variable "name" {
  description = "Name prefix."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key that encrypts the backups."
  type        = string
}

variable "retention_days" {
  description = "Days a backup is kept."
  type        = number
  default     = 30
}

variable "force_destroy" {
  description = "Allow destroying the bucket with backups in it (demo teardown)."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
