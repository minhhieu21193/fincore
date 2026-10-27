output "cluster_name" {
  description = "Cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 cluster CA."
  value       = module.eks.cluster_certificate_authority_data
}

output "node_security_group_id" {
  description = "Security group shared by all nodes."
  value       = module.eks.node_security_group_id
}

output "cluster_primary_security_group_id" {
  description = "EKS-managed cluster security group."
  value       = module.eks.cluster_primary_security_group_id
}

output "karpenter_node_role_name" {
  description = "IAM role for Karpenter-launched nodes."
  value       = module.karpenter.node_iam_role_name
}

output "karpenter_interruption_queue" {
  description = "SQS queue for Spot interruption events."
  value       = module.karpenter.queue_name
}

output "cde_nodes_security_group_id" {
  description = "Security group of cardholder-data-zone nodes."
  value       = aws_security_group.cde_nodes.id
}

output "system_nodes_security_group_id" {
  description = "Security group of the system node group (Vault)."
  value       = aws_security_group.system_nodes.id
}
