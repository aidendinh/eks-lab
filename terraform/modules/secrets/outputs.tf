output "secret_name" {
  description = "Name ESO addresses in remoteRef.key."
  value       = aws_secretsmanager_secret.this.name
}

output "secret_arn" {
  description = "Secret ARN."
  value       = aws_secretsmanager_secret.this.arn
}

output "grafana_password" {
  description = "Grafana admin password, for the operator to log in with."
  value       = random_password.grafana.result
  sensitive   = true
}

output "argocd_password" {
  description = "Argo CD admin password, for the operator to log in with."
  value       = random_password.argocd.result
  sensitive   = true
}
