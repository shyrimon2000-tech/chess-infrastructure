variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "vpc_id" {
  description = "ID of the VPC where the cluster is deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "IDs of private subnets for EKS nodes and Fargate profiles"
  type        = list(string)
}

variable "tags" {
  description = "Additional tags to apply to all cluster resources"
  type        = map(string)
  default     = {}
}

variable "admin_principal_arn" {
  description = "IAM principal ARN to grant personal cluster-admin access via an EKS access entry — needed once applies stop running as this identity (e.g. once CI takes over and enable_cluster_creator_admin_permissions no longer covers you)"
  type        = string
  default     = ""
}
