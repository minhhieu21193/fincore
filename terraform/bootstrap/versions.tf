terraform {
  required_version = "~> 1.17.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.70.0"
    }
  }
  # Local state on purpose: this creates the remote state bucket itself.
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}
