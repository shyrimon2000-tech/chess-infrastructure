output "iam_role_arn" {
  description = "IRSA role ARN the controller runs as"
  value       = aws_iam_role.this.arn
}
