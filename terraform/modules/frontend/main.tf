locals {
  hostname = "${var.subdomain}.${var.public_domain}"
  # S3 bucket names are globally unique across all AWS accounts — suffixing
  # with the account ID avoids a collision with someone else's bucket
  # (same reasoning as the Terraform state bucket name).
  bucket_name = "${var.name}-frontend-${data.aws_caller_identity.current.account_id}"
}

data "aws_caller_identity" "current" {}

# ── S3 — private bucket, no static website hosting, no public access ──────────
# CloudFront (via Origin Access Control) is the only thing that ever reads
# from this bucket directly. No website endpoint, no public bucket policy —
# TLS termination and the public hostname both live at CloudFront, not S3.

resource "aws_s3_bucket" "frontend" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ── ACM — CloudFront requires the certificate in us-east-1 specifically ───────
# Not an issue here since this whole project already runs in us-east-1 (see
# root.hcl) — no separate provider alias needed, unlike a project whose main
# region is elsewhere.

resource "aws_acm_certificate" "frontend" {
  domain_name       = local.hostname
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_route53_zone" "public" {
  name         = "${var.public_domain}."
  private_zone = false
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.frontend.domain_validation_options : dvo.domain_name => {
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

resource "aws_acm_certificate_validation" "frontend" {
  certificate_arn         = aws_acm_certificate.frontend.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ── CloudFront ──────────────────────────────────────────────────────────────

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.name}-frontend"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ALB path-pattern conditions only accept literal characters plus `*`/`?`
# wildcards, not regex — so unlike ingress-nginx (which strips the `/api`
# prefix itself via a regex rewrite-target), the ALB Ingress Controller has no
# way to strip it before forwarding. Doing the strip here, at the edge, means
# auth/room/game keep receiving the same unprefixed paths they already get in
# dev/staging (`/auth/...`, `/rooms/...`, `/game/...`) — no backend changes,
# and the ALB's own Ingress rules can stay plain prefix matches.
resource "aws_cloudfront_function" "strip_api_prefix" {
  name    = "${var.name}-strip-api-prefix"
  runtime = "cloudfront-js-2.0"
  comment = "Strips the /api prefix before forwarding to the ALB origin"
  publish = true
  code    = file("${path.module}/functions/strip-api-prefix.js")
}

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  default_root_object = "index.html"
  aliases             = [local.hostname]
  price_class         = var.price_class

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  # ALB isn't created by Terraform at all — the AWS Load Balancer Controller
  # (a K8s controller, see alb-controller module) creates it later, on its
  # own, once chess-chart's Ingress is deployed by ArgoCD. `var.api_origin_hostname`
  # doesn't resolve to anything yet at the moment this distribution is
  # created — that's fine, CloudFront only needs an origin's DNS to resolve
  # when an actual request routes there, not at creation time. ExternalDNS
  # (separate module) later creates the A record pointing this hostname at
  # the real ALB, fully automatically, no second `terraform apply` needed.
  # See README ALB/ExternalDNS section for the full sequencing.
  origin {
    domain_name = var.api_origin_hostname
    origin_id   = "alb-api"

    # TLS for end users terminates here at CloudFront (the cert above already
    # covers this hostname) — the CloudFront-to-ALB hop gets its own, separate
    # re-encrypted TLS session (https-only) rather than plain HTTP. Originally
    # http-only, relying on the AWS internal backbone alone for
    # confidentiality — but the old X-Origin-Verify secret header traveled in
    # that same request, so a readable hop would have leaked the very secret
    # meant to prove "this is really our CloudFront".
    #
    # origin_mtls_config replaces that header entirely: CloudFront presents a
    # client certificate (terraform/modules/origin-mtls) that the ALB verifies
    # against its trust store before accepting the connection at all. Proves
    # "this specific distribution" cryptographically — a forged/leaked header
    # value could be replayed by anyone; a private key backing a client
    # certificate can't be.
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]

      # CloudFront's own origin-connection timeouts, independent of the ALB's
      # idle_timeout (3600s, game-ingress.yaml) and nginx's proxy-read/send-
      # timeout (3600s, dev/staging) - neither of those covers this hop at
      # all. Defaults are 30s response / 5s keep-alive, which silently killed
      # long-idle WebSocket game sessions specifically in prod (never in
      # dev/staging, which has no CloudFront in the path at all) - a player
      # just thinking for 30+ seconds without sending a move was enough.
      # 180s is the max CloudFront allows without an AWS support quota
      # increase; a real game move can still take longer than that with no
      # app-level ping/keepalive frame in between, so this raises the
      # ceiling substantially but isn't a complete fix on its own - see
      # README Troubleshooting.
      origin_read_timeout       = 180
      origin_keepalive_timeout  = 60

      origin_mtls_config {
        client_certificate_arn = var.origin_mtls_client_certificate_arn
      }
    }
  }

  # Second ALB origin, same hostname/ALB, different port (8443) and
  # deliberately NO origin_mtls_config - CloudFront does not support
  # WebSocket for an origin with origin mTLS enabled (AWS-documented
  # limitation, found live - see README Troubleshooting). game-service's
  # /ws/games path routes here instead; everything else keeps going through
  # "alb-api" above with mTLS intact.
  origin {
    domain_name = var.api_origin_hostname
    origin_id   = "alb-game-ws"

    custom_origin_config {
      http_port                = 80
      https_port                = 8443
      origin_protocol_policy    = "https-only"
      origin_ssl_protocols      = ["TLSv1.2"]
      origin_read_timeout       = 180
      origin_keepalive_timeout  = 60
    }
  }

  # /api/game/ws/* → the mTLS-free ALB listener above. Must come before the
  # general /api/* behavior below (ordered_cache_behavior list order decides
  # precedence - first match wins), since /api/game/ws/games/1 would
  # otherwise also match the broader /api/* pattern first.
  ordered_cache_behavior {
    path_pattern             = "/api/game/ws/*"
    target_origin_id         = "alb-game-ws"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = false # avoid interfering with the WebSocket upgrade response
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # AWS managed: CachingDisabled
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AWS managed: AllViewerExceptHostHeader

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.strip_api_prefix.arn
    }
  }

  # /api/* → ALB (auth/room/game), everything else → S3 (default behavior
  # below). CachingDisabled since these are dynamic API responses, not
  # static assets. AllViewerExceptHostHeader forwards all headers/cookies/
  # query strings the API needs — but deliberately NOT the original viewer
  # Host header (chess.alexit.online): the ALB's Ingress host-based listener
  # rule matches on api_origin_hostname, so CloudFront must send that as the
  # Host header to the origin, not what the browser actually requested.
  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "alb-api"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # AWS managed: CachingDisabled
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AWS managed: AllViewerExceptHostHeader

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.strip_api_prefix.arn
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    # AWS managed "CachingOptimized" policy — long TTL, gzip/brotli aware.
    # No forwarded_values block (deprecated in favor of cache policies).
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # React Router does client-side routing — a direct hit on e.g.
  # /profile/123 doesn't exist as an S3 object, so S3 (via OAC) returns 403
  # (not 404 — a private bucket denies unknown keys rather than revealing
  # they're absent). Rewrite both to index.html with a real 200 so the SPA's
  # own router can take over client-side instead of the browser showing a
  # raw CloudFront error page.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.frontend.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# ── S3 bucket policy — only this specific CloudFront distribution may read ────

