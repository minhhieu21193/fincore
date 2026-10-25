# Application secrets in Secrets Manager. External Secrets syncs them into
# the cluster; names match the kind emulator so manifests are identical.
# Phase 2 replaces the static database passwords with Vault dynamic credentials.

resource "random_password" "this" {
  for_each = var.generated
  length   = 40
  special  = false
}

resource "aws_secretsmanager_secret" "this" {
  for_each                = var.generated
  name                    = each.key
  description             = "FinCore ${each.key} (managed by Terraform)"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.recovery_window_in_days
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "this" {
  for_each      = var.generated
  secret_id     = aws_secretsmanager_secret.this[each.key].id
  secret_string = jsonencode({ (each.value) = random_password.this[each.key].result })
}
