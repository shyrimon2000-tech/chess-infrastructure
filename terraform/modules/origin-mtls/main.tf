data "aws_caller_identity" "current" {}

# ── ALB's own server certificate ──────────────────────────────────────────────
# What the ALB presents as a TLS server so CloudFront can verify it's really
# talking to this ALB (standard TLS server auth) — separate from the client
# certificate below, which is what CloudFront presents *to* the ALB. Both live
# on the same HTTPS:443 listener once the controller creates it, via
# chess-chart's certificate-arn and mutual-authentication Ingress annotations
# — Terraform never creates or references the ALB/listener itself.
#
# Lives here rather than in alb-controller: that module's other resources
# (IRSA role, helm_release) are tied to a specific EKS cluster's OIDC provider
# and get destroyed/recreated along with it. This certificate has no such
# dependency — same reasoning as the client cert/trust store below and as
# frontend's S3+CloudFront — so bundling it with alb-controller would force a
# new ACM ARN (and a manual values-prod.yaml edit) on every cluster
# teardown/recreate cycle this project regularly does for cost savings. This
# whole module is excluded from `run --all destroy` (see terragrunt.hcl) so
# every ARN it produces stays stable regardless of what happens to eks/vpc.

data "aws_route53_zone" "public" {
  name         = "${var.public_domain}."
  private_zone = false
}

resource "aws_acm_certificate" "alb" {
  domain_name       = var.api_origin_hostname
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "alb_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.alb.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.public.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 300
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "alb" {
  certificate_arn         = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for r in aws_route53_record.alb_cert_validation : r.fqdn]
}

# Not a secret — an ARN alone grants no access. Same discovery pattern as
# frontend's bucket/distribution-id SSM parameters (Terraform/Helm boundary).
resource "aws_ssm_parameter" "alb_certificate_arn" {
  name      = "/${var.name}/origin-mtls/alb-certificate-arn"
  type      = "String"
  overwrite = true
  value     = aws_acm_certificate_validation.alb.certificate_arn
}

# ── CA — signs the client certificate CloudFront presents to the ALB ─────────
# Self-signed, not AWS Private CA: ACM PCA charges ~$400/mo just for the CA to
# exist, regardless of how many certificates it issues — not justified for
# this project's scale. We fully own rotation/revocation ourselves instead;
# acceptable here because the only "client" ever presenting this cert is
# CloudFront itself (an automated system, not a human), so there's no
# meaningful trust chain to a public CA to lose by self-signing.

resource "tls_private_key" "ca" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem = tls_private_key.ca.private_key_pem

  is_ca_certificate     = true
  validity_period_hours = 87600 # 10 years — no rotation automation exists yet

  subject {
    common_name  = "${var.name}-origin-mtls-ca"
    organization = "chess-infrastructure"
  }

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
    "key_encipherment",
  ]
}

# ── Client certificate — what CloudFront actually presents at the TLS handshake ─
# Extended Key Usage must include TLS Client Authentication ("client_auth"
# below) — this is an AWS requirement for origin mTLS, not just a convention.

resource "tls_private_key" "client" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "client" {
  private_key_pem = tls_private_key.client.private_key_pem

  subject {
    common_name  = "${var.name}-cloudfront-origin-client"
    organization = "chess-infrastructure"
  }
}

resource "tls_locally_signed_cert" "client" {
  cert_request_pem   = tls_cert_request.client.cert_request_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem

  validity_period_hours = 43800 # 5 years

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "client_auth",
  ]
}

# CloudFront's origin mTLS config requires this specific client certificate to
# live in ACM us-east-1 — same regional requirement as the viewer-facing
# certificate in the frontend module, not an issue since this whole project
# already runs in us-east-1.
resource "aws_acm_certificate" "client" {
  private_key       = tls_private_key.client.private_key_pem
  certificate_body  = tls_locally_signed_cert.client.cert_pem
  certificate_chain = tls_self_signed_cert.ca.cert_pem

  lifecycle {
    create_before_destroy = true
  }
}

# ── ALB trust store — what the ALB verifies the client certificate against ───
# aws_lb_trust_store can't take inline PEM content the way ACM's
# certificate_body does — it requires the CA bundle to already exist as an S3
# object, referenced by bucket/key.

resource "aws_s3_bucket" "trust_store" {
  bucket = "${var.name}-origin-mtls-trust-store-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "trust_store" {
  bucket = aws_s3_bucket.trust_store.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "ca_bundle" {
  bucket  = aws_s3_bucket.trust_store.id
  key     = "ca-bundle.pem"
  content = tls_self_signed_cert.ca.cert_pem
}

resource "aws_lb_trust_store" "this" {
  name                             = "${var.name}-origin-mtls"
  ca_certificates_bundle_s3_bucket = aws_s3_bucket.trust_store.id
  ca_certificates_bundle_s3_key    = aws_s3_object.ca_bundle.key
}

# ── SSM — trust store ARN needs to reach chess-chart's values-prod.yaml ───────
# (alb.ingress.kubernetes.io/mutual-authentication annotation) — Terraform and
# Helm are decoupled layers here (ArgoCD, not Terraform, deploys the chart),
# so this is a plain String discovery value to copy in, same pattern as
# frontend's bucket/distribution-id SSM parameters. Not a secret — an ARN
# alone grants no access.
resource "aws_ssm_parameter" "trust_store_arn" {
  name      = "/${var.name}/origin-mtls/trust-store-arn"
  type      = "String"
  overwrite = true
  value     = aws_lb_trust_store.this.arn
}
