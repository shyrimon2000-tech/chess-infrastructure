locals {
  oidc_provider_url = regex("oidc-provider/(.+)$", var.oidc_provider_arn)[0]
}

data "aws_route53_zone" "public" {
  name         = "${var.domain_filter}."
  private_zone = false
}

# ── IAM — IRSA for the controller's own service account ──────────────────────

data "aws_iam_policy_document" "external_dns_irsa" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:external-dns:external-dns"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-external-dns"
  assume_role_policy = data.aws_iam_policy_document.external_dns_irsa.json
}

# ChangeResourceRecordSets scoped to exactly this one hosted zone — same
# least-privilege reasoning as eso's SSM path scoping. List*/Get* actions
# are read-only discovery calls that Route53's API only supports at
# account-wide scope (no per-zone ARN), not a broader grant than intended.
data "aws_iam_policy_document" "external_dns_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [data.aws_route53_zone.public.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResources",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "route53-records"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.external_dns_permissions.json
}

# ── ExternalDNS ────────────────────────────────────────────────────────────
# Watches Ingress (and Service) resources cluster-wide and creates/updates
# Route53 records automatically — for Ingress specifically it reads the
# record straight from spec.rules[].host, no annotation needed (confirmed
# against the project's own README ALB/ExternalDNS troubleshooting note).
# policy = upsert-only: never deletes a record it didn't create, even if the
# matching Ingress disappears — safer default than "sync" for a shared
# hosted zone that also holds unrelated records (e.g. the vpn module's).

resource "helm_release" "this" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  namespace  = "external-dns"
  version    = var.chart_version

  create_namespace = true

  set = [
    {
      name  = "provider"
      value = "aws"
    },
    {
      name  = "policy"
      value = "upsert-only"
    },
    {
      name  = "txtOwnerId"
      value = var.cluster_name
    },
    {
      name  = "domainFilters[0]"
      value = var.domain_filter
    },
    {
      name  = "serviceAccount.name"
      value = "external-dns"
    },
    {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.this.arn
    }
  ]
}
