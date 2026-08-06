output "telemetry_endpoint" {
  description = "Internal NLB hostname the workload cluster remote-writes and ships logs/traces to."
  value       = data.kubernetes_service.ingress_nginx.status[0].load_balancer[0].ingress[0].hostname
}

output "grafana_endpoint" {
  description = "Public NLB hostname for the Grafana UI."
  value       = data.kubernetes_service.grafana.status[0].load_balancer[0].ingress[0].hostname
}

output "namespace" {
  value = var.namespace
}
