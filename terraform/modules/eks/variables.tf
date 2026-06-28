variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type    = string
  default = "1.31"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "infra_node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "infra_node_count" {
  type    = number
  default = 2
}

variable "tags" {
  type    = map(string)
  default = {}
}
