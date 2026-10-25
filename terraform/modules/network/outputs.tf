output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "VPC CIDR."
  value       = module.vpc.vpc_cidr_block
}

output "azs" {
  description = "Availability zones in use."
  value       = local.azs
}

output "private_subnet_ids" {
  description = "Private subnets (nodes and pods)."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnets (internet-facing load balancers)."
  value       = module.vpc.public_subnets
}

output "database_subnet_group_name" {
  description = "DB subnet group for Aurora."
  value       = module.vpc.database_subnet_group_name
}
