# Cluster 2: the central Prometheus / Grafana / Loki / Tempo stack, plus the
# ingress that cluster 1 ships metrics, logs and traces to.

# The namespace is created by the caller, not here: ESO must be able to write
# Grafana's admin Secret into it *before* this stack installs, and a namespace
# owned by this module would make that ordering circular.

# gp3 rather than the gp2 default: same durability, cheaper per GiB, and
# baseline IOPS that do not scale with volume size. WaitForFirstConsumer keeps
# the volume in the AZ the pod actually lands in.
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}

# ------------------------------------------------------------ prometheus

resource "helm_release" "kube_prometheus_stack" {
  name      = var.prometheus_release_name
  namespace = var.namespace

  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_version

  values = [
    file("${path.module}/values/prometheus.yaml"),
    yamlencode({
      grafana = {
        # Credentials come from the eks-lab Secrets Manager secret via ESO;
        # the chart's own random admin password is never used.
        admin = {
          existingSecret = var.grafana_admin_secret
          userKey        = "admin-user"
          passwordKey    = "admin-password"
        }
      }
      prometheus = {
        prometheusSpec = {
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = kubernetes_storage_class.gp3.metadata[0].name
                accessModes      = ["ReadWriteOnce"]
                resources        = { requests = { storage = var.prometheus_storage_size } }
              }
            }
          }
        }
      }
    }),
  ]

  wait    = true
  timeout = 1200

  depends_on = [kubernetes_storage_class.gp3]
}

# ------------------------------------------------------------------- loki

resource "helm_release" "loki" {
  name      = "loki"
  namespace = var.namespace

  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = var.loki_version

  values = [
    file("${path.module}/values/loki.yaml"),
    yamlencode({
      singleBinary = {
        persistence = {
          storageClass = kubernetes_storage_class.gp3.metadata[0].name
        }
      }
    }),
  ]

  wait    = true
  timeout = 900

  depends_on = [kubernetes_storage_class.gp3]
}

# ------------------------------------------------------------------ tempo

resource "helm_release" "tempo" {
  name      = "tempo"
  namespace = var.namespace

  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo"
  version    = var.tempo_version

  values = [
    file("${path.module}/values/tempo.yaml"),
    yamlencode({
      persistence = {
        storageClassName = kubernetes_storage_class.gp3.metadata[0].name
      }
    }),
  ]

  wait    = true
  timeout = 900

  depends_on = [kubernetes_storage_class.gp3]
}

# --------------------------------------------------------------- ingestion

# One internal NLB fronts all three sinks. Internal, because the only client is
# the workload cluster in the same VPC — nothing about this path should be
# reachable from the internet.
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true

  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = var.ingress_nginx_version

  values = [file("${path.module}/values/ingress-nginx.yaml")]

  wait    = true
  timeout = 900
}

resource "kubernetes_ingress_v1" "telemetry" {
  metadata {
    name      = "telemetry"
    namespace = var.namespace

    annotations = {
      # Remote-write batches and trace payloads are both larger than the 1m
      # nginx default, and a slow Loki flush outlasts the 60s read timeout.
      "nginx.ingress.kubernetes.io/proxy-body-size"   = "32m"
      "nginx.ingress.kubernetes.io/proxy-read-timeout" = "120"
      "nginx.ingress.kubernetes.io/proxy-send-timeout" = "120"
    }
  }

  spec {
    ingress_class_name = "nginx"

    rule {
      http {
        path {
          path      = "/api/v1/write"
          path_type = "Prefix"
          backend {
            service {
              name = "${var.prometheus_release_name}-kube-prometheus-prometheus"
              port { number = 9090 }
            }
          }
        }

        path {
          path      = "/loki/api/v1/push"
          path_type = "Prefix"
          backend {
            service {
              name = "loki-gateway"
              port { number = 80 }
            }
          }
        }

        path {
          path      = "/v1/traces"
          path_type = "Prefix"
          backend {
            service {
              name = "tempo"
              port { number = 4318 }
            }
          }
        }
      }
    }
  }

  depends_on = [
    helm_release.ingress_nginx,
    helm_release.kube_prometheus_stack,
    helm_release.loki,
    helm_release.tempo,
  ]
}

# Helm's --wait blocks until a LoadBalancer Service has an ingress address, so
# by the time this is read the NLB hostname exists.
data "kubernetes_service" "ingress_nginx" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }

  depends_on = [helm_release.ingress_nginx]
}

data "kubernetes_service" "grafana" {
  metadata {
    name      = "${var.prometheus_release_name}-grafana"
    namespace = var.namespace
  }

  depends_on = [helm_release.kube_prometheus_stack]
}
