terraform {
  # >= 1.10 for S3-native state locking (use_lockfile) — no DynamoDB table needed.
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Bucket/key/region are supplied at `terraform init` time via -backend-config
  # flags (see .github/workflows/deploy.yml) so nothing account-specific has to
  # be committed here. Locking uses S3's native lockfile — no DynamoDB.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}
