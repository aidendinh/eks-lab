variable "namespace" {
  description = "Namespace for the whole stack."
  type        = string
  default     = "monitoring"
}

variable "prometheus_release_name" {
  description = "Helm release name for kube-prometheus-stack. Service names — and therefore the telemetry Ingress backends — derive from it."
  type        = string
  default     = "monitoring"
}

variable "grafana_admin_secret" {
  description = "Kubernetes Secret, populated by ESO from the eks-lab secret, holding Grafana's admin credentials."
  type        = string
  default     = "grafana-admin"
}

variable "prometheus_storage_size" {
  description = "PersistentVolume size for the central Prometheus."
  type        = string
  default     = "20Gi"
}

variable "kube_prometheus_stack_version" {
  type    = string
  default = "88.0.1"
}

variable "loki_version" {
  type    = string
  default = "6.24.0"
}

variable "tempo_version" {
  type    = string
  default = "1.18.2"
}

variable "ingress_nginx_version" {
  type    = string
  default = "4.15.1"
}
