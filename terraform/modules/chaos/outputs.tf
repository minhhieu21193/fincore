output "az_loss_template_id" {
  description = "FIS experiment template that loses one zone."
  value       = aws_fis_experiment_template.az_loss.id
}
