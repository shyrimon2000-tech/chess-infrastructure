variable "name" {
  description = "Name prefix for VPN resources (e.g. chess-shared)"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC the VPN server routes traffic into"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC — used to derive the VPC DNS resolver address (base+2) pushed to WireGuard peers"
  type        = string
}

variable "public_subnet_id" {
  description = "Public subnet the VPN EC2 instance launches in"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — its security group gets an ingress rule allowing the VPN server to reach the API on 443"
  type        = string
}

variable "public_domain" {
  description = "Existing public Route53 hosted zone domain the vpn subdomain record is created in"
  type        = string
  default     = "alexit.online"
}

variable "subdomain" {
  description = "Subdomain prefix for the VPN hostname (e.g. \"vpn\" -> vpn.alexit.online) — must be unique per VPN instance since each gets its own EIP"
  type        = string
  default     = "vpn"
}

variable "instance_type" {
  description = "EC2 instance type for the VPN server"
  type        = string
  default     = "t3.micro"
}
