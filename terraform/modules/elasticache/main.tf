locals {
  # room and game share one REDIS_URL, not isolated per-service logical DBs
  # — Redis here is for cross-service game-state pub/sub (see CLAUDE.md),
  # so both services need to see the same keyspace/channels, not their own
  # private slice of it. DB index 0 — no reason to pick another.
  redis_url = "redis://${aws_elasticache_cluster.this.cache_nodes[0].address}:${aws_elasticache_cluster.this.port}/0"
}

# ── Networking — same private database subnets as rds, no public access ──────

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name}-redis"
  subnet_ids = var.database_subnet_ids
}

resource "aws_security_group" "redis" {
  name_prefix = "${var.name}-redis-"
  vpc_id      = var.vpc_id

  # VPC CIDR, not a specific security-group reference — same trust model as
  # the rds module's MySQL ingress rule: covers both EKS pods and a
  # VPN-connected client alike.
  ingress {
    description = "Redis from anywhere inside the VPC"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Redis — single node, no replication group ─────────────────────────────
# A room-service Spot interruption already can't happen (prod nodepools are
# on-demand — see CLAUDE.md), and this project doesn't need automatic
# multi-AZ failover for a personal-project cache tier. A production team
# with real availability requirements would use aws_elasticache_replication_group
# instead (multi-AZ, automatic failover, at-rest encryption) — trading cost
# and complexity for HA this project doesn't need.

resource "aws_elasticache_cluster" "this" {
  cluster_id           = "${var.name}-redis"
  engine               = "redis"
  engine_version       = var.engine_version
  node_type            = var.node_type
  num_cache_nodes      = 1
  port                 = 6379
  parameter_group_name = "default.redis7"

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]
}

# ── SSM — sole owner of /chess-prod/room and /chess-prod/game ─────────────
# rds deliberately doesn't write these (see terraform/modules/rds/main.tf) —
# this module combines its own REDIS_URL with rds's DATABASE_URL/JWT
# outputs (passed in as variables via a terragrunt `dependency` block) and
# writes the complete secret once, as the only Terraform resource that ever
# manages these two SSM parameters.

resource "aws_ssm_parameter" "room_secret" {
  name      = "/${var.name}/room"
  type      = "SecureString"
  overwrite = true
  value = jsonencode({
    DATABASE_URL   = var.room_database_url
    REDIS_URL      = local.redis_url
    JWT_SECRET_KEY = var.jwt_secret_key
  })
}

resource "aws_ssm_parameter" "game_secret" {
  name      = "/${var.name}/game"
  type      = "SecureString"
  overwrite = true
  value = jsonencode({
    DATABASE_URL   = var.game_database_url
    REDIS_URL      = local.redis_url
    JWT_SECRET_KEY = var.jwt_secret_key
  })
}
