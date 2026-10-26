output "repository_arns" {
  description = "Repository ARNs by short name."
  value       = { for k, r in aws_ecr_repository.this : k => r.arn }
}

output "registry" {
  description = "Registry host (<account>.dkr.ecr.<region>.amazonaws.com)."
  value       = split("/", one(values(aws_ecr_repository.this)).repository_url)[0]
}
