variable "name" {
  description = "Trail name (also prefixes the bucket, key alias and log group)."
  type        = string
}

variable "retention_days" {
  description = "Retention of audit logs in S3 and CloudWatch (PCI DSS 10.5.1: at least 12 months)."
  type        = number
  default     = 365
}

variable "force_destroy" {
  description = "Allow destroying the bucket with objects in it (demo teardown). Keep false in production."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
