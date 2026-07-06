locals {
  vpn_hostname              = "${var.subdomain}.${var.public_domain}"
  wg_easy_password_ssm_path = "/${var.name}/vpn/wg-easy-password-hash"
}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Created manually, same as the ArgoCD admin password hash — Terraform only reads it.
data "aws_ssm_parameter" "wg_easy_password_hash" {
  name            = local.wg_easy_password_ssm_path
  with_decryption = true
}

# ── IAM — SSM Session Manager access, no SSH ────────────────────────────────────

resource "aws_iam_role" "vpn" {
  name = "${var.name}-vpn"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "vpn_ssm" {
  role       = aws_iam_role.vpn.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "vpn" {
  name = "${var.name}-vpn"
  role = aws_iam_role.vpn.name
}

# ── Security Group ───────────────────────────────────────────────────────────────

resource "aws_security_group" "vpn" {
  name        = "${var.name}-vpn"
  description = "WireGuard VPN server - UDP 51820 + HTTPS/HTTP for wg-easy panel, no SSH"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "WireGuard handshake"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "wg-easy panel (via Caddy)"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "ACME HTTP-01 challenge for Caddy"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ── EC2 instance ──────────────────────────────────────────────────────────────────

resource "aws_instance" "vpn" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  subnet_id              = var.public_subnet_id
  vpc_security_group_ids = [aws_security_group.vpn.id]
  iam_instance_profile   = aws_iam_instance_profile.vpn.name

  # Required so the instance can forward tunnel traffic addressed to other
  # hosts in the VPC instead of only its own ENI — same requirement as a NAT instance.
  source_dest_check = false

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    wg_host        = local.vpn_hostname
    wg_default_dns = cidrhost(var.vpc_cidr, 2)
    wg_allowed_ips = var.vpc_cidr
    # docker-compose.yml is parsed by docker-compose's own $VAR interpolation
    # engine at `docker-compose up` time (independent of the bash heredoc that
    # writes the file) — every literal $ in the bcrypt hash (always at least
    # three: $2a$10$...) gets treated as a variable reference and silently
    # dropped/mangled unless escaped as $$. Login then fails with a password
    # that "looks right" because the *real* hash never made it into the
    # container's env — the file on disk has a corrupted one.
    password_hash = replace(data.aws_ssm_parameter.wg_easy_password_hash.value, "$", "$$")
  })

  tags = {
    Name = "${var.name}-vpn"
  }
}

resource "aws_eip" "vpn" {
  instance = aws_instance.vpn.id
  domain   = "vpc"
}

# ── DNS — public record so clients can reach the panel before connecting ──────────

data "aws_route53_zone" "public" {
  name         = "${var.public_domain}."
  private_zone = false
}

resource "aws_route53_record" "vpn" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = local.vpn_hostname
  type    = "A"
  ttl     = 300
  records = [aws_eip.vpn.public_ip]
}

# ── EKS control-plane access — allow the VPN server to reach the API server ───────

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

resource "aws_security_group_rule" "eks_from_vpn" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  source_security_group_id = aws_security_group.vpn.id
  description              = "EKS API access from ${var.name} VPN server"
}
