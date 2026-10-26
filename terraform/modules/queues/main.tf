# Payment events queue with a dead-letter queue. The same names and redrive
# policy are emulated by ElasticMQ on kind (gitops/platform/local-infra).

resource "aws_sqs_queue" "dlq" {
  name                              = "${var.name}-dlq"
  message_retention_seconds         = 1209600 # 14 days: time to investigate
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = 300
  tags                              = var.tags
}

resource "aws_sqs_queue" "main" {
  name                              = var.name
  visibility_timeout_seconds        = var.visibility_timeout_seconds
  message_retention_seconds         = 345600 # 4 days
  receive_wait_time_seconds         = 10
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = 300

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
  tags = var.tags
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main.arn]
  })
}

data "aws_iam_policy_document" "tls_only" {
  for_each = { main = aws_sqs_queue.main.arn, dlq = aws_sqs_queue.dlq.arn }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [each.value]
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
}

resource "aws_sqs_queue_policy" "tls_only" {
  for_each  = { main = aws_sqs_queue.main.id, dlq = aws_sqs_queue.dlq.id }
  queue_url = each.value
  policy    = data.aws_iam_policy_document.tls_only[each.key].json
}
