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
