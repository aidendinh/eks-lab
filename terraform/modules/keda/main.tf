# KEDA: workload autoscaling. Karpenter scales nodes; KEDA scales pods, and the
# two compose — a ScaledObject adding replicas creates Pending pods, which is
# exactly the signal Karpenter provisions against.
#
# KEDA rather than a plain HPA because the interesting trigger here is a
# Prometheus query (request rate scraped from the services), which a stock HPA
# cannot read without a custom metrics adapter. KEDA ships that adapter and
# still drives a normal HPA underneath.

resource "helm_release" "keda" {
  name             = "keda"
  namespace        = var.namespace
  create_namespace = true

  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  version    = var.chart_version

  values = [yamlencode({
    nodeSelector = var.node_selector
    tolerations  = var.tolerations

    # The three components each take their own scheduling block; the top-level
    # one does not reach them.
    operator          = { nodeSelector = var.node_selector, tolerations = var.tolerations }
    metricsServer     = { nodeSelector = var.node_selector, tolerations = var.tolerations }
    webhooks          = { nodeSelector = var.node_selector, tolerations = var.tolerations }
    resources = {
      operator = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
    }
  })]

  wait    = true
  timeout = 900
}
