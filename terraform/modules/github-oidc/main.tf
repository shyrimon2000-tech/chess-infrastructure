# GitHub's own OIDC issuer — one provider per AWS account, not per
# environment (unlike each EKS cluster's own OIDC provider, see
# modules/eks's oidc_provider_arn output, which is per-cluster and
# federates trust for pods via IRSA). This one federates trust for GitHub
# Actions workflow runs — same general AssumeRoleWithWebIdentity mechanism,
# but a completely separate issuer/provider, unrelated to IRSA.
#
# Thumbprint is fetched live rather than hardcoded so a future GitHub
# certificate rotation doesn't silently break trust.
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

# Trust policy for the dev branch — enforced via the `sub` claim, which
# encodes repo+ref for push/workflow_dispatch events. This (not anything
# about the provider itself) is what makes it impossible for a
# workflow_dispatch run on any other branch to assume this role.
#
# Also accepts "repo:<repo>:pull_request" — GitHub sets `sub` to this fixed
# value (no branch info at all) for every pull_request-triggered run,
# regardless of base or head branch (confirmed: this is why the plan job
# first failed with "Not authorized to perform sts:AssumeRoleWithWebIdentity"
# — neither role's trust policy matched the pull_request token's actual sub
# until this was added). This does mean a pull_request run into *either*
# dev or main could technically assume *either* role — an acceptable gap
# for now since both roles currently carry identical permissions anyway
# (see cicd_permissions below) and only the plan job (read-only, never
# applies) runs on pull_request; revisit with a base_ref-based condition if
# the two roles' permissions ever diverge.
data "aws_iam_policy_document" "assume_role_dev" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:ref:refs/heads/dev",
        "repo:${var.github_repo}:pull_request",
      ]
    }
  }
}

# Same shape, scoped to main instead.
data "aws_iam_policy_document" "assume_role_main" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:ref:refs/heads/main",
        "repo:${var.github_repo}:pull_request",
      ]
    }
  }
}

# dev branch → shared environment (dev + staging namespaces)
resource "aws_iam_role" "shared" {
  name               = "chess-shared-cicd"
  assume_role_policy = data.aws_iam_policy_document.assume_role_dev.json
}

# main branch → prod environment
resource "aws_iam_role" "prod" {
  name               = "chess-prod-cicd"
  assume_role_policy = data.aws_iam_policy_document.assume_role_main.json
}

# One inline policy per role, not attached managed policies — IAM hard-caps
# "PoliciesPerRole" at 10 attached policies (AWS-managed + customer-managed
# count together against that same quota), and this needs 13 service
# entries + EKS. Inline policies (aws_iam_role_policy) don't count against
# that quota at all — they have a separate, much larger character-based
# limit instead — so bundling everything into one inline document per role
# sidesteps the cap entirely.
#
# Action list mirrors what the equivalent AWS managed *FullAccess policies
# grant (verified against every `resource "aws_*"` across all modules, plus
# what the community VPC/EKS/Karpenter/IRSA modules provision under the
# hood) — service-scoped, not AdministratorAccess. eks:* has no AWS managed
# policy equivalent at all (AmazonEKSClusterPolicy and siblings are for the
# cluster/node's own service role, not a caller of
# eks:CreateCluster/DescribeCluster/etc — verified against AWS's own
# managed-policy docs). Resource is "*" throughout: several actions here
# (e.g. eks:ListClusters, ec2:DescribeInstances) don't support resource-level
# permissions at all, so a scoped Resource would silently break those calls.
#
# Same list on both roles for now rather than splitting exactly by which
# environment uses which service — a reasonable simplification given the
# overlap, revisit if the two environments' footprints diverge further.
#
# ecs:*/logs:* deliberately excluded — no ECS/CloudWatch Logs usage anywhere
# in this repo (the module that used to need them, ecs-runner, was removed).
#
# wafv2:*/waf:*/waf-regional:* included even though nothing uses WAF yet —
# planned future work, not a currently-exercised permission.
data "aws_iam_policy_document" "cicd_permissions" {
  statement {
    effect    = "Allow"
    resources = ["*"]
    actions = [
      "ec2:*",
      "eks:*",
      "rds:*",
      "elasticache:*",
      "s3:*",
      "cloudfront:*",
      "acm:*",
      "route53:*",
      "elasticloadbalancing:*",
      "iam:*",
      "ssm:*",
      "sqs:*",
      "events:*",
      "wafv2:*",
      "waf:*",
      "waf-regional:*",
    ]
  }
}

resource "aws_iam_role_policy" "shared_permissions" {
  name   = "cicd-permissions"
  role   = aws_iam_role.shared.id
  policy = data.aws_iam_policy_document.cicd_permissions.json
}

resource "aws_iam_role_policy" "prod_permissions" {
  name   = "cicd-permissions"
  role   = aws_iam_role.prod.id
  policy = data.aws_iam_policy_document.cicd_permissions.json
}
