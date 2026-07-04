variable "name" {
  description = "Name prefix for frontend resources (e.g. chess-prod) — also the SSM parameter path prefix the frontend repo's CI reads from"
  type        = string
}

variable "public_domain" {
  description = "Existing public Route53 hosted zone domain the frontend record is created in"
  type        = string
  default     = "alexit.online"
}

variable "subdomain" {
  description = "Subdomain prefix for the frontend hostname (e.g. \"chess\" -> chess.alexit.online)"
  type        = string
  default     = "chess"
}

variable "price_class" {
  description = "CloudFront price class — PriceClass_100 (US/Canada/Europe only) is cheapest and sufficient for this project's audience"
  type        = string
  default     = "PriceClass_100"
}

variable "api_origin_hostname" {
  description = "Stable hostname CloudFront routes /api/* to — doesn't resolve to anything at apply time (the ALB it eventually points to is created later by the AWS Load Balancer Controller, not Terraform). ExternalDNS creates the actual Route53 record once the ALB exists. Must match chess-chart's values-prod.yaml ingress.host exactly, or the ALB's listener rule won't match the Host header CloudFront sends."
  type        = string
  default     = "api-origin.alexit.online"
}

variable "origin_mtls_client_certificate_arn" {
  description = "ACM ARN of the client certificate CloudFront presents to the ALB for origin mTLS (see terraform/modules/origin-mtls) — replaces the old X-Origin-Verify shared-secret header as proof of \"this specific distribution\"."
  type        = string
}
