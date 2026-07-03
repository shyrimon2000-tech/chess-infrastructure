variable "name" {
  description = "Name prefix for this environment (e.g. chess-shared) — scopes the IRSA policy to /<name>/* in Parameter Store"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider for IRSA"
  type        = string
}

variable "eso_version" {
  description = "External Secrets Operator Helm chart version (verify current release before apply — see external-secrets/external-secrets releases)"
  type        = string
  default     = "0.10.7"
}
