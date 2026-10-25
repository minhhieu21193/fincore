terraform {
  required_version = "~> 1.17.0"

  # Providers used only inside modules (random, tls, time) are pinned exactly
  # by .terraform.lock.hcl, which is committed.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.70.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.3.0"
    }
  }

  # Partial configuration: terraform init -backend-config=backend.hcl
  # (see backend.hcl.example; the bucket comes from terraform/bootstrap).
  backend "s3" {
    key          = "fincore/demo/terraform.tfstate"
    encrypt      = true
    use_lockfile = true # S3-native locking, no DynamoDB table
  }
}
