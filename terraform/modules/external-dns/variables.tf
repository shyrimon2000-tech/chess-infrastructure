variable "name" {
  description = "Name prefix for IAM resources (e.g. chess-prod)"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — used only for tagging/context, ExternalDNS itself is cluster-agnostic"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS cluster's OIDC provider ARN, for the controller's IRSA trust policy"
  type        = string
}

variable "domain_filter" {
  description = "Public hosted zone domain ExternalDNS is allowed to manage records in — restricts it from touching any other zone in the account"
  type        = string
  default     = "alexit.online"
}

variable "chart_version" {
  description = "external-dns Helm chart version"
  type        = string
  default     = "1.21.1"
}
