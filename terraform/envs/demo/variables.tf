variable "aws_account_id" {
  description = "The only AWS account this configuration may touch (provider allowed_account_ids guard)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "Must be a 12-digit account ID."
  }
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Project name, used in resource names and the Project cost-allocation tag."
  type        = string
  default     = "fincore"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "demo"
}

variable "domain" {
  description = "Public Route 53 hosted zone the demo may use (e.g. demo.example.com). The API is served at api.<domain>."
  type        = string
}

variable "acme_email" {
  description = "Contact e-mail for Let's Encrypt (cert-manager)."
  type        = string
}

variable "github_repository" {
  description = "owner/name of the GitHub repository (GitOps source and OIDC trust)."
  type        = string
  default     = "minhhieu21193/fincore"
}

variable "gitops_revision" {
  description = "Git revision Argo CD tracks."
  type        = string
  default     = "main"
}

variable "create_github_oidc_provider" {
  description = "Create the account-wide GitHub OIDC provider (false if it already exists)."
  type        = bool
  default     = true
}

variable "azs" {
  description = "Three availability zones in the region."
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
}

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.40.0.0/16"
}

variable "single_nat_gateway" {
  description = "One NAT gateway for all AZs (demo cost saving)."
  type        = bool
  default     = true
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.36"
}

variable "eks_addon_versions" {
  description = <<-EOT
    Pinned EKS add-on versions for kubernetes_version. vpc-cni, coredns and kube-proxy
    defaults are the versions the EKS user guide lists for 1.36 (checked 2026-10-26).
    eks-pod-identity-agent and aws-ebs-csi-driver have no published table: look them up with
    `aws eks describe-addon-versions --addon-name <name> --kubernetes-version 1.36`.
  EOT
  type        = map(string)
}

variable "system_ami_release_version" {
  description = "EKS AL2023 AMI release for the system node group (github.com/awslabs/amazon-eks-ami/releases)."
  type        = string
  default     = "1.36.5-20261019"
}

variable "system_instance_types" {
  description = "System node group instance types."
  type        = list(string)
  default     = ["m7g.large"]
}

variable "eks_public_access_cidrs" {
  description = "CIDRs allowed to reach the EKS API (your IP/32). Empty makes the endpoint private only."
  type        = list(string)

  validation {
    condition     = !contains(var.eks_public_access_cidrs, "0.0.0.0/0")
    error_message = "Do not expose the EKS API to the whole internet."
  }
}

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL version."
  type        = string
  default     = "17.11"
}

variable "aurora_min_acu" {
  description = "Aurora Serverless v2 minimum ACUs per instance."
  type        = number
  default     = 0.5
}

variable "aurora_max_acu" {
  description = "Aurora Serverless v2 maximum ACUs per instance."
  type        = number
  default     = 8
}

variable "budget_monthly_usd" {
  description = "Monthly budget for resources tagged Project=<project>."
  type        = number
  default     = 100
}

variable "budget_account_usd" {
  description = "Monthly budget for the whole account (backstop)."
  type        = number
  default     = 150
}

variable "budget_alert_emails" {
  description = "Budget alert recipients."
  type        = list(string)
}

variable "waf_rate_limit_per_5min" {
  description = "Requests per client IP per 5 minutes before AWS WAF blocks it."
  type        = number
  default     = 2000
}

variable "audit_force_destroy" {
  description = "Let terraform destroy the CloudTrail bucket with its logs (one-day demo account only)."
  type        = bool
  default     = false
}
