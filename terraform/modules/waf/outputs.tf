output "web_acl_arn" {
  description = "Web ACL ARN (ingress annotation alb.ingress.kubernetes.io/wafv2-acl-arn)."
  value       = aws_wafv2_web_acl.this.arn
}
