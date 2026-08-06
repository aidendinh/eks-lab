terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}

# 10-infra is a separate root precisely so that these provider blocks can read
# concrete endpoints instead of values that are unknown until the clusters are
# built.
data "terraform_remote_state" "infra" {
  backend = "local"

  config = {
    path = "${path.module}/../10-infra/terraform.tfstate"
  }
}

locals {
  infra         = data.terraform_remote_state.infra.outputs
  workload      = local.infra.workload_cluster
  observability = local.infra.observability_cluster
  region        = local.infra.region
}

provider "aws" {
  region = local.region
}

# Tokens are fetched by exec rather than baked in: an EKS token lives 15
# minutes, so a token captured at plan time is expired by the end of a long
# apply.
provider "kubernetes" {
  alias                  = "workload"
  host                   = local.workload.endpoint
  cluster_ca_certificate = base64decode(local.workload.ca_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.workload.name, "--region", local.region]
  }
}

provider "kubernetes" {
  alias                  = "observability"
  host                   = local.observability.endpoint
  cluster_ca_certificate = base64decode(local.observability.ca_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.observability.name, "--region", local.region]
  }
}

provider "helm" {
  alias = "workload"

  kubernetes {
    host                   = local.workload.endpoint
    cluster_ca_certificate = base64decode(local.workload.ca_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.workload.name, "--region", local.region]
    }
  }
}

provider "helm" {
  alias = "observability"

  kubernetes {
    host                   = local.observability.endpoint
    cluster_ca_certificate = base64decode(local.observability.ca_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.observability.name, "--region", local.region]
    }
  }
}
