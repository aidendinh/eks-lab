variable "name" {
  description = "Name prefix for the filesystem and its IAM role."
  type        = string
}

variable "vpc_id" {
  description = "VPC hosting the mount targets."
  type        = string
}

variable "vpc_cidr_block" {
  description = "CIDR allowed to reach NFS on the mount targets."
  type        = string
}

variable "subnets_by_az" {
  description = "AZ -> subnet id. One mount target per entry; cover every AZ that can host a pod. Keyed by AZ so the map keys are known at plan time."
  type        = map(string)
}

variable "cluster_name" {
  description = "Cluster that gets the EFS CSI driver add-on."
  type        = string
}

variable "controller_node_selector" {
  description = "nodeSelector for the CSI controller Deployment."
  type        = map(string)
  default     = {}
}

variable "controller_tolerations" {
  description = "Tolerations for the CSI controller Deployment; required when the platform nodes are tainted."
  type        = list(any)
  default     = []
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
