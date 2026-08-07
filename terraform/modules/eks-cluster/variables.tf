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

variable "admin_principal_arns" {
  description = <<-EOT
    IAM principals to grant Kubernetes cluster-admin, beyond the implicit
    cluster-creator entry.

    The cluster runs `authentication_mode = "API"`, so access entries are the
    only path from IAM into Kubernetes RBAC — there is no aws-auth ConfigMap to
    fall back on. Bootstrap admin covers whoever ran `apply` and nobody else, so
    any other identity — a colleague, a CI role, or the same human signed into
    the console under a different principal — is Unauthorized on everything that
    reads the Kubernetes API, including the console's Nodes and Workloads tabs.

    Give the IAM **role** ARN, never the assumed-role session ARN the console
    shows you. For IAM Identity Center that is
    arn:aws:iam::<account>:role/aws-reserved/sso.amazonaws.com/<region>/AWSReservedSSO_<PermissionSet>_<hash>.
    The access-entry API rejects STS session principals outright, since a session
    is temporary and has no permanent identity to attach permissions to.

    Do not list the principal that ran the first `apply`. Its bootstrap entry
    already exists and is not in Terraform state, so Terraform would try to
    create a duplicate and the apply would fail with ResourceInUseException —
    one ARN can hold only one access entry per cluster.

    Same-account principals only; the API will not accept an ARN from another
    AWS account.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for arn in var.admin_principal_arns :
      can(regex("^arn:[^:]+:iam::[0-9]{12}:(role|user)/", arn))
    ])
    error_message = "Each ARN must be an IAM role or user ARN. An assumed-role session ARN (arn:aws:sts::<account>:assumed-role/<role>/<session>) is rejected by the access-entry API; use the underlying role instead."
  }
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

variable "enable_ebs_csi" {
  description = "Install the EBS CSI driver and its Pod Identity role. Needed only by clusters with stateful components."
  type        = bool
  default     = false
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
