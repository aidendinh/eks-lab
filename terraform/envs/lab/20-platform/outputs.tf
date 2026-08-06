output "telemetry_endpoint" {
  description = "Internal NLB cluster 1 ships metrics, logs and traces to."
  value       = module.observability_stack.telemetry_endpoint
}

output "grafana_url" {
  description = "Grafana UI. Username `admin`; password from `terraform -chdir=../10-infra output -raw grafana_password`."
  value       = "http://${module.observability_stack.grafana_endpoint}"
}

output "argocd_url" {
  description = "Argo CD UI. Username `admin`; password from `terraform -chdir=../10-infra output -raw argocd_password`."
  value       = "https://${module.gitops.server_endpoint}"
}
