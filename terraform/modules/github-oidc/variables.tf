variable "github_repository" {
  description = "owner/name of the repository allowed to assume the role."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Use the form owner/name."
  }
}

variable "allowed_branches" {
  description = "Branches whose workflows may assume the role."
  type        = list(string)
  default     = ["main"]
}

variable "create_provider" {
  description = "Create the GitHub OIDC provider (false if the account already has one)."
  type        = bool
  default     = true
}

variable "role_name" {
  description = "Name of the deploy role."
  type        = string
}

variable "ecr_repository_arns" {
  description = "Repositories the role may push to."
  type        = list(string)
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
