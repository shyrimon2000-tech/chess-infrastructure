variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "node_iam_role_name" {
  description = "IAM role name for nodes provisioned by Karpenter"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider for IRSA (used by the EBS CSI driver's service account)"
  type        = string
}

variable "consolidation_policy" {
  description = "Karpenter consolidation policy (WhenEmpty for prod, WhenEmptyOrUnderutilized for shared)"
  type        = string
}

variable "consolidate_after" {
  description = "How long a node must be underutilized before consolidation (e.g. 30s for shared, 5m for prod)"
  type        = string
}

variable "use_spot" {
  description = "If true, uses Spot instances (shared/dev). If false, uses on-demand (prod)."
  type        = bool
  default     = false
}

variable "cpu_limit" {
  description = "Maximum total CPU Karpenter can provision across all nodes (e.g. \"8\")"
  type        = string
  default     = "8"
}

variable "memory_limit" {
  description = "Maximum total memory Karpenter can provision across all nodes (e.g. \"32Gi\")"
  type        = string
  default     = "32Gi"
}
