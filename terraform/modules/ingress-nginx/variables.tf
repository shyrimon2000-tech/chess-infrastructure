variable "ingress_nginx_version" {
  description = "ingress-nginx Helm chart version (verify current release before apply)"
  type        = string
  default     = "4.11.3"
}
