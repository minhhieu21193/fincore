output "cluster_name" {
  description = "EKS cluster name (aws eks update-kubeconfig --name <this>)."
  value       = module.eks.cluster_name
}

output "github_deploy_role_arn" {
  description = "Set as the AWS_DEPLOY_ROLE_ARN variable in the GitHub repository."
  value       = module.github_oidc.role_arn
}

output "ecr_registry" {
  description = "Set as the ECR_REGISTRY variable in the GitHub repository."
  value       = module.ecr.registry
}

output "api_url" {
  description = "Public payments API URL."
  value       = "https://api.${var.domain}"
}

output "payment_events_queue_url" {
  description = "Payment events queue."
  value       = module.queues.queue_url
}

output "payment_events_dlq_url" {
  description = "Payment events dead-letter queue."
  value       = module.queues.dlq_url
}

output "aurora_endpoint" {
  description = "Aurora writer endpoint."
  value       = module.aurora.endpoint
}

output "aurora_cluster_id" {
  description = "Aurora cluster identifier (scripts/chaos-aws.sh failover)."
  value       = module.aurora.cluster_id
}

output "fis_az_loss_template_id" {
  description = "FIS experiment template: lose the first availability zone (scripts/chaos-aws.sh)."
  value       = module.chaos.az_loss_template_id
}
