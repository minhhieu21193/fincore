variable "name" {
  description = "Queue name; the DLQ is <name>-dlq."
  type        = string
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for server-side encryption."
  type        = string
}

variable "visibility_timeout_seconds" {
  description = "Default visibility timeout; the notifier extends it per message on failure."
  type        = number
  default     = 30
}

variable "max_receive_count" {
  description = "Receives before a message is moved to the DLQ."
  type        = number
  default     = 5
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
