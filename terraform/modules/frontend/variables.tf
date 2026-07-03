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

variable "origin_verify_secret" {
  description = "Shared secret CloudFront sends as the X-Origin-Verify header on every request to the ALB origin — the ALB only forwards requests carrying this exact value (see chess-chart's ingress.alb.originVerifySecret, must match verbatim). Distinguishes this specific CloudFront distribution's traffic from any other CloudFront customer's, on top of the security-group IP restriction to CloudFront's origin-facing prefix list alone. Committed in plaintext in both this module's tfvars and values-prod.yaml — acceptable here because this is a public pet-project repo where that's an accepted, documented tradeoff; a private/closed-source repo wouldn't have this exposure at all since repo access is already restricted, and a real production team would likely pull this from a secret store injected at deploy time instead of committing it either way."
  type        = string
  sensitive   = true
}
