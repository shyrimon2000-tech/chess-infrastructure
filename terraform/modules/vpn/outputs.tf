output "vpn_hostname" {
  description = "Public DNS hostname clients use to configure their WireGuard peer"
  value       = local.vpn_hostname
}

output "security_group_id" {
  description = "Security group of the VPN server — reference this when granting access to other private resources (e.g. RDS)"
  value       = aws_security_group.vpn.id
}
