terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Local state. A single-operator lab that is created and destroyed in one
  # sitting gains nothing from S3+DynamoDB, and the bucket would outlive the
  # thing it tracks.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}
