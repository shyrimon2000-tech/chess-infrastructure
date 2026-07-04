locals {
  # "auth" doesn't need Redis, "room"/"game" do — but all three get an
  # identical database + dedicated user here regardless. The JWT secret is
  # shared across all three (auth issues tokens, room/game verify them), not
  # generated per-service.
  db_urls = {
    for svc in var.services :
    svc => "mysql+pymysql://${svc}_user:${random_password.db_user[svc].result}@${aws_db_instance.this.address}:${aws_db_instance.this.port}/${svc}_db"
  }
}

# ── Networking — private database subnets only, no public access ─────────────

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-rds"
  subnet_ids = var.database_subnet_ids
}

resource "aws_security_group" "rds" {
  name_prefix = "${var.name}-rds-"
  vpc_id      = var.vpc_id

  # VPC CIDR, not a specific security-group reference — covers both EKS pods
  # (wherever Karpenter happens to place them) and a VPN-connected Terraform
  # apply client (split-tunnel routes the VPC CIDR through the tunnel, so a
  # connected laptop looks like a VPC-internal address). Same trust model as
  # the chess-chart NetworkPolicy's prod `db.cidr` egress rule — see README.
  ingress {
    description = "MySQL from anywhere inside the VPC"
    from_port   = 3306
    to_port     = 3306
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

# ── RDS instance ────────────────────────────────────────────────────────────
# Master password and JWT secret are both manually created SSM SecureString
# parameters (Terraform only reads them, never generates them) — same
# pattern as the ArgoCD admin password hash and wg-easy VPN password.
# Neither this "manual" choice nor the Terraform-generated per-service
# passwords below actually change what ends up in Terraform state — any
# resource attribute (aws_db_instance.password, this SSM value) is stored in
# state regardless of where its value originated. What manual creation does
# change is *source of truth*: these two are human-chosen/rotated outside
# Terraform's control, matching every other admin-facing secret in this repo.

data "aws_ssm_parameter" "master_password" {
  name            = "/${var.name}/rds/master-password"
  with_decryption = true
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name}-mysql"
  engine         = "mysql"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  multi_az = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  # Master user is for admin access (you set this password yourself, you
  # know it, connect with any MySQL client once on the VPN) and for this
  # module's own `mysql` provider below to create the three per-service
  # databases/users — application pods never see or use these credentials,
  # they get their own dedicated per-database user via DATABASE_URL (see
  # locals.db_urls).
  username = "admin"
  password = data.aws_ssm_parameter.master_password.value

  # Personal-project tradeoffs, not what a production team would ship as-is:
  # skip_final_snapshot avoids a lingering manual snapshot on every teardown
  # cycle (this project tears prod down between sessions — see README);
  # deletion_protection off for the same reason (would otherwise block that
  # same teardown). A production team would want both the opposite way,
  # backed by a real change-control step to disable protection intentionally.
  skip_final_snapshot = true
  deletion_protection = false

  backup_retention_period = 1
}

# ── Per-service databases + dedicated, scoped MySQL users ─────────────────────
# Connects over the real MySQL wire protocol — only reachable from inside the
# VPC (RDS is in private database subnets, publicly_accessible = false), so
# `terraform apply` for this module only succeeds while connected to prod's
# VPN (or from inside the VPC, e.g. the future ecs-runner) — same operational
# constraint as any `kubectl`/`helm` provider call against the EKS API.

provider "mysql" {
  endpoint = aws_db_instance.this.endpoint
  username = aws_db_instance.this.username
  password = data.aws_ssm_parameter.master_password.value
}

resource "mysql_database" "this" {
  for_each = toset(var.services)
  name     = "${each.value}_db"
}

resource "random_password" "db_user" {
  for_each = toset(var.services)
  length   = 32
  special  = false
}

resource "mysql_user" "this" {
  for_each           = toset(var.services)
  user               = "${each.value}_user"
  host               = "%"
  plaintext_password = random_password.db_user[each.value].result
}

# Full privileges, but scoped to exactly one database each — the isolation
# boundary is "which database", not "which SQL statements": alembic's
# `upgrade head` (see README Troubleshooting) needs DDL (CREATE/ALTER/DROP
# TABLE), not just DML, so a narrower privilege set would break migrations.
resource "mysql_grant" "this" {
  for_each   = toset(var.services)
  user       = mysql_user.this[each.value].user
  host       = mysql_user.this[each.value].host
  database   = mysql_database.this[each.value].name
  privileges = ["ALL PRIVILEGES"]
}

# ── SSM — auth's secret is complete right now (no Redis dependency) ───────────
# room/game deliberately are NOT written here — see terraform/modules/rds
# README note / commit message: writing them here and having the elasticache
# module overwrite the same parameter later would mean two different
# Terraform states both trying to own one AWS resource. Instead this module
# only exposes room/game's DATABASE_URL + the shared JWT secret as outputs;
# the elasticache module (applied after) reads them via a terragrunt
# `dependency` block and writes the complete `/chess-prod/room` /
# `/chess-prod/game` parameters itself, as sole owner.

# Manually created SecureString, like the master password above — this is
# an app-wide secret shared by auth/room/game, not something specific to
# RDS, so it lives at the top level of the /chess-prod/ namespace rather
# than under /rds/.
data "aws_ssm_parameter" "jwt_secret" {
  name            = "/${var.name}/jwt-secret-key"
  with_decryption = true
}

resource "aws_ssm_parameter" "auth_secret" {
  name      = "/${var.name}/auth"
  type      = "SecureString"
  overwrite = true
  value = jsonencode({
    DATABASE_URL   = local.db_urls["auth"]
    JWT_SECRET_KEY = data.aws_ssm_parameter.jwt_secret.value
  })
}
