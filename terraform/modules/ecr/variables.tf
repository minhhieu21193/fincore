variable "prefix" {
  description = "Repository name prefix, e.g. fincore -> fincore/payments-api."
  type        = string
}

variable "repositories" {
  description = "Repository names (one per service image)."
  type        = list(string)
}

variable "kms_key_arn" {
  description = "KMS key for image encryption."
  type        = string
}

variable "keep_images" {
  description = "Images retained per repository."
  type        = number
  default     = 30
}

variable "force_delete" {
  description = "Allow terraform destroy to delete repositories that still contain images (demo teardown)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
