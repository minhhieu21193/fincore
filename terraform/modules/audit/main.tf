# Account audit trail: a multi-region CloudTrail with log-file integrity
# validation, encrypted with its own KMS key, delivered to a private, versioned
# S3 bucket (kept 365 days) and to CloudWatch Logs for search and alerting.
# EKS control-plane logs and the Vault audit device complete the audit picture.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  trail_arn  = "arn:${local.partition}:cloudtrail:${local.region}:${local.account_id}:trail/${var.name}"
  bucket     = "${var.name}-cloudtrail-${local.account_id}"
}

# ---------------------------------------------------------------- KMS
data "aws_iam_policy_document" "kms" {
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
  statement {
    sid       = "CloudTrailEncrypt"
    actions   = ["kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:${local.partition}:cloudtrail:*:${local.account_id}:trail/*"]
    }
  }
  statement {
    sid = "CloudWatchLogs"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"]
    }
  }
}

resource "aws_kms_key" "this" {
  description             = "FinCore audit trail (CloudTrail)"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  rotation_period_in_days = 90
  policy                  = data.aws_iam_policy_document.kms.json
  tags                    = var.tags
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}-audit"
  target_key_id = aws_kms_key.this.key_id
}

# ---------------------------------------------------------------- S3
resource "aws_s3_bucket" "this" {
  #checkov:skip=CKV_AWS_18:This bucket is the audit sink itself; access to it is recorded by the CloudTrail data plane and S3 server access logs would need another bucket of the same kind
  #checkov:skip=CKV_AWS_144:Single-region demo; cross-region replication of audit logs is noted in docs/compliance-mapping.md as a production step
  #checkov:skip=CKV2_AWS_62:No consumer for object-created events; CloudTrail is also delivered to CloudWatch Logs for alerting
  bucket        = local.bucket
  force_destroy = var.force_destroy
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.this.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    id     = "retain-then-expire"
    status = "Enabled"
    filter {}
    expiration {
      days = var.retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = var.retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
  statement {
    sid       = "CloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.this.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
  statement {
    sid       = "CloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this.arn}/AWSLogs/${local.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json
}

# ---------------------------------------------------------------- CloudWatch Logs delivery
resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/cloudtrail/${var.name}"
  retention_in_days = var.retention_days
  kms_key_id        = aws_kms_key.this.arn
  tags              = var.tags
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "delivery" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:log-stream:*"]
  }
}

resource "aws_iam_role" "delivery" {
  name               = "${var.name}-cloudtrail-logs"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "delivery" {
  name   = "deliver-to-cloudwatch-logs"
  role   = aws_iam_role.delivery.id
  policy = data.aws_iam_policy_document.delivery.json
}

# ---------------------------------------------------------------- trail
resource "aws_cloudtrail" "this" {
  #checkov:skip=CKV_AWS_252:Alerting reads the CloudWatch Logs delivery; an SNS topic per log file is not needed
  name                          = var.name
  s3_bucket_name                = aws_s3_bucket.this.id
  kms_key_id                    = aws_kms_key.this.arn
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.this.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.delivery.arn

  # Management events in every region.
  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  tags = var.tags

  depends_on = [aws_s3_bucket_policy.this]
}
