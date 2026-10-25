variable "generated" {
  description = "Secrets to create with a random value: secret name => JSON property holding the value."
  type        = map(string)
}

variable "kms_key_arn" {
  description = "KMS key used to encrypt the secrets."
  type        = string
}

variable "recovery_window_in_days" {
  description = "0 deletes immediately on destroy (demo teardown); 7-30 in production."
  type        = number
  default     = 0
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
