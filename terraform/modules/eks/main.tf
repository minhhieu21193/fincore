# EKS control plane, a small managed "system" node group for cluster
# controllers (Argo CD, Karpenter, add-ons), Karpenter for everything else,
# and EKS Pod Identity roles for each in-cluster AWS client.
#
# The system nodes are labelled (fincore.io/node-role=system) but not tainted:
# platform controllers must be able to start before Karpenter exists.

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  endpoint_private_access      = true
  endpoint_public_access       = length(var.public_access_cidrs) > 0
  endpoint_public_access_cidrs = var.public_access_cidrs

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  enabled_log_types                      = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  cloudwatch_log_group_retention_in_days = var.log_retention_days
  cloudwatch_log_group_kms_key_id        = var.kms_key_arn

  # Envelope encryption of Kubernetes Secrets with our key.
  create_kms_key = false
  encryption_config = {
    provider_key_arn = var.kms_key_arn
    resources        = ["secrets"]
  }

  addons = {
    vpc-cni = {
      before_compute = true
      addon_version  = var.addon_versions["vpc-cni"]
      # Enforce Kubernetes NetworkPolicies (the cardholder-data zone boundary).
      # "standard" enforcing mode: a new pod is allowed until its policies are
      # programmed (about a second). Strict mode closes that window but denies
      # every pod without a policy cluster-wide, so it needs policies for all
      # platform namespaces first (see docs/compliance-mapping.md, gaps).
      configuration_values = jsonencode({ enableNetworkPolicy = "true" })
    }
    eks-pod-identity-agent = { before_compute = true, addon_version = var.addon_versions["eks-pod-identity-agent"] }
    kube-proxy             = { addon_version = var.addon_versions["kube-proxy"] }
    coredns                = { addon_version = var.addon_versions["coredns"] }
    # Persistent volumes (Vault's Raft storage).
    aws-ebs-csi-driver = {
      addon_version = var.addon_versions["aws-ebs-csi-driver"]
      pod_identity_association = [{
        role_arn        = module.ebs_csi_pod_identity.iam_role_arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  eks_managed_node_groups = {
    system = {
      ami_type            = "AL2023_ARM_64_STANDARD"
      ami_release_version = var.system_ami_release_version
      instance_types      = var.system_instance_types
      capacity_type       = "ON_DEMAND"
      min_size            = 2
      max_size            = 3
      desired_size        = 2
      labels = {
        "fincore.io/node-role" = "system"
      }
      # Vault runs here; this group is one of the two that Aurora admits.
      vpc_security_group_ids = [aws_security_group.system_nodes.id]
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 40
            volume_type           = "gp3"
            encrypted             = true
            kms_key_id            = var.kms_key_arn
            delete_on_termination = true
          }
        }
      }
    }
  }

  # Karpenter discovers the node security group by this tag.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.name
  }

  tags = var.tags
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.29.0"

  cluster_name = module.eks.cluster_name

  # Controller credentials via EKS Pod Identity (kube-system/karpenter).
  create_pod_identity_association = true
  namespace                       = "kube-system"
  service_account                 = "karpenter"

  # Spot interruption handling: SQS queue fed by EventBridge rules.
  enable_spot_termination = true

  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${var.name}-karpenter-node"
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Node security groups that mark where database clients may run. They carry no
# rules of their own (cluster traffic is governed by the shared node group);
# Aurora admits exactly these two.

resource "aws_security_group" "cde_nodes" {
  #checkov:skip=CKV2_AWS_5:Attached to cardholder-data-zone nodes by Karpenter's EC2NodeClass "cde" (selected by tag)
  name        = "${var.name}-cde-nodes"
  description = "Cardholder-data-zone nodes (Karpenter NodePool cde)"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-cde-nodes", "fincore.io/security-group" = "cde" })
}

resource "aws_security_group" "system_nodes" {
  #checkov:skip=CKV2_AWS_5:Attached to the system managed node group through the EKS module (vpc_security_group_ids)
  name        = "${var.name}-system-nodes"
  description = "System node group (cluster controllers and Vault)"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-system-nodes" })
}

# ---------------------------------------------------------------------------
# Pod Identity: one role per in-cluster AWS client, least privilege.

module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name                      = "${var.name}-ebs-csi"
  attach_aws_ebs_csi_policy = true
  aws_ebs_csi_kms_arns      = [var.kms_key_arn]
  tags                      = var.tags
}

# Vault auto-unseal: the dedicated key only, and only the three calls the seal makes.
data "aws_iam_policy_document" "vault" {
  statement {
    sid       = "AutoUnseal"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
    resources = [var.vault_kms_key_arn]
  }
}

module "vault_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name                    = "${var.name}-vault"
  attach_custom_policy    = true
  source_policy_documents = [data.aws_iam_policy_document.vault.json]
  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "vault"
      service_account = "vault"
    }
  }
  tags = var.tags
}

# Kyverno reads image signatures and SBOM attestations from ECR.
data "aws_iam_policy_document" "kyverno" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "ReadSignatures"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
    resources = var.ecr_repository_arns
  }
}

module "kyverno_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name                    = "${var.name}-kyverno"
  attach_custom_policy    = true
  source_policy_documents = [data.aws_iam_policy_document.kyverno.json]
  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kyverno"
      service_account = "kyverno-admission-controller"
    }
  }
  tags = var.tags
}

module "aws_lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name                            = "${var.name}-aws-lb-controller"
  attach_aws_lb_controller_policy = true
  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
  tags = var.tags
}

module "external_dns_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name                          = "${var.name}-external-dns"
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = [var.hosted_zone_arn]
  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "external-dns"
      service_account = "external-dns"
    }
  }
  tags = var.tags
}

module "cert_manager_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name                          = "${var.name}-cert-manager"
  attach_cert_manager_policy    = true
  cert_manager_hosted_zone_arns = [var.hosted_zone_arn]
  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "cert-manager"
      service_account = "cert-manager"
    }
  }
  tags = var.tags
}

module "external_secrets_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name                                  = "${var.name}-external-secrets"
  attach_external_secrets_policy        = true
  external_secrets_secrets_manager_arns = var.secrets_manager_arns
  external_secrets_kms_key_arns         = [var.kms_key_arn]
  external_secrets_create_permission    = false
  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "external-secrets"
      service_account = "external-secrets"
    }
  }
  tags = var.tags
}

data "aws_iam_policy_document" "payments_api" {
  statement {
    sid       = "PublishPaymentEvents"
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
    resources = [var.payment_events_queue_arn]
  }
  statement {
    sid       = "EncryptMessages"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

module "payments_api_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name                    = "${var.name}-payments-api"
  attach_custom_policy    = true
  source_policy_documents = [data.aws_iam_policy_document.payments_api.json]
  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "fincore-cde"
      service_account = "payments-api"
    }
  }
  tags = var.tags
}

data "aws_iam_policy_document" "notifier" {
  statement {
    sid = "ConsumePaymentEvents"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [var.payment_events_queue_arn]
  }
  statement {
    sid       = "DecryptMessages"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

module "notifier_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name                    = "${var.name}-notifier"
  attach_custom_policy    = true
  source_policy_documents = [data.aws_iam_policy_document.notifier.json]
  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "fincore"
      service_account = "notifier"
    }
  }
  tags = var.tags
}
