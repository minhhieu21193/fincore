output "trail_arn" {
  description = "CloudTrail ARN."
  value       = aws_cloudtrail.this.arn
}

output "bucket_name" {
  description = "S3 bucket receiving the trail."
  value       = aws_s3_bucket.this.id
}

output "log_group_name" {
  description = "CloudWatch log group receiving the trail."
  value       = aws_cloudwatch_log_group.this.name
}
