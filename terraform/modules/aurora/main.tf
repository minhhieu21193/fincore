# Aurora PostgreSQL Serverless v2: a writer and a reader in different AZs so
# a failover can be exercised (Phase 3). The master password is generated and
# rotated by RDS in Secrets Manager; applications use their own roles created
# by the db-init job (gitops/apps/fincore-base).

module "aurora" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "10.4.1"

  name           = var.name
  engine         = "aurora-postgresql"
  engine_mode    = "provisioned"
  engine_version = var.engine_version

  cluster_instance_class = "db.serverless"
  instances = {
    writer = {}
    reader = {}
  }
  serverlessv2_scaling_configuration = {
    min_capacity = var.min_acu
    max_capacity = var.max_acu
  }

  vpc_id                 = var.vpc_id
  db_subnet_group_name   = var.db_subnet_group_name
  create_db_subnet_group = false
  security_group_ingress_rules = {
    for k, sg in var.allowed_security_group_ids : k => {
      description                  = "PostgreSQL from ${k}"
      referenced_security_group_id = sg
      from_port                    = 5432
      to_port                      = 5432
    }
  }

  master_username                      = "fincore_admin"
  manage_master_user_password          = true
  master_user_secret_kms_key_id        = var.kms_key_arn
  manage_master_user_password_rotation = false

  storage_encrypted                   = true
  kms_key_id                          = var.kms_key_arn
  iam_database_authentication_enabled = true

  cluster_parameter_group = {
    family      = "aurora-postgresql17"
    description = "FinCore Aurora PostgreSQL 17"
    parameters = [
      { name = "rds.force_ssl", value = "1", apply_method = "immediate" },
      { name = "log_min_duration_statement", value = "500", apply_method = "immediate" },
    ]
  }

  enabled_cloudwatch_logs_exports        = ["postgresql"]
  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = var.log_retention_days
  cloudwatch_log_group_kms_key_id        = var.kms_key_arn

  cluster_performance_insights_enabled    = true
  cluster_performance_insights_kms_key_id = var.kms_key_arn
  cluster_monitoring_interval             = 60

  backup_retention_period    = var.backup_retention_days
  preferred_backup_window    = "17:00-18:00" # 00:00-01:00 Asia/Singapore
  copy_tags_to_snapshot      = true
  deletion_protection        = var.deletion_protection
  skip_final_snapshot        = var.skip_final_snapshot
  auto_minor_version_upgrade = false # versions are pinned; upgrades are deliberate
  apply_immediately          = true

  tags = var.tags
}
