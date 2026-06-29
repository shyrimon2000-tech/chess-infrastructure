variable "cluster_name" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "karpenter_version" {
  type    = string
  default = "1.3.3"
}