# Offline: every provider is mocked, nothing is called. Run with
# `terraform test` in this directory (scripts/check.sh does).
# Checks which KMS key each workload may use, and for what.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_region" {
    defaults = { region = "ap-southeast-1", name = "ap-southeast-1" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "000000000000", arn = "arn:aws:iam::000000000000:user/test" }
  }
  mock_data "aws_iam_session_context" {
    defaults = { issuer_arn = "arn:aws:iam::000000000000:role/test" }
  }
}
mock_provider "tls" {}
mock_provider "time" {}
mock_provider "cloudinit" {}
mock_provider "null" {}

variables {
  name                       = "fincore-demo"
  kubernetes_version         = "1.36"
  addon_versions             = { vpc-cni = "v1.0.0-eksbuild.1", eks-pod-identity-agent = "v1.0.0-eksbuild.1", kube-proxy = "v1.0.0-eksbuild.1", coredns = "v1.0.0-eksbuild.1", aws-ebs-csi-driver = "v1.0.0-eksbuild.1" }
  system_ami_release_version = "1.36.5-20261019"
  vpc_id                     = "vpc-0123456789abcdef0"
  private_subnet_ids         = ["subnet-0a", "subnet-0b", "subnet-0c"]
  public_access_cidrs        = []
  platform_kms_key_arn       = "arn:aws:kms:ap-southeast-1:000000000000:key/platform"
  cde_kms_key_arn            = "arn:aws:kms:ap-southeast-1:000000000000:key/cde"
  backups_kms_key_arn        = "arn:aws:kms:ap-southeast-1:000000000000:key/backups"
  vault_kms_key_arn          = "arn:aws:kms:ap-southeast-1:000000000000:key/vault"
  hosted_zone_arn            = "arn:aws:route53:::hostedzone/Z0000000000000000000"
  platform_secret_arns       = ["arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:fincore-webhook-signing-AbCdEf"]
  cde_secret_arns            = ["arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:fincore-payments-db-AbCdEf"]
  payment_events_queue_arn   = "arn:aws:sqs:ap-southeast-1:000000000000:fincore-demo-payment-events"
  backup_bucket_arn          = "arn:aws:s3:::fincore-demo-backups-000000000000"
  ecr_repository_arns        = ["arn:aws:ecr:ap-southeast-1:000000000000:repository/fincore/ledger"]
}

run "cde_workloads_use_only_the_cde_key_for_their_queue" {
  command = plan

  # payments-api: encrypt and decrypt, CDE key only, through SQS, this queue only.
  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.payments_api.statement :
      !anytrue([for a in s.actions : startswith(a, "kms:")]) || (
        toset(s.resources) == toset([var.cde_kms_key_arn]) &&
        toset(s.actions) == toset(["kms:GenerateDataKey", "kms:Decrypt"]) &&
        anytrue([for c in s.condition : c.test == "StringEquals" && c.variable == "kms:ViaService" && toset(c.values) == toset(["sqs.ap-southeast-1.amazonaws.com"])]) &&
        anytrue([for c in s.condition : c.test == "StringEquals" && c.variable == "kms:EncryptionContext:aws:sqs:arn" && toset(c.values) == toset([var.payment_events_queue_arn])])
      )
    ])
    error_message = "payments-api may use only the CDE key, through SQS, for the payment-events queue."
  }
  # notifier: decrypt only, same constraints.
  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.notifier.statement :
      !anytrue([for a in s.actions : startswith(a, "kms:")]) || (
        toset(s.resources) == toset([var.cde_kms_key_arn]) &&
        toset(s.actions) == toset(["kms:Decrypt"]) &&
        anytrue([for c in s.condition : c.test == "StringEquals" && c.variable == "kms:ViaService" && toset(c.values) == toset(["sqs.ap-southeast-1.amazonaws.com"])]) &&
        anytrue([for c in s.condition : c.test == "StringEquals" && c.variable == "kms:EncryptionContext:aws:sqs:arn" && toset(c.values) == toset([var.payment_events_queue_arn])])
      )
    ])
    error_message = "The notifier may only decrypt with the CDE key, through SQS, for the payment-events queue."
  }
  # Both actually have a KMS statement (the checks above pass vacuously otherwise).
  assert {
    condition = (
      anytrue([for s in data.aws_iam_policy_document.payments_api.statement : contains(s.actions, "kms:GenerateDataKey")]) &&
      anytrue([for s in data.aws_iam_policy_document.notifier.statement : contains(s.actions, "kms:Decrypt")])
    )
    error_message = "payments-api and the notifier need their CDE key statements."
  }
}

