output "client_certificate_arn" {
  description = "ACM ARN of the client certificate CloudFront presents for origin mTLS — feeds the frontend module's origin_mtls_config"
  value       = aws_acm_certificate.client.arn
}

output "trust_store_arn" {
  description = "ALB trust store ARN — copy into chess-chart's values-prod.yaml alb.ingress.kubernetes.io/mutual-authentication annotation (also written to SSM for discoverability)"
  value       = aws_lb_trust_store.this.arn
}

output "alb_certificate_arn" {
  description = "ALB's own server certificate ARN — copy into chess-chart's values-prod.yaml alb.ingress.kubernetes.io/certificate-arn (also written to SSM for discoverability)"
  value       = aws_acm_certificate_validation.alb.certificate_arn
}
