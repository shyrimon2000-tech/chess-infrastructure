variable "name" {
  description = "Name prefix for resources (e.g. chess-prod)"
  type        = string
}

variable "public_domain" {
  description = "Existing public Route53 hosted zone domain the ALB's own certificate is DNS-validated in"
  type        = string
  default     = "alexit.online"
}

variable "api_origin_hostname" {
  description = "Hostname the ALB's HTTPS listener certificate covers — must match frontend module's api_origin_hostname and chess-chart's values-prod.yaml ingress.host exactly"
  type        = string
  default     = "api-origin.alexit.online"
}
