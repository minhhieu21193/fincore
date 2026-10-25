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

module "network" {
  source             = "../../modules/network"
  name               = local.name
  cidr               = var.vpc_cidr
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
    "fincore-ledger-db"       = "password"
    "fincore-webhook-signing" = "secret"
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
  tags                       = local.tags
}

module "aurora" {
  source               = "../../modules/aurora"
  name                 = local.name
  engine_version       = var.aurora_engine_version
  min_acu              = var.aurora_min_acu
  max_acu              = var.aurora_max_acu
  vpc_id               = module.network.vpc_id
  db_subnet_group_name = module.network.database_subnet_group_name
  allowed_security_group_ids = {
    nodes   = module.eks.node_security_group_id
    cluster = module.eks.cluster_primary_security_group_id
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
