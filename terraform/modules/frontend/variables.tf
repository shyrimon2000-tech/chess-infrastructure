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
