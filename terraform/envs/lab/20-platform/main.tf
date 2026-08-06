# Layer 2: everything that lives inside the two clusters.
#
# Ordering that matters, and why:
#   1. namespaces come from here, not from the modules, so ESO can populate a
#      Secret before the release that consumes it installs.
#   2. the observability stack must finish first — its internal NLB hostname is
#      the endpoint cluster 1's shippers are configured with.
#   3. Argo CD precedes the workload ExternalSecrets, because the Argo CD admin
#      password is *merged* into a Secret the Argo CD chart creates.

locals {
  platform_node_selector = { workload-class = "platform" }

  platform_tolerations = [{
    key      = "dedicated"
    operator = "Equal"
    value    = "platform"
    effect   = "NoSchedule"
  }]

  secret_key = local.infra.secret_name
}

# ===========================================================================
# Cluster 2 — observability
# ===========================================================================

resource "kubernetes_namespace" "observability_monitoring" {
  provider = kubernetes.observability

  metadata {
    name = "monitoring"
  }
}

module "eso_observability" {
  source = "../../../modules/external-secrets"

  providers = {
    helm       = helm.observability
    kubernetes = kubernetes.observability
  }

  region = local.region

  external_secrets = [{
    name      = "grafana-admin"
    namespace = kubernetes_namespace.observability_monitoring.metadata[0].name
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "aws-secrets", kind = "ClusterSecretStore" }
      target          = { name = "grafana-admin", creationPolicy = "Owner" }
      data = [
        {
          secretKey = "admin-user"
          remoteRef = { key = local.secret_key, property = "grafana-username" }
        },
        {
          secretKey = "admin-password"
          remoteRef = { key = local.secret_key, property = "grafana-password" }
        },
      ]
    }
  }]
}

module "observability_stack" {
  source = "../../../modules/observability-stack"

  providers = {
    helm       = helm.observability
    kubernetes = kubernetes.observability
  }

  namespace = kubernetes_namespace.observability_monitoring.metadata[0].name

  # Grafana starts with the admin Secret already in place.
  depends_on = [module.eso_observability]
}

# ===========================================================================
# Cluster 1 — workload
# ===========================================================================

resource "kubernetes_namespace" "workload_monitoring" {
  provider = kubernetes.workload

  metadata {
    name = "monitoring"
  }
}

# Argo CD would create this itself on first sync, but the collector-URL
# ExternalSecret has to land here before the first application pod starts.
resource "kubernetes_namespace" "sample" {
  provider = kubernetes.workload

  metadata {
    name = "sample"
  }

  lifecycle {
    # Argo CD adopts and labels the namespace once it syncs.
    ignore_changes = [metadata[0].labels, metadata[0].annotations]
  }
}

# The EFS StorageClass. Dynamic provisioning: each PVC gets its own access
# point on the shared filesystem, created by the CSI driver on demand — there
# is no pre-created PersistentVolume anywhere.
resource "kubernetes_storage_class" "efs" {
  provider = kubernetes.workload

  metadata {
    name = "efs-rwx"
  }

  storage_provisioner = "efs.csi.aws.com"
  # EFS is not block storage: there is nothing to bind to a zone, so volumes
  # can be provisioned immediately.
  volume_binding_mode = "Immediate"
  reclaim_policy      = "Delete"

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = local.infra.efs_file_system_id
    directoryPerms   = "775"
    # Matches the containers' runAsUser/runAsGroup so the mount is writable
    # without running anything as root.
    uid = "10001"
    gid = "2000"
  }
}

module "karpenter" {
  source = "../../../modules/karpenter-controller"

  providers = {
    helm = helm.workload
  }

  cluster_name       = local.workload.name
  interruption_queue = local.infra.karpenter_queue_name
  node_role_name     = local.workload.node_role_name
  security_group_id  = local.workload.security_group

  node_selector = local.platform_node_selector
  tolerations   = local.platform_tolerations
}

module "keda" {
  source = "../../../modules/keda"

  providers = {
    helm = helm.workload
  }

  node_selector = local.platform_node_selector
  tolerations   = local.platform_tolerations
}

module "telemetry_agents" {
  source = "../../../modules/telemetry-agents"

  providers = {
    helm       = helm.workload
    kubernetes = kubernetes.workload
  }

