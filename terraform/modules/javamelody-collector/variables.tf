variable "name" {
  description = "Name of the Deployment and Service."
  type        = string
  default     = "javamelody-collector"
}

variable "namespace" {
  description = "Namespace to deploy into. Must be the namespace the javamelody-auth ExternalSecret targets."
  type        = string
  default     = "monitoring"
}

variable "image" {
  description = "Collector server image."
  type        = string
}

variable "auth_secret_name" {
  description = "Kubernetes Secret, populated by ESO, holding the JVM @argfile with the authorized-users property."
  type        = string
  default     = "javamelody-auth"
}

variable "node_selector" {
  description = "Keep the collector on the managed platform node group."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Tolerations for the tainted platform nodes."
  type = list(object({
    key      = string
    operator = string
    value    = string
    effect   = string
  }))
  default = []
}
