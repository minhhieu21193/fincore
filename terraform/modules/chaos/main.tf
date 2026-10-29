# AWS Fault Injection Service: losing one availability zone. The experiment
# cuts all network traffic of the zone's private and database subnets for a
# fixed time, as an AZ outage would. It never starts by itself:
# scripts/chaos-aws.sh starts it, and an alarm on the payments 5xx rate can
# stop it early.

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["fis.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fis" {
  name               = "${var.name}-fis"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "network" {
  role       = aws_iam_role.fis.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSFaultInjectionSimulatorNetworkAccess"
}

resource "aws_fis_experiment_template" "az_loss" {
  description = "Lose ${var.zone}: no traffic in or out of its private and database subnets for ${var.duration}"
  role_arn    = aws_iam_role.fis.arn

  action {
    name      = "disrupt-zone"
    action_id = "aws:network:disrupt-connectivity"
    parameter {
      key   = "duration"
      value = var.duration
    }
    parameter {
      key   = "scope"
      value = "all"
    }
    target {
      key   = "Subnets"
      value = "zone-subnets"
    }
  }

  target {
    name           = "zone-subnets"
    resource_type  = "aws:ec2:subnet"
    selection_mode = "ALL"
    resource_arns  = var.subnet_arns
  }

  dynamic "stop_condition" {
    for_each = var.stop_alarm_arn == null ? ["none"] : []
    content {
      source = "none"
    }
  }
  dynamic "stop_condition" {
    for_each = var.stop_alarm_arn == null ? [] : [var.stop_alarm_arn]
    content {
      source = "aws:cloudwatch:alarm"
      value  = stop_condition.value
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-az-loss" })
}