data "aws_iam_policy_document" "frontend_oac" {
  statement {
    sid       = "AllowCloudFrontOAC"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.frontend.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend_oac.json
}

# ── DNS ─────────────────────────────────────────────────────────────────────

resource "aws_route53_record" "frontend" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = local.hostname
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.frontend.domain_name
    zone_id                = aws_cloudfront_distribution.frontend.hosted_zone_id
    evaluate_target_health = false
  }
}

# ── SSM — deploy targets for the frontend repo's own CI, not a secret ─────────
# The frontend repo (chess-frontend-service) builds and `aws s3 sync`s itself
# — Terraform only provisions the bucket/distribution, never uploads content
# (see README GitHub Actions CD section: infra vs app-delivery stay separate).
# These are plain String parameters, not SecureString — a bucket name and a
# distribution ID aren't secrets, just discovery values a CI job on another
# repo has no other way to know without hardcoding them.

resource "aws_ssm_parameter" "frontend_bucket" {
  name = "/${var.name}/frontend/s3-bucket"
  type = "String"
  # Defaults to false on create (won't clobber a parameter it doesn't own
  # yet) — but a bucket-name/distribution-ID value left over from a prior
  # destroy/apply cycle that never made it into *this* state should always
  # just be replaced with whatever this apply actually created. Same failure
  # class as the Helm "name still in use" and EKS "addon already exists"
  # bugs elsewhere in this project — neither is a secret needing manual
  # bootstrap, so there's no reason to preserve a stale value here.
  overwrite = true
  value     = aws_s3_bucket.frontend.bucket
}

resource "aws_ssm_parameter" "frontend_distribution_id" {
  name      = "/${var.name}/frontend/cloudfront-distribution-id"
  type      = "String"
  overwrite = true
  value     = aws_cloudfront_distribution.frontend.id
}
