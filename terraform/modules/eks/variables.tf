variable "name" {
  description = "Cluster name."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version (minor)."
  type        = string
}

variable "addon_versions" {
  description = "Pinned EKS add-on versions (look up with: aws eks describe-addon-versions --kubernetes-version <v>)."
  type        = map(string)

  validation {
    condition     = alltrue([for a in ["vpc-cni", "eks-pod-identity-agent", "kube-proxy", "coredns", "aws-ebs-csi-driver"] : contains(keys(var.addon_versions), a)])
    error_message = "addon_versions must pin vpc-cni, eks-pod-identity-agent, kube-proxy, coredns and aws-ebs-csi-driver."
  }
}

variable "system_instance_types" {
  description = "Instance types for the system node group (Graviton by default)."
  type        = list(string)
  default     = ["m7g.large"]
}

variable "system_ami_release_version" {
  description = "Pinned EKS AL2023 AMI release for the system node group, e.g. 1.36.5-20261019."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for the control plane ENIs and nodes."
  type        = list(string)
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. Empty = private endpoint only."
  type        = list(string)
}

variable "platform_kms_key_arn" {
  description = "Platform KMS key: Secrets envelope encryption, control-plane logs, EBS."
  type        = string
}

variable "cde_kms_key_arn" {
  description = "Cardholder-data-zone KMS key (payment-events queue, Aurora, CDE secrets)."
  type        = string
}

variable "backups_kms_key_arn" {
  description = "KMS key of the backup bucket."
  type        = string
}

variable "system_node_count" {
  description = "Nodes in the system node group (3 with Vault HA)."
  type        = number
  default     = 3
}

variable "log_retention_days" {
  description = "Control-plane log retention."
  type        = number
  default     = 7
}

variable "hosted_zone_arn" {
  description = "Route 53 hosted zone ExternalDNS and cert-manager may modify."
  type        = string
}

variable "platform_secret_arns" {
  description = "Secrets (platform key) External Secrets may read."
  type        = list(string)
}

variable "cde_secret_arns" {
  description = "Secrets (CDE key) External Secrets may read; the CDE key opens only these."
  type        = list(string)
}

variable "payment_events_queue_arn" {
  description = "Payment events queue (payments-api publishes, notifier consumes)."
  type        = string
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}

variable "vault_enabled" {
  description = "Vault runs in the cluster (Pod Identity roles for Vault and its snapshot job)."
  type        = bool
  default     = true
}

variable "vault_kms_key_arn" {
  description = "KMS key Vault uses for auto-unseal (null without Vault)."
  type        = string
  default     = null
}

variable "ecr_repository_arns" {
  description = "ECR repositories whose signatures and attestations Kyverno verifies."
  type        = list(string)
}

variable "backup_bucket_arn" {
  description = "Backup bucket (Velero cluster state, Vault Raft snapshots)."
  type        = string
}
