# Offline: the AWS provider is mocked, nothing is called. Run with
# `terraform test` in this directory (scripts/check.sh does).

mock_provider "aws" {
  # Mocks do not render policy documents; the assertions read their statements.
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "000000000000" }
  }
  override_data {
    target = data.aws_partition.current
    values = { partition = "aws" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "ap-southeast-1" }
  }
}

variables {
  alias       = "test"
  description = "test"
}

run "default_key_is_administered_through_iam_only" {
  command = plan

  assert {
    condition     = length(data.aws_iam_policy_document.this.statement) == 1
    error_message = "A key with no options must have only the account-root statement."
  }
  assert {
    condition     = aws_kms_key.this.enable_key_rotation && aws_kms_key.this.rotation_period_in_days == 90
    error_message = "Every key rotates every 90 days."
  }
}

run "cde_key_only_through_its_services" {
  command = plan

  variables {
    via_services           = ["sqs", "rds", "secretsmanager", "ec2"]
    log_group_arn_patterns = ["arn:aws:logs:ap-southeast-1:000000000000:log-group:/aws/rds/cluster/fincore-demo/*"]
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.this.statement :
      s.sid == "OnlyThroughServices" && s.effect == "Deny" &&
      contains(s.actions, "kms:Decrypt") && contains(s.actions, "kms:GenerateDataKey*") &&
      anytrue([for c in s.condition :
        c.test == "StringNotEquals" && c.variable == "kms:ViaService" &&
        toset(c.values) == toset(["sqs.ap-southeast-1.amazonaws.com", "rds.ap-southeast-1.amazonaws.com", "secretsmanager.ap-southeast-1.amazonaws.com", "ec2.ap-southeast-1.amazonaws.com"])
      ]) &&
      anytrue([for c in s.condition : c.variable == "aws:PrincipalIsAWSService" && toset(c.values) == toset(["false"])])
    ])
    error_message = "The CDE key must deny direct data use outside SQS, RDS, Secrets Manager and EC2 (node volumes)."
  }
  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.this.statement :
      s.sid == "CloudWatchLogs" && anytrue([for c in s.condition :
        toset(c.values) == toset(["arn:aws:logs:ap-southeast-1:000000000000:log-group:/aws/rds/cluster/fincore-demo/*"])
      ])
    ])
    error_message = "CloudWatch Logs may use the CDE key for Aurora's log groups only."
  }
  assert {
    condition     = !anytrue([for s in data.aws_iam_policy_document.this.statement : startswith(coalesce(s.sid, "-"), "AutoScaling")])
    error_message = "EC2 Auto Scaling has no business with the CDE key."
  }
  assert {
    condition = !anytrue([for s in data.aws_iam_policy_document.this.statement : anytrue([
      for p in s.principals : anytrue([for i in p.identifiers : strcontains(i, "AWSServiceRoleForEC2Spot")])
    ])])
    error_message = "The CDE NodePool is on-demand only: the Spot service-linked role gets nothing on the CDE key."
  }
}

run "platform_key_launches_node_group_volumes" {
  command = plan

  variables {
    autoscaling_service_role = true
    spot_service_role        = true
    log_group_arn_patterns   = ["arn:aws:logs:ap-southeast-1:000000000000:log-group:*"]
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.this.statement :
      s.sid == "AutoScalingGrants" && contains(s.actions, "kms:CreateGrant") &&
      anytrue([for c in s.condition : c.variable == "kms:GrantIsForAWSResource" && toset(c.values) == toset(["true"])])
    ])
    error_message = "The Auto Scaling service-linked role may create grants for AWS resources only."
  }
  # Karpenter's general nodes try Spot first: EC2 launches Spot instances with
  # its Spot service-linked role, which must be able to use the volume key.
  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.this.statement :
      s.sid == "SpotUse" &&
      anytrue([for p in s.principals : contains(p.identifiers, "arn:aws:iam::000000000000:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot")]) &&
      toset(s.actions) == toset(["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]) &&
      length(s.condition) == 0
    ])
    error_message = "The Spot service-linked role may use the platform key (data actions and DescribeKey)."
  }
  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.this.statement :
      s.sid == "SpotGrants" && toset(s.actions) == toset(["kms:CreateGrant"]) &&
      anytrue([for p in s.principals : contains(p.identifiers, "arn:aws:iam::000000000000:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot")]) &&
      anytrue([for c in s.condition : c.variable == "kms:GrantIsForAWSResource" && toset(c.values) == toset(["true"])])
    ])
    error_message = "The Spot service-linked role may create grants for AWS resources only."
  }
  assert {
    condition     = !anytrue([for s in data.aws_iam_policy_document.this.statement : s.effect == "Deny"])
    error_message = "The platform key has no via-service restriction (EKS and EBS call it directly)."
  }
}
