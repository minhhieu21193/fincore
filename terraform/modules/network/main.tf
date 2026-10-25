# VPC across three AZs: public subnets (load balancers, NAT), private subnets
# (all nodes and pods), database subnets (Aurora). Interface endpoints keep
# ECR pulls, STS, SQS and Secrets Manager traffic off the NAT gateway.

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.name
  cidr = var.cidr
  azs  = local.azs

  private_subnets  = [for i in range(3) : cidrsubnet(var.cidr, 4, i)]      # /20 each: room for pod IPs
  public_subnets   = [for i in range(3) : cidrsubnet(var.cidr, 8, 48 + i)] # /24
  database_subnets = [for i in range(3) : cidrsubnet(var.cidr, 8, 52 + i)] # /24

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway # one NAT for the demo; one per AZ in production
  one_nat_gateway_per_az = !var.single_nat_gateway

  enable_dns_hostnames = true
  enable_dns_support   = true

  create_database_subnet_group       = true
  create_database_subnet_route_table = true

  map_public_ip_on_launch = false

  # Lock down the default security group (no rules).
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_retention_in_days = var.log_retention_days
  flow_log_cloudwatch_log_group_kms_key_id        = var.kms_key_arn

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = var.cluster_name
  }

  tags = var.tags
}

resource "aws_security_group" "endpoints" {
  name        = "${var.name}-vpc-endpoints"
  description = "HTTPS from inside the VPC to interface endpoints"
  vpc_id      = module.vpc.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  description       = "HTTPS from the VPC"
  cidr_ipv4         = module.vpc.vpc_cidr_block
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

module "endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "6.7.3"

  vpc_id             = module.vpc.vpc_id
  security_group_ids = [aws_security_group.endpoints.id]

  endpoints = merge(
    {
      s3 = {
        service         = "s3"
        service_type    = "Gateway"
        route_table_ids = module.vpc.private_route_table_ids
        tags            = { Name = "${var.name}-s3" }
      }
    },
    {
      for svc in ["ecr.api", "ecr.dkr", "sts", "sqs", "secretsmanager"] : replace(svc, ".", "_") => {
        service             = svc
        private_dns_enabled = true
        subnet_ids          = module.vpc.private_subnets
        tags                = { Name = "${var.name}-${svc}" }
      }
    },
  )

  tags = var.tags
}
