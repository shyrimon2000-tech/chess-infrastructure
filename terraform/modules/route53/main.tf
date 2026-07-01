resource "aws_route53_zone" "private" {
  name = var.zone_name

  vpc {
    vpc_id = var.vpc_id
  }
}

resource "aws_route53_record" "dev" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "dev.${var.zone_name}"
  type    = "CNAME"
  ttl     = 300
  records = [var.load_balancer_hostname]
}

resource "aws_route53_record" "staging" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "staging.${var.zone_name}"
  type    = "CNAME"
  ttl     = 300
  records = [var.load_balancer_hostname]
}

resource "aws_route53_record" "argocd" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "argocd.${var.zone_name}"
  type    = "CNAME"
  ttl     = 300
  records = [var.load_balancer_hostname]
}
