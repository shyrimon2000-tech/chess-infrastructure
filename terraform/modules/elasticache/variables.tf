variable "name" {
  description = "Name prefix for ElastiCache resources (e.g. chess-prod) — also the SSM parameter path prefix"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID the ElastiCache security group is created in"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR — Redis security group allows ingress (6379) from this range only, same trust model as the rds module's db.cidr rule"
  type        = string
}

variable "database_subnet_ids" {
  description = "IDs of the private database subnets the cache subnet group spans — same subnets RDS uses"
  type        = list(string)
}

variable "node_type" {
  description = "ElastiCache node instance class"
  type        = string
  default     = "cache.t3.micro"
}

variable "engine_version" {
  description = "Redis engine version"
  type        = string
  default     = "7.1"
}

# ── Passed in from the rds module via a terragrunt `dependency` block ────────
# room and game both need DATABASE_URL — this module composes and writes
# their complete SSM secrets (DATABASE_URL + REDIS_URL + JWT_SECRET_KEY) as
# sole owner, since it's the one that also knows REDIS_URL. See rds module's
# README note for why rds itself doesn't write these two parameters.

variable "room_database_url" {
  description = "room service's DATABASE_URL, from the rds module's output"
  type        = string
  sensitive   = true
}

variable "game_database_url" {
  description = "game service's DATABASE_URL, from the rds module's output"
  type        = string
  sensitive   = true
}

variable "jwt_secret_key" {
  description = "Shared JWT secret, from the rds module's output (itself read from the manually created /chess-prod/jwt-secret-key SSM parameter)"
  type        = string
  sensitive   = true
}
