variable "name" {
  description = "Cluster identifier."
  type        = string
}

variable "engine_version" {
  description = "Aurora PostgreSQL version (pinned)."
  type        = string
}

variable "min_acu" {
  description = "Minimum Aurora capacity units per instance (0 enables auto-pause)."
  type        = number
  default     = 0.5
}

variable "max_acu" {
  description = "Maximum Aurora capacity units per instance."
  type        = number
  default     = 8
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "db_subnet_group_name" {
  description = "DB subnet group (database subnets)."
  type        = string
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to connect on 5432 (label => SG ID)."
  type        = map(string)
}

variable "kms_key_arn" {
  description = "KMS key for storage, secrets, logs and Performance Insights."
  type        = string
}

variable "backup_retention_days" {
  description = "Automated backup retention."
  type        = number
  default     = 7
}

variable "log_retention_days" {
  description = "PostgreSQL log retention."
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "Protect the cluster from deletion (true in production)."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy (demo teardown)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
