output "provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider"
  value       = aws_iam_openid_connect_provider.github.arn
}

output "shared_role_arn" {
  description = "ARN of the IAM role assumable by workflow runs on the dev branch (shared environment: plan+apply against dev/staging)"
  value       = aws_iam_role.shared.arn
}

output "prod_role_arn" {
  description = "ARN of the IAM role assumable by workflow runs on the main branch (prod environment)"
  value       = aws_iam_role.prod.arn
}
