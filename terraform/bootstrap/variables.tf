variable "aws_account_id" {
  description = "The only AWS account this configuration may touch."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "Must be a 12-digit account ID."
  }
}

variable "region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Project name used in the bucket name."
  type        = string
  default     = "fincore"
}
