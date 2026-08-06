variable "name" {
  description = "Cluster name; also the prefix for its IAM roles."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS control plane version."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the control plane ENIs. Private subnets only."
  type        = list(string)
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint."
  type        = list(string)
}

variable "enabled_log_types" {
  description = "Control-plane log types to ship to CloudWatch."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "log_retention_days" {
  description = "Retention for the control-plane log group. Short by default; these logs are chatty and this is a lab."
  type        = number
  default     = 7
}

variable "node_groups" {
  description = <<-EOT
    Managed node groups, keyed by name. These host system/platform components
    only — application workloads land on Karpenter-provisioned nodes.
  EOT
  type = map(object({
    subnet_ids     = list(string)
    ami_type       = string
    capacity_type  = string
    instance_types = list(string)
    disk_size      = optional(number, 20)
    desired_size   = number
    min_size       = number
    max_size       = number
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
    tags = optional(map(string), {})
  }))
  default = {}
}

variable "coredns_configuration_values" {
  description = "JSON string passed to the CoreDNS add-on. Required when every node is tainted."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
