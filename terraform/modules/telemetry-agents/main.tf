# Cluster 1's shippers. Nothing is queried here — all three signals leave for
# the observability cluster:
#
#   metrics  Prometheus (2h retention, forwarder) -> remote_write -> cluster 2
#   logs     Alloy DaemonSet tails /var/log/pods  -> Loki push     -> cluster 2
#   traces   Alloy OTLP receiver                  -> OTLP/HTTP     -> cluster 2

# The namespace is created by the caller: ESO writes the JavaMelody credential
# into it before these releases install.

# A forwarder, not a store: two hours of local retention is a buffer against a
# brief outage of the central Prometheus, not a queryable history.
resource "helm_release" "prometheus_agent" {
  name      = var.prometheus_release_name
  namespace = var.namespace

  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_version

  values = [
    file("${path.module}/values/prometheus.yaml"),
    yamlencode({
      prometheus = {
        prometheusSpec = {
          externalLabels = { cluster = var.cluster_name }
          remoteWrite = [{
            url = "http://${var.telemetry_endpoint}/api/v1/write"
            queueConfig = {
              capacity          = 2500
              maxSamplesPerSend = 500
              maxShards         = 4
            }
          }]
        }
      }
    }),
  ]

  wait    = true
  timeout = 1200
}

resource "helm_release" "alloy" {
  name      = "alloy"
  namespace = var.namespace

  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = var.alloy_version

  values = [templatefile("${path.module}/values/alloy.yaml.tftpl", {
    telemetry_endpoint = var.telemetry_endpoint
    cluster_name       = var.cluster_name
  })]

  wait    = true
  timeout = 900
}
