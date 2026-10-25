provider "aws" {
  region = var.region

  # Guard rail: refuse to run against any account other than the one intended.
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = local.tags
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
