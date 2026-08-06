# Consumed by 20-platform through terraform_remote_state, and by the runbook.

output "region" {
  description = "Region both clusters live in."
  value       = var.region
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}

output "ecr_repository_url" {
  description = "Push target for the three application images."
  value       = aws_ecr_repository.apps.repository_url
}

output "workload_cluster" {
  description = "Everything 20-platform needs to configure a provider against cluster 1."
  value = {
    name           = module.workload_cluster.cluster_name
    endpoint       = module.workload_cluster.cluster_endpoint
    ca_data        = module.workload_cluster.cluster_ca_data
    node_role_arn  = module.workload_cluster.node_role_arn
    node_role_name = module.workload_cluster.node_role_name
    security_group = module.workload_cluster.cluster_security_group_id
  }
}

output "observability_cluster" {
  description = "Everything 20-platform needs to configure a provider against cluster 2."
  value = {
    name           = module.observability_cluster.cluster_name
    endpoint       = module.observability_cluster.cluster_endpoint
    ca_data        = module.observability_cluster.cluster_ca_data
    node_role_arn  = module.observability_cluster.node_role_arn
    node_role_name = module.observability_cluster.node_role_name
    security_group = module.observability_cluster.cluster_security_group_id
  }
}

output "efs_file_system_id" {
  description = "Backs the microservices' ReadWriteMany StorageClass."
  value       = module.efs.file_system_id
}

output "karpenter_queue_name" {
  description = "Interruption queue, passed to the controller as settings.interruptionQueue."
  value       = module.karpenter.queue_name
}

output "secret_name" {
  description = "The single Secrets Manager secret ESO reads."
  value       = module.secrets.secret_name
}

output "grafana_password" {
  description = "Grafana admin password. `terraform output -raw grafana_password`."
  value       = module.secrets.grafana_password
  sensitive   = true
}

output "argocd_password" {
  description = "Argo CD admin password. `terraform output -raw argocd_password`."
  value       = module.secrets.argocd_password
  sensitive   = true
}
