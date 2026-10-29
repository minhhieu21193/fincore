locals {
  name = "${var.project}-${var.environment}"
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = var.github_repository
  }
  services  = ["payments-api", "ledger", "notifier", "webhook-sink"]
  partition = data.aws_partition.current.partition
  vault     = var.secrets_backend == "vault"
}

data "aws_partition" "current" {}

data "aws_route53_zone" "this" {
  name         = var.domain
  private_zone = false
}

# One customer-managed key per data domain, so a grant on one never opens
# another (docs/compliance-mapping.md):
#   cde      cardholder-data zone data: the payment-events queue, Aurora
#            (storage, logs, Performance Insights) and the secrets that open it
#   platform the cluster: EKS Secrets, EBS, ECR images, VPC/EKS/WAF logs
#   backups  the backup bucket (Velero cluster state, Vault snapshots)
#   vault    Vault auto-unseal (only with secrets_backend = "vault")
# The audit trail has its own key in modules/audit.
module "cde_kms" {
  source      = "../../modules/kms"
  alias       = "${local.name}-cde"
  description = "FinCore ${var.environment}: cardholder-data zone (SQS, Aurora, its secrets)"
  # Usable for data only through the services that hold CDE data.
  via_services            = ["sqs", "rds", "secretsmanager"]
  log_group_arn_patterns  = ["arn:${local.partition}:logs:${var.region}:${var.aws_account_id}:log-group:/aws/rds/cluster/${local.name}/*"]
  deletion_window_in_days = 30
  tags                    = local.tags
}

module "platform_kms" {
  source                   = "../../modules/kms"
  alias                    = "${local.name}-platform"
  description              = "FinCore ${var.environment}: EKS Secrets, EBS, ECR, platform logs"
  log_group_arn_patterns   = ["arn:${local.partition}:logs:${var.region}:${var.aws_account_id}:log-group:*"]
  autoscaling_service_role = true
  tags                     = local.tags
}

module "backups_kms" {
  source                  = "../../modules/kms"
  alias                   = "${local.name}-backups"
  description             = "FinCore ${var.environment}: backups (Velero, Vault snapshots)"
  via_services            = ["s3"]
  deletion_window_in_days = 30
  tags                    = local.tags
}

# Vault auto-unseal: its own key, usable only by Vault's Pod Identity role.
module "vault_kms" {
  count                   = local.vault ? 1 : 0
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
  kms_key_arn        = module.platform_kms.key_arn
  tags               = local.tags
}

module "queues" {
  source      = "../../modules/queues"
  name        = "${local.name}-payment-events"
  kms_key_arn = module.cde_kms.key_arn
  tags        = local.tags
}

module "ecr" {
  source       = "../../modules/ecr"
  prefix       = var.project
  repositories = local.services
  kms_key_arn  = module.platform_kms.key_arn
  tags         = local.tags
}

# Secrets that open the cardholder-data zone's database are CDE data.
module "cde_secrets" {
  source = "../../modules/secrets"
  generated = local.vault ? {
    # Bootstrap password of Vault's database admin role; Vault rotates it on
    # first use. The ledger has no static password (Vault-issued users).
    "fincore-payments-db"    = "password"
    "fincore-vault-db-admin" = "password"
    } : {
    # secrets_backend = "secrets-manager": the ledger logs in with a static
    # password, like payments-api (docs/compliance-mapping.md, small-team profile).
    "fincore-payments-db" = "password"
    "fincore-ledger-db"   = "password"
  }
  kms_key_arn = module.cde_kms.key_arn
  tags        = local.tags
}

module "platform_secrets" {
  source      = "../../modules/secrets"
  generated   = { "fincore-webhook-signing" = "secret" }
  kms_key_arn = module.platform_kms.key_arn
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
  system_node_count          = var.system_node_count
  platform_kms_key_arn       = module.platform_kms.key_arn
  cde_kms_key_arn            = module.cde_kms.key_arn
  backups_kms_key_arn        = module.backups_kms.key_arn
  hosted_zone_arn            = data.aws_route53_zone.this.arn
  platform_secret_arns       = values(module.platform_secrets.secret_arns)
  cde_secret_arns            = concat(values(module.cde_secrets.secret_arns), [module.aurora.master_user_secret_arn])
  payment_events_queue_arn   = module.queues.queue_arn
  vault_enabled              = local.vault
  vault_kms_key_arn          = local.vault ? module.vault_kms[0].key_arn : null
  backup_bucket_arn          = module.backups.bucket_arn
  ecr_repository_arns        = values(module.ecr.repository_arns)
  tags                       = local.tags
}

module "backups" {
  source      = "../../modules/backups"
  name        = local.name
  kms_key_arn = module.backups_kms.key_arn
  tags        = local.tags
}

module "chaos" {
  source      = "../../modules/chaos"
  name        = local.name
  zone        = module.network.azs[0]
  subnet_arns = [module.network.private_subnet_arns[0], module.network.database_subnet_arns[0]]
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
  # Only the cardholder-data-zone nodes and, with Vault, the system nodes (where
  # Vault runs) reach the database.
  allowed_security_group_ids = merge(
    { cde-nodes = module.eks.cde_nodes_security_group_id },
    local.vault ? { system-nodes = module.eks.system_nodes_security_group_id } : {},
  )
  kms_key_arn = module.cde_kms.key_arn
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
  kms_key_arn         = module.platform_kms.key_arn
  tags                = local.tags
}

# Account audit trail (CloudTrail -> S3 + CloudWatch Logs).
module "audit" {
  source        = "../../modules/audit"
  name          = local.name
  force_destroy = var.audit_force_destroy
  tags          = local.tags
}
