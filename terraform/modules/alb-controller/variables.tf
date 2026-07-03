variable "name" {
  description = "Name prefix for IAM resources (e.g. chess-prod)"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name the controller manages Ingress resources for"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS cluster's OIDC provider ARN, for the controller's IRSA trust policy"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID the controller discovers subnets/security groups in"
  type        = string
}

variable "chart_version" {
  description = "aws-load-balancer-controller Helm chart version"
  type        = string
  default     = "3.4.0"
}
