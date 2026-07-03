variable "zone_name" {
  description = "Private hosted zone domain name"
  type        = string
  default     = "chess.internal"
}

variable "vpc_id" {
  description = "VPC the private hosted zone is associated with"
  type        = string
}

variable "load_balancer_hostname" {
  description = "DNS hostname of the internal ingress-nginx NLB that each record in var.records points to"
  type        = string
}

variable "records" {
  description = "Subdomain names to create as CNAME records in the private zone, each pointing at load_balancer_hostname (e.g. [\"argocd\"] for a zone that only needs to route admin traffic)"
  type        = list(string)
  default     = ["dev", "staging", "argocd"]
}
