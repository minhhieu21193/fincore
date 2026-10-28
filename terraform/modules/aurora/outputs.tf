output "endpoint" {
  description = "Writer endpoint."
  value       = module.aurora.cluster_endpoint
}

output "reader_endpoint" {
  description = "Reader endpoint."
  value       = module.aurora.cluster_reader_endpoint
}

output "master_user_secret_arn" {
  description = "Secrets Manager ARN of the RDS-managed master credentials."
  value       = module.aurora.cluster_master_user_secret[0].secret_arn
}

output "cluster_id" {
  description = "Aurora cluster identifier (for failover)."
  value       = module.aurora.cluster_id
}