  namespace          = kubernetes_namespace.workload_monitoring.metadata[0].name
  cluster_name       = local.workload.name
  telemetry_endpoint = module.observability_stack.telemetry_endpoint
}

module "gitops" {
  source = "../../../modules/gitops"

  providers = {
    helm       = helm.workload
    kubernetes = kubernetes.workload
  }

  repo_url              = var.git_repository_url
  target_revision       = var.git_target_revision
  destination_namespace = kubernetes_namespace.sample.metadata[0].name

  node_selector = local.platform_node_selector
  tolerations   = local.platform_tolerations

  # The chart Argo CD syncs contains ServiceMonitors, so the Prometheus operator
  # CRDs have to be in place before the first sync — otherwise the Application
  # burns its retry budget and sits SyncFailed until something nudges it.
  depends_on = [module.telemetry_agents]
}

module "eso_workload" {
  source = "../../../modules/external-secrets"

  providers = {
    helm       = helm.workload
    kubernetes = kubernetes.workload
  }

  region = local.region

  helm_values = {
    nodeSelector   = local.platform_node_selector
    tolerations    = local.platform_tolerations
    webhook        = { nodeSelector = local.platform_node_selector, tolerations = local.platform_tolerations }
    certController = { nodeSelector = local.platform_node_selector, tolerations = local.platform_tolerations }
  }

  external_secrets = [
    # The collector's own Basic-auth configuration, delivered as a JVM @argfile
    # so the credential never appears on a command line.
    {
      name      = "javamelody-auth"
      namespace = kubernetes_namespace.workload_monitoring.metadata[0].name
      spec = {
        refreshInterval = "1h"
        secretStoreRef  = { name = "aws-secrets", kind = "ClusterSecretStore" }
        target = {
          name           = "javamelody-auth"
          creationPolicy = "Owner"
          template = {
            data = {
              "auth.args" = "-Djavamelody.authorized-users={{ .auth }}"
            }
          }
        }
        data = [{
          secretKey = "auth"
          remoteRef = { key = local.secret_key, property = "javamelody-auth" }
        }]
      }
    },

    # The same credential, this time as the userinfo half of the URL the
    # application pods register themselves with.
    {
      name      = "javamelody-collector-url"
      namespace = kubernetes_namespace.sample.metadata[0].name
      spec = {
        refreshInterval = "1h"
        secretStoreRef  = { name = "aws-secrets", kind = "ClusterSecretStore" }
        target = {
          name           = "javamelody-collector-url"
          creationPolicy = "Owner"
          template = {
            data = {
              JAVAMELODY_COLLECTOR_URL = "http://{{ .auth }}@javamelody-collector.monitoring.svc.cluster.local:8080"
            }
          }
        }
        data = [{
          secretKey = "auth"
          remoteRef = { key = local.secret_key, property = "javamelody-auth" }
        }]
      }
    },

    # Merge, not Owner: argocd-secret is created by the Argo CD chart and holds
    # the server's signing keys too. Owning it here would wipe them.
    {
      name      = "argocd-admin-password"
      namespace = "argocd"
      spec = {
        refreshInterval = "1h"
        secretStoreRef  = { name = "aws-secrets", kind = "ClusterSecretStore" }
        target = {
          name           = "argocd-secret"
          creationPolicy = "Merge"
          template = {
            data = {
              "admin.password" = "{{ .password }}"
              # Argo CD invalidates issued tokens whenever this is older than
              # the token; a fixed value keeps logins stable across syncs.
              "admin.passwordMtime" = "2026-08-07T00:00:00Z"
            }
          }
        }
        data = [{
          secretKey = "password"
          remoteRef = { key = local.secret_key, property = "argocd-bcrypt" }
        }]
      }
    },
  ]

  # argocd-secret must exist before it can be merged into.
  depends_on = [module.gitops]
}

module "javamelody_collector" {
  source = "../../../modules/javamelody-collector"

  providers = {
    kubernetes = kubernetes.workload
  }

  namespace = kubernetes_namespace.workload_monitoring.metadata[0].name
  image     = "${local.infra.ecr_repository_url}:${var.collector_image_tag}"

  node_selector = local.platform_node_selector
  tolerations = [{
    key      = "dedicated"
    operator = "Equal"
    value    = "platform"
    effect   = "NoSchedule"
  }]

  # The auth Secret is mounted, so it has to exist first.
  depends_on = [module.eso_workload]
}
