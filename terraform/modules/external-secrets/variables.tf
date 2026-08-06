variable "namespace" {
  description = "Namespace for the operator. Must match the Pod Identity association made in 10-infra."
  type        = string
  default     = "external-secrets"
}

variable "chart_version" {
  description = <<-EOT
    external-secrets chart version. Must be a release whose CRDs serve
    `external-secrets.io/v1` — the 0.14.x line only serves v1alpha1/v1beta1, and
    the manifests in this repo are written against v1.
  EOT
  type    = string
  default = "2.8.0"
}

variable "region" {
  description = "Region the Secrets Manager secret lives in."
  type        = string
}

variable "secret_store_name" {
  description = "Name of the ClusterSecretStore that ExternalSecrets reference."
  type        = string
  default     = "aws-secrets"
}

variable "external_secrets" {
  description = <<-EOT
    ExternalSecrets to create, as objects of {name, namespace, spec}. `spec` is
    emitted verbatim, so anything the CRD accepts works without this module
    growing a schema of its own.
  EOT
  type = list(object({
    name      = string
    namespace = string
    spec      = any
  }))
  default = []
}

variable "helm_values" {
  description = "Extra values for the operator chart, e.g. nodeSelector/tolerations for tainted platform nodes."
  type        = any
  default     = {}
}
