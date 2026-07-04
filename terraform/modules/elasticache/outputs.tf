output "redis_url" {
  description = "Full REDIS_URL (redis://host:port/0) — same value written into both /chess-prod/room and /chess-prod/game"
  value       = local.redis_url
  sensitive   = true
}

output "security_group_id" {
  description = "Security group attached to the Redis cluster"
  value       = aws_security_group.redis.id
}
