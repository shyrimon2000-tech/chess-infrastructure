variable "name" {
  description = "Name prefix for VPC resources"
  type        = string
}

variable "cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zones to deploy subnets into"
  type        = list(string)
}

variable "public_subnets" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
}

variable "private_subnets" {
  description = "CIDR blocks for private subnets (one per AZ)"
  type        = list(string)
}

variable "database_subnets" {
  description = "CIDR blocks for database subnets (one per AZ); empty disables subnet group creation"
  type        = list(string)
  default     = []
}

variable "private_subnet_tags" {
  description = "Additional tags for private subnets (e.g. EKS internal-elb and cluster discovery tags)"
  type        = map(string)
  default     = {}
}

variable "public_subnet_tags" {
  description = "Additional tags for public subnets (e.g. EKS elb and cluster discovery tags)"
  type        = map(string)
  default     = {}
}
