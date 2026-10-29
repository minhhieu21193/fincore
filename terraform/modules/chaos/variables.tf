variable "name" {
  description = "Name prefix."
  type        = string
}

variable "zone" {
  description = "Availability zone the experiment takes out."
  type        = string
}

variable "subnet_arns" {
  description = "Subnets of that zone (private and database)."
  type        = list(string)
}

variable "duration" {
  description = "How long the zone is lost (ISO 8601)."
  type        = string
  default     = "PT5M"
}

variable "stop_alarm_arn" {
  description = "CloudWatch alarm that stops the experiment early (null: runs for the full duration)."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
