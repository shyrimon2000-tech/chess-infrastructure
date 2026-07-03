output "endpoint" {
  description = "RDS instance connection endpoint (address:port)"
  value       = aws_db_instance.this.endpoint
}

output "address" {
  description = "RDS instance hostname (no port)"
  value       = aws_db_instance.this.address
}

output "security_group_id" {
  description = "Security group attached to the RDS instance — exposed in case another module (e.g. a future bastion or migration job) needs an explicit ingress rule"
  value       = aws_security_group.rds.id
}

# Consumed by the elasticache module via a terragrunt `dependency` block to
# build the complete /chess-prod/room and /chess-prod/game SSM secrets
# (DATABASE_URL from here + REDIS_URL from elasticache + this same shared
# JWT secret) — see the SSM section in main.tf for why room/game aren't
# written directly by this module.
output "database_urls" {
  description = "DATABASE_URL per service (mysql+pymysql://...) — includes the per-service generated password"
  value       = local.db_urls
  sensitive   = true
}

output "jwt_secret_key" {
  description = "Shared JWT secret — manually created SSM SecureString (/chess-prod/jwt-secret-key), just re-exposed here so elasticache doesn't need its own copy of the same data source"
  value       = data.aws_ssm_parameter.jwt_secret.value
  sensitive   = true
}
