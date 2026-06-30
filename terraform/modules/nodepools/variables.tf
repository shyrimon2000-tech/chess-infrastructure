variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "node_iam_role_name" {
  description = "IAM role name for nodes provisioned by Karpenter"
  type        = string
}

variable "simplified" {
  description = "If true, forces Spot capacity type (used for shared/dev environment)"
  type        = bool
  default     = false
}
