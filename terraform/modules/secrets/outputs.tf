output "secret_arns" {
  description = "Secret ARNs by name."
  value       = { for k, s in aws_secretsmanager_secret.this : k => s.arn }
}
