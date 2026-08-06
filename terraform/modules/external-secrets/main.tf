# External Secrets Operator, plus the ClusterSecretStore and ExternalSecrets
# that project the single `eks-lab` Secrets Manager secret into Kubernetes.
#
# Installed on both clusters — Grafana's admin credentials are needed on the
# observability side, the collector and Argo CD credentials on the workload
# side — so everything here is parameterised rather than hardcoded.

resource "helm_release" "operator" {
  name             = "external-secrets"
  namespace        = var.namespace
  create_namespace = true

  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = var.chart_version

  # The operator authenticates to AWS through the Pod Identity association made
  # in 10-infra, which attaches to this service account by name. Letting the
  # chart create it with its default name keeps the two in sync.
  values = [yamlencode(merge(
    {
      installCRDs = true
    },
    var.helm_values,
  ))]

  wait    = true
  timeout = 600
}

# CRs go through a local chart rather than kubernetes_manifest: that resource
# reads the CRD schema during plan, and the CRDs do not exist until the release
# above is applied. Helm has no such plan-time dependency.
resource "helm_release" "resources" {
  name      = "external-secrets-resources"
  namespace = var.namespace

  chart = "${path.module}/chart"

  values = [yamlencode({
    secretStoreName = var.secret_store_name
    region          = var.region
    externalSecrets = var.external_secrets
  })]

  wait    = true
  timeout = 300

  depends_on = [helm_release.operator]
}
