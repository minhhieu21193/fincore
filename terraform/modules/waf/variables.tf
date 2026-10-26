variable "name" {
  description = "Web ACL name."
  type        = string
}

variable "rate_limit_per_5min" {
  description = "Requests per client IP in any 5-minute window before it is blocked."
  type        = number
  default     = 2000
}

variable "kms_key_arn" {
  description = "KMS key for the WAF log group."
  type        = string
}

variable "log_retention_days" {
  description = "Retention of WAF logs."
  type        = number
  default     = 365
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
