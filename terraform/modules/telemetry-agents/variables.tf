variable "namespace" {
  description = "Namespace for the shippers."
  type        = string
  default     = "monitoring"
}

variable "cluster_name" {
  description = "Value of the `cluster` label stamped on every metric and log line, so cluster 2 can tell the sources apart."
  type        = string
}

variable "telemetry_endpoint" {
  description = "Internal NLB hostname of the observability cluster's ingress."
  type        = string
}

variable "prometheus_release_name" {
  description = "Helm release name for the forwarder. Distinct from the observability cluster's release so ServiceMonitor labels do not collide conceptually."
  type        = string
  default     = "workload-monitoring"
}

variable "kube_prometheus_stack_version" {
  type    = string
  default = "88.0.1"
}

variable "alloy_version" {
  type    = string
  default = "1.11.0"
}
