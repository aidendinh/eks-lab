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

variable "api_public_access_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach both clusters' public Kubernetes API endpoints.

    Defaults to open. The API server still requires AWS IAM authentication — an
    access entry must exist for the caller — so this is reachability, not
    authorisation, and it is what EKS itself defaults to when public access is
    enabled. It does put both API servers on the internet, which is a real
    increase in attack surface for anything auth-bypassing.

    Narrow it to ["<your ip>/32"] in terraform.tfvars when you want the lab
    locked down; a list, so an office and a home address can both be listed.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.api_public_access_cidrs) > 0
    error_message = "Provide at least one CIDR, or the API endpoint is unreachable."
  }
}

variable "cluster_admin_principal_arns" {
  description = <<-EOT
    Extra IAM principals granted Kubernetes cluster-admin on both clusters.

    Empty by default, which leaves exactly one admin: the principal that ran the
    first `apply`. Add your console identity here if the EKS console shows
    "Unauthorized" under Nodes or Workloads — that view reads the Kubernetes API,
    which AWS account admin does not reach on its own.

    Use the IAM role ARN, not the assumed-role session ARN. Find it with
    `aws sts get-caller-identity`: a session ARN of
    arn:aws:sts::<account>:assumed-role/AWSReservedSSO_Admin_abc123/you maps to
    arn:aws:iam::<account>:role/aws-reserved/sso.amazonaws.com/<region>/AWSReservedSSO_Admin_abc123.
  EOT
  type        = list(string)
  default     = []
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
