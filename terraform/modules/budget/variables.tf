variable "name" {
  description = "Budget name prefix."
  type        = string
}

variable "project_tag" {
  description = "Value of the Project cost-allocation tag to filter on (activate the tag in Billing first)."
  type        = string
}

variable "monthly_limit_usd" {
  description = "Monthly budget for resources tagged with the project."
  type        = number
}

variable "account_limit_usd" {
  description = "Monthly budget for the whole account (backstop)."
  type        = number
}

variable "alert_emails" {
  description = "E-mail addresses notified by the budget."
  type        = list(string)

  validation {
    condition     = length(var.alert_emails) > 0
    error_message = "At least one alert e-mail is required."
  }
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
