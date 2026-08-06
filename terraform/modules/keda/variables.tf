variable "namespace" {
  description = "Namespace KEDA runs in."
  type        = string
  default     = "keda"
}

variable "chart_version" {
  description = "keda chart version."
  type        = string
  default     = "2.16.1"
}

variable "node_selector" {
  description = "KEDA is platform tooling; keep it on the managed node group."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Tolerations for the tainted platform nodes."
  type        = list(any)
  default     = []
}
