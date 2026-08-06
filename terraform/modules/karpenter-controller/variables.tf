variable "cluster_name" {
  description = "Cluster Karpenter provisions for. Also the value of the karpenter.sh/discovery subnet tag."
  type        = string
}

variable "namespace" {
  description = "Namespace for the controller. Must match the Pod Identity association from 10-infra."
  type        = string
  default     = "karpenter"
}

variable "chart_version" {
  description = "Karpenter chart version."
  type        = string
  default     = "1.14.0"
}

variable "interruption_queue" {
  description = "SQS queue carrying Spot interruption and rebalance notices."
  type        = string
}

variable "node_role_name" {
  description = "IAM role name Karpenter attaches to the nodes it launches."
  type        = string
}

variable "security_group_id" {
  description = "Security group for launched nodes; the EKS-managed cluster security group."
  type        = string
}

variable "node_selector" {
  description = "Where the controller itself runs."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Tolerations for the controller."
  type        = list(any)
  default     = []
}

# ------------------------------------------------------------- pool shaping

variable "instance_types" {
  description = "amd64 instance types for pools 1 and 3. Capped at t3.medium by the lab's cost constraint."
  type        = list(string)
  default     = ["t3.small", "t3.medium", "t3a.small", "t3a.medium"]
}

variable "graviton_instance_types" {
  description = "arm64 instance types for pool 2. Capped at t4g.medium."
  type        = list(string)
  default     = ["t4g.small", "t4g.medium"]
}

variable "general_cpu_limit" {
  description = "vCPU ceiling for pool 1 (Spot, amd64)."
  type        = string
  default     = "4"
}

variable "graviton_cpu_limit" {
  description = "vCPU ceiling for pool 2 (Graviton, arm64)."
  type        = string
  default     = "4"
}

variable "spot_cpu_limit" {
  description = <<-EOT
    vCPU ceiling for the Spot half of pool 3. At 2 vCPU per t3.medium, 6 allows
    three Spot nodes — the "3" of the 1:3 ratio.
  EOT
  type        = string
  default     = "6"
}

variable "ondemand_cpu_limit" {
  description = <<-EOT
    vCPU ceiling for the On-Demand half of pool 3. At 2 vCPU per t3.medium, 2
    allows a single On-Demand node — the "1" of the 1:3 ratio.
  EOT
  type        = string
  default     = "2"
}

variable "microservices_taint" {
  description = "Taint applied to pool 3, so only pods that explicitly tolerate it land there."
  type = object({
    key    = string
    value  = string
    effect = string
  })
  default = {
    key    = "dedicated"
    value  = "microservices"
    effect = "NoSchedule"
  }
}
