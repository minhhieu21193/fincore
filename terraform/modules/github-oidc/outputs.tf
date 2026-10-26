output "role_arn" {
  description = "Deploy role ARN (set as the AWS_DEPLOY_ROLE_ARN repository variable in GitHub)."
  value       = aws_iam_role.deploy.arn
}
