variable "name" {
  description = "Name prefix for RDS resources (e.g. chess-prod) — also the SSM parameter path prefix"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID the RDS instance's security group is created in"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR — RDS security group allows MySQL (3306) ingress from this range only (covers both EKS nodes and a VPN-connected client, same trust model as the chess-chart NetworkPolicy's db.cidr)"
  type        = string
}

variable "database_subnet_ids" {
  description = "IDs of the private database subnets the DB subnet group spans"
  type        = list(string)
}

variable "instance_class" {
  description = "RDS instance class — paired with a 1-year Reserved Instance purchase (done manually in the AWS console/CLI, not something Terraform manages) for the ~$40-50/mo estimate in CLAUDE.md"
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Allocated storage in GiB (gp3)"
  type        = number
  default     = 20
}

variable "engine_version" {
  description = "MySQL engine version"
  type        = string
  default     = "8.0"
}

variable "services" {
  description = "Chess microservices that each get their own database + dedicated MySQL user, scoped to only their own database"
  type        = list(string)
  default     = ["auth", "room", "game"]
}
