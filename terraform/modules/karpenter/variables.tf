variable "cluster_name" {
  description = "Cluster Karpenter provisions nodes for; also the queue/role name prefix."
  type        = string
}

variable "node_role_arn" {
  description = "IAM role Karpenter passes to the instances it launches. Reuses the cluster's node role so managed and Karpenter nodes authenticate identically."
  type        = string
}

variable "namespace" {
  description = "Namespace the controller runs in."
  type        = string
  default     = "karpenter"
}

variable "service_account" {
  description = "Controller service account name, for the Pod Identity association."
  type        = string
  default     = "karpenter"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
