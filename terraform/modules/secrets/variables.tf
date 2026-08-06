variable "secret_name" {
  description = "Secrets Manager secret name. The assignment requires exactly one secret, named `eks-lab`."
  type        = string
  default     = "eks-lab"
}

variable "cluster_names" {
  description = "Clusters that run ESO; each gets an IAM role and a Pod Identity association."
  type        = set(string)
}

variable "eso_namespace" {
  description = "Namespace ESO runs in."
  type        = string
  default     = "external-secrets"
}

variable "eso_service_account" {
  description = "ESO controller service account name."
  type        = string
  default     = "external-secrets"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
