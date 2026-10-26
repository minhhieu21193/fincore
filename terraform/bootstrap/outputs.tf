output "state_bucket" {
  description = "Use as `bucket` in terraform/envs/*/backend.hcl."
  value       = aws_s3_bucket.state.bucket
}

output "state_kms_key_arn" {
  description = "KMS key encrypting the state."
  value       = aws_kms_key.state.arn
}
