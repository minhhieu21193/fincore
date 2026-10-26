output "queue_url" {
  description = "Main queue URL."
  value       = aws_sqs_queue.main.id
}

output "queue_arn" {
  description = "Main queue ARN."
  value       = aws_sqs_queue.main.arn
}

output "dlq_url" {
  description = "Dead-letter queue URL."
  value       = aws_sqs_queue.dlq.id
}

output "dlq_arn" {
  description = "Dead-letter queue ARN."
  value       = aws_sqs_queue.dlq.arn
}
