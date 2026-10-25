variable "name" {
  description = "Name prefix for network resources."
  type        = string
}

variable "azs" {
  description = "Exactly three availability zones."
  type        = list(string)

  validation {
    condition     = length(var.azs) == 3
    error_message = "Provide exactly three AZs."
  }
}

variable "cidr" {
  description = "VPC CIDR block (/16 recommended)."
  type        = string
  default     = "10.40.0.0/16"
}

variable "cluster_name" {
  description = "EKS cluster name, used for Karpenter subnet discovery tags."
  type        = string
}

variable "single_nat_gateway" {
  description = "Use one NAT gateway for all AZs (cheaper, not AZ-resilient)."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "KMS key for the flow-log log group."
  type        = string
}

variable "log_retention_days" {
  description = "Flow log retention."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
