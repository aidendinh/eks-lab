output "server_endpoint" {
  description = "Public NLB hostname for the Argo CD UI."
  value       = data.kubernetes_service.argocd_server.status[0].load_balancer[0].ingress[0].hostname
}
