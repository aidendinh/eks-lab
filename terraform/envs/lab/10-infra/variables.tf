variable "region" {
  description = "AWS region for the whole lab."
  type        = string
  default     = "ap-southeast-1"
}

variable "azs" {
  description = "Availability zones. Two gives the zone topology-spread constraint somewhere to spread to without a third NAT-less AZ to reason about."
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b"]
}

variable "kubernetes_version" {
  description = "EKS version for both clusters."
  type        = string
  default     = "1.36"
}

variable "operator_cidr" {
  description = <<-EOT
    CIDR allowed to reach both public API endpoints, normally "<your ip>/32".
    Terraform, kubectl and helm all run from here. Set it in terraform.tfvars;
    there is deliberately no default, because 0.0.0.0/0 must never be one.
  EOT
  type        = string

  validation {
    condition     = var.operator_cidr != "0.0.0.0/0"
    error_message = "Refusing to open the Kubernetes API to the whole internet."
  }
}

variable "workload_cluster_name" {
  description = "Name of cluster 1, which runs the JVM microservices."
  type        = string
  default     = "eks-workload"
}

variable "observability_cluster_name" {
  description = "Name of cluster 2, which runs Prometheus/Grafana/Loki/Tempo."
  type        = string
  default     = "eks-observability"
}

variable "ecr_repository_name" {
  description = "ECR repository holding all three application images, distinguished by tag."
  type        = string
  default     = "eks-lab"
}
