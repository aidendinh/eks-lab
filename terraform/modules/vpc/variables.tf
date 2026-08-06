variable "name" {
  description = "Name prefix applied to every network resource."
  type        = string
}

variable "cidr_block" {
  description = "IPv4 CIDR for the VPC. Must be a /16 so the /24 subnet split has room."
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zones to spread subnets across. Two is enough for the topology spread constraints to have somewhere to spread to."
  type        = list(string)
}

variable "karpenter_discovery_value" {
  description = "Value for the karpenter.sh/discovery tag on private subnets; Karpenter's EC2NodeClass selects on it."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
