# One customer-managed key per data domain. Key administration is delegated to
# IAM in this account; what each key may be used for is narrowed here:
#   - log_group_arn_patterns: the CloudWatch Logs groups the key may encrypt;
#   - via_services: if set, nobody can use the key for data directly, only
#     through these AWS services (e.g. SQS, RDS), so an IAM policy with kms:*
#     still cannot decrypt the domain's data outside them;
#   - autoscaling_service_role: EC2 Auto Scaling may launch instances whose EBS
#     volumes use this key (managed node groups).

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  data_actions = [
    "kms:Encrypt",
    "kms:Decrypt",
    "kms:ReEncrypt*",
    "kms:GenerateDataKey*",
  ]
  autoscaling_role = "arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"
}

data "aws_iam_policy_document" "this" {
  #checkov:skip=CKV_AWS_109:KMS key policy; "*" resource means this key only
  #checkov:skip=CKV_AWS_111:KMS key policy; "*" resource means this key only
  #checkov:skip=CKV_AWS_356:KMS key policy; "*" resource means this key only
  statement {
    sid       = "AccountRoot"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  dynamic "statement" {
    for_each = length(var.log_group_arn_patterns) > 0 ? [1] : []
    content {
      sid       = "CloudWatchLogs"
      actions   = concat(local.data_actions, ["kms:Describe*"])
      resources = ["*"]
      principals {
        type        = "Service"
        identifiers = ["logs.${local.region}.amazonaws.com"]
      }
      condition {
        test     = "ArnLike"
        variable = "kms:EncryptionContext:aws:logs:arn"
        values   = var.log_group_arn_patterns
      }
    }
  }

  # The managed node group's launch template encrypts root volumes with this
  # key; EC2 Auto Scaling launches the instances with its service-linked role,
  # which no IAM policy of ours can grant anything.
  dynamic "statement" {
    for_each = var.autoscaling_service_role ? [1] : []
    content {
      sid       = "AutoScalingUse"
      actions   = concat(local.data_actions, ["kms:DescribeKey"])
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = [local.autoscaling_role]
      }
    }
  }

  dynamic "statement" {
    for_each = var.autoscaling_service_role ? [1] : []
    content {
      sid       = "AutoScalingGrants"
      actions   = ["kms:CreateGrant"]
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = [local.autoscaling_role]
      }
      condition {
        test     = "Bool"
        variable = "kms:GrantIsForAWSResource"
        values   = ["true"]
      }
    }
  }

  # Data-plane calls by IAM principals only through the listed services. AWS
  # service principals (CloudWatch Logs) are exempt; they are scoped above.
  dynamic "statement" {
    for_each = length(var.via_services) > 0 ? [1] : []
    content {
      sid       = "OnlyThroughServices"
      effect    = "Deny"
      actions   = local.data_actions
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = ["*"]
      }
      condition {
        test     = "StringNotEquals"
        variable = "kms:ViaService"
        values   = [for s in var.via_services : "${s}.${local.region}.amazonaws.com"]
      }
      condition {
        test     = "Bool"
        variable = "aws:PrincipalIsAWSService"
        values   = ["false"]
      }
    }
  }
}

resource "aws_kms_key" "this" {
  description             = var.description
  deletion_window_in_days = var.deletion_window_in_days
  enable_key_rotation     = true
  rotation_period_in_days = 90
  policy                  = data.aws_iam_policy_document.this.json
  tags                    = var.tags
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.alias}"
  target_key_id = aws_kms_key.this.key_id
}
