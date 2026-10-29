variable "alias" {
  description = "Alias (without the alias/ prefix)."
  type        = string
}

variable "description" {
  description = "Key description."
  type        = string
}

variable "deletion_window_in_days" {
  description = "Waiting period before the key is deleted (7-30)."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}

variable "log_group_arn_patterns" {
  description = "CloudWatch Logs log-group ARN patterns that may be encrypted with this key (empty: none)."
  type        = list(string)
  default     = []
}

variable "via_services" {
  description = "If set, IAM principals may use the key for data only through these services (e.g. [\"sqs\", \"rds\"]); direct Encrypt/Decrypt is denied."
  type        = list(string)
  default     = []
}

variable "autoscaling_service_role" {
  description = "Let the EC2 Auto Scaling service-linked role use the key (EBS volumes of managed node groups)."
  type        = bool
  default     = false
}

variable "spot_service_role" {
  description = "Let the EC2 Spot service-linked role use the key (EBS volumes of Spot instances)."
  type        = bool
  default     = false
}
