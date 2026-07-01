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
  description = "DNS hostname of the internal ingress-nginx NLB that dev/staging/argocd records point to"
  type        = string
}
