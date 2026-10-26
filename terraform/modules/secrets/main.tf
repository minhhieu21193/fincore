# Application secrets in Secrets Manager. External Secrets syncs them into
# the cluster; names match the kind emulator so manifests are identical.
# The ledger has no entry here: Vault issues its database users (Phase 2).

resource "random_password" "this" {
  for_each = var.generated
  length   = 40
  special  = false
}

resource "aws_secretsmanager_secret" "this" {
  #checkov:skip=CKV2_AWS_57:Rotation is handled per secret: Vault rotates its admin password on first use and issues short-lived ledger users; payments-api moves to Vault next; webhook secret rotation is coordinated with merchants
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
