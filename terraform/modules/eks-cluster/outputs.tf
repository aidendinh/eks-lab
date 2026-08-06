output "cluster_name" {
  description = "Cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca_data" {
  description = "Base64 cluster CA, for kubeconfig / provider configuration."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "The EKS-managed cluster security group. Karpenter nodes and EFS mount targets attach to it."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_role_arn" {
  description = "IAM role ARN shared by managed and Karpenter-launched nodes."
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  description = "IAM role name shared by managed and Karpenter-launched nodes."
  value       = aws_iam_role.node.name
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL. Unused by this lab (Pod Identity is used instead) but needed by anything that still wants IRSA."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}
