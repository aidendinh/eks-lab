# Argo CD, and the single Application that delivers the microservices chart.
#
# The assignment forbids kubectl-applied app manifests, so the chart is never
# installed by Helm or Terraform directly: Terraform installs Argo CD and
# registers *where the chart lives*, and Argo CD does the rest from Git.

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = var.namespace
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.chart_version

  values = [yamlencode({
    global = {
      nodeSelector = var.node_selector
      tolerations  = var.tolerations
    }

    configs = {
      params = {
        # Keep TLS on: the server is exposed through a public NLB.
        "server.insecure" = false
      }
    }

    server = {
      replicas = 1
      service = {
        type        = "LoadBalancer"
        annotations = { "service.beta.kubernetes.io/aws-load-balancer-type" = "nlb" }
      }
    }

    controller     = { replicas = 1 }
    repoServer     = { replicas = 1 }
    applicationSet = { replicas = 1 }
    # Nothing to notify and no SSO provider in a lab.
    notifications = { enabled = false }
    dex           = { enabled = false }
  })]

  wait    = true
  timeout = 1200
}

# The Application is a CRD instance, so it ships as a local chart for the same
# reason the Karpenter NodePools do: kubernetes_manifest would need the schema
# at plan time, before Argo CD exists.
resource "helm_release" "application" {
  name      = "sample-microservices-app"
  namespace = var.namespace

  chart = "${path.module}/chart"

  values = [yamlencode({
    name            = var.application_name
    namespace       = var.namespace
    repoUrl         = var.repo_url
    targetRevision  = var.target_revision
    path            = var.chart_path
    destNamespace   = var.destination_namespace
    releaseName     = var.application_name
  })]

  wait    = true
  timeout = 300

  depends_on = [helm_release.argocd]
}

data "kubernetes_service" "argocd_server" {
  metadata {
    name      = "argocd-server"
    namespace = var.namespace
  }

  depends_on = [helm_release.argocd]
}