run "other_workloads_stay_in_their_domain" {
  command = plan

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.backups.statement :
      !anytrue([for a in s.actions : startswith(a, "kms:")]) || (
        toset(s.resources) == toset([var.backups_kms_key_arn]) &&
        anytrue([for c in s.condition : c.variable == "kms:EncryptionContext:aws:s3:arn"])
      )
    ])
    error_message = "Backup writers may use only the backups key, for the backup bucket."
  }
  # External Secrets: every KMS statement is bound to Secrets Manager and to
  # the secrets of that key's domain; no unconditioned Decrypt on any key.
  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.external_secrets.statement :
      !anytrue([for a in s.actions : startswith(a, "kms:")]) || (
        toset(s.actions) == toset(["kms:Decrypt"]) && length(s.resources) == 1 &&
        anytrue([for c in s.condition : c.test == "StringEquals" && c.variable == "kms:ViaService" && toset(c.values) == toset(["secretsmanager.ap-southeast-1.amazonaws.com"])]) &&
        anytrue([for c in s.condition : c.test == "StringEquals" && c.variable == "kms:EncryptionContext:SecretARN" && toset(c.values) == toset(
          contains(s.resources, var.cde_kms_key_arn) ? var.cde_secret_arns : var.platform_secret_arns
        )])
      )
    ])
    error_message = "External Secrets may open each key only through Secrets Manager, for that key's secrets."
  }
  assert {
    condition = (
      anytrue([for s in data.aws_iam_policy_document.external_secrets.statement : toset(s.resources) == toset([var.platform_kms_key_arn])]) &&
      anytrue([for s in data.aws_iam_policy_document.external_secrets.statement : toset(s.resources) == toset([var.cde_kms_key_arn])])
    )
    error_message = "External Secrets needs a (conditioned) statement for the platform key and for the CDE key."
  }
  assert {
    condition     = length(data.aws_iam_policy_document.vault) == 1
    error_message = "With Vault, its auto-unseal policy exists."
  }
}

run "karpenter_uses_node_keys_only_through_ec2" {
  command = plan

  assert {
    condition = alltrue([
      for st in local.karpenter_ebs_kms_statements :
      toset(st.resources) == toset([var.platform_kms_key_arn, var.cde_kms_key_arn]) &&
      anytrue([for c in st.condition : c.test == "StringEquals" && c.variable == "kms:ViaService" && toset(c.values) == toset(["ec2.ap-southeast-1.amazonaws.com"])])
    ])
    error_message = "The Karpenter controller may use the platform and CDE keys only through EC2."
  }
  assert {
    condition = alltrue([
      for st in local.karpenter_ebs_kms_statements :
      !contains(st.actions, "kms:CreateGrant") ||
      anytrue([for c in st.condition : c.variable == "kms:GrantIsForAWSResource" && toset(c.values) == toset(["true"])])
    ])
    error_message = "Karpenter may create grants only for AWS resources."
  }
  assert {
    condition = toset(flatten([for st in local.karpenter_ebs_kms_statements : st.actions])) == toset([
      "kms:CreateGrant", "kms:GenerateDataKeyWithoutPlaintext", "kms:Decrypt", "kms:ReEncrypt*", "kms:DescribeKey",
    ])
    error_message = "Karpenter gets exactly what EC2 needs to launch encrypted volumes (no Encrypt, no GenerateDataKey with plaintext)."
  }
}

run "small_team_has_no_vault_roles" {
  command = plan

  variables {
    vault_enabled     = false
    vault_kms_key_arn = null
    system_node_count = 2
  }

  assert {
    condition     = length(data.aws_iam_policy_document.vault) == 0
    error_message = "Without Vault there is no auto-unseal policy."
  }
  assert {
    condition     = module.vault_pod_identity.iam_role_arn == null && module.vault_snapshot_pod_identity.iam_role_arn == null
    error_message = "Without Vault there are no Vault or Vault-snapshot roles."
  }
}
