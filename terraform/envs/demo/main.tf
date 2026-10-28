locals {
  name = "${var.project}-${var.environment}"
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = var.github_repository
  }
  services = ["payments-api", "ledger", "notifier", "webhook-sink"]
}

data "aws_route53_zone" "this" {
  name         = var.domain
  private_zone = false
}

module "kms" {
  source      = "../../modules/kms"
  alias       = local.name
  description = "FinCore ${var.environment}: SQS, Secrets Manager, Aurora, ECR, EKS secrets, logs"
  tags        = local.tags
}

# Vault auto-unseal: its own key, usable only by Vault's Pod Identity role.
module "vault_kms" {
  source                  = "../../modules/kms"
  alias                   = "${local.name}-vault-unseal"
  description             = "FinCore ${var.environment}: Vault auto-unseal"
  deletion_window_in_days = 30
  tags                    = local.tags
}

module "network" {
  source             = "../../modules/network"
  name               = local.name
  cidr               = var.vpc_cidr
  azs                = var.azs
  cluster_name       = local.name
  single_nat_gateway = var.single_nat_gateway
  kms_key_arn        = module.kms.key_arn
  tags               = local.tags
}

module "queues" {
  source      = "../../modules/queues"
  name        = "${local.name}-payment-events"
  kms_key_arn = module.kms.key_arn
  tags        = local.tags
}

module "ecr" {
  source       = "../../modules/ecr"
  prefix       = var.project
  repositories = local.services
  kms_key_arn  = module.kms.key_arn
  tags         = local.tags
}

module "secrets" {
  source = "../../modules/secrets"
  generated = {
    "fincore-payments-db"     = "password"
    "fincore-webhook-signing" = "secret"
    # Bootstrap password of Vault's database admin role; Vault rotates it on
    # first use. The ledger has no static password (Vault-issued users).
    "fincore-vault-db-admin" = "password"
  }
  kms_key_arn = module.kms.key_arn
  tags        = local.tags
}

module "eks" {
  source                     = "../../modules/eks"
  name                       = local.name
  kubernetes_version         = var.kubernetes_version
  addon_versions             = var.eks_addon_versions
  system_ami_release_version = var.system_ami_release_version
  system_instance_types      = var.system_instance_types
  vpc_id                     = module.network.vpc_id
  private_subnet_ids         = module.network.private_subnet_ids
  public_access_cidrs        = var.eks_public_access_cidrs
  kms_key_arn                = module.kms.key_arn
  hosted_zone_arn            = data.aws_route53_zone.this.arn
  secrets_manager_arns       = concat(values(module.secrets.secret_arns), [module.aurora.master_user_secret_arn])
  payment_events_queue_arn   = module.queues.queue_arn
  vault_kms_key_arn          = module.vault_kms.key_arn
  backup_bucket_arn          = module.backups.bucket_arn
  ecr_repository_arns        = values(module.ecr.repository_arns)
  tags                       = local.tags
}

module "backups" {
  source      = "../../modules/backups"
  name        = local.name
  kms_key_arn = module.kms.key_arn
  tags        = local.tags
}

module "aurora" {
  source               = "../../modules/aurora"
  name                 = local.name
  engine_version       = var.aurora_engine_version
  min_acu              = var.aurora_min_acu
  max_acu              = var.aurora_max_acu
  vpc_id               = module.network.vpc_id
  db_subnet_group_name = module.network.database_subnet_group_name
  # Only the cardholder-data-zone nodes and the system nodes (Vault) reach the database.
  allowed_security_group_ids = {
    cde-nodes    = module.eks.cde_nodes_security_group_id
    system-nodes = module.eks.system_nodes_security_group_id
  }
  kms_key_arn = module.kms.key_arn
  tags        = local.tags
}

module "budget" {
  source            = "../../modules/budget"
  name              = local.name
  project_tag       = var.project
  monthly_limit_usd = var.budget_monthly_usd
  account_limit_usd = var.budget_account_usd
  alert_emails      = var.budget_alert_emails
  tags              = local.tags
}

module "github_oidc" {
  source              = "../../modules/github-oidc"
  github_repository   = var.github_repository
  create_provider     = var.create_github_oidc_provider
  role_name           = "${local.name}-github-deploy"
  ecr_repository_arns = values(module.ecr.repository_arns)
  tags                = local.tags
}

# ACM certificate for the public API (the ALB controller discovers it by host).
resource "aws_acm_certificate" "api" {
  domain_name       = "api.${var.domain}"
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "api_validation" {
  for_each = {
    for o in aws_acm_certificate.api.domain_validation_options : o.domain_name => o
  }
  zone_id = data.aws_route53_zone.this.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "api" {
  certificate_arn         = aws_acm_certificate.api.arn
  validation_record_fqdns = [for r in aws_route53_record.api_validation : r.fqdn]
}

# Edge protection for the public API (attached to the ALB by ingress annotation).
module "waf" {
  source              = "../../modules/waf"
  name                = local.name
  rate_limit_per_5min = var.waf_rate_limit_per_5min
  kms_key_arn         = module.kms.key_arn
  tags                = local.tags
}

# Account audit trail (CloudTrail -> S3 + CloudWatch Logs).
module "audit" {
  source        = "../../modules/audit"
  name          = local.name
  force_destroy = var.audit_force_destroy
  tags          = local.tags
}
