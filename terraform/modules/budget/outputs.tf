output "budget_name" {
  description = "Project budget name."
  value       = aws_budgets_budget.monthly.name
}
