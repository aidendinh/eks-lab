variable "namespace" {
  description = "Namespace Argo CD runs in."
  type        = string
  default     = "argocd"
}

variable "chart_version" {
  description = "argo-cd chart version."
  type        = string
  default     = "10.2.2"
}

variable "repo_url" {
  description = "Git repository Argo CD syncs the microservices chart from."
  type        = string
}

variable "target_revision" {
  description = "Git revision to track."
  type        = string
  default     = "HEAD"
}

variable "chart_path" {
  description = "Path to the chart inside the repository."
  type        = string
  default     = "assignment/charts/sample-microservices"
}

variable "application_name" {
  description = "Argo CD Application name, also used as the Helm release name."
  type        = string
  default     = "sample-microservices"
}

variable "destination_namespace" {
  description = "Namespace the microservices are deployed into."
  type        = string
  default     = "sample"
}

variable "node_selector" {
  description = "Argo CD is platform tooling; keep it on the managed node group."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Tolerations for the tainted platform nodes."
  type        = list(any)
  default     = []
}
