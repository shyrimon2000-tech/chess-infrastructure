resource "aws_route53_zone" "private" {
  name = var.zone_name

  vpc {
    vpc_id = var.vpc_id
  }
}

# Subdomain list is parameterized, not hardcoded, so this same module works
# for shared (dev + staging + argocd — all app traffic is VPN-only) and prod
# (argocd only — the chess services themselves go through the public ALB,
# not this private zone; only admin-facing ArgoCD needs to stay VPN-only).
resource "aws_route53_record" "this" {
  for_each = toset(var.records)

  zone_id = aws_route53_zone.private.zone_id
  name    = "${each.value}.${var.zone_name}"
  type    = "CNAME"
  ttl     = 300
  records = [var.load_balancer_hostname]
}

# Migrates shared's already-applied dev/staging/argocd records to the new
# for_each address in-place — without these, Terraform would plan to destroy
# and recreate all three (different resource address = different identity to
# state, even though the resulting DNS records are identical).
moved {
  from = aws_route53_record.dev
  to   = aws_route53_record.this["dev"]
}

moved {
  from = aws_route53_record.staging
  to   = aws_route53_record.this["staging"]
}

moved {
  from = aws_route53_record.argocd
  to   = aws_route53_record.this["argocd"]
}
