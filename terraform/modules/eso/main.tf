locals {
  oidc_provider_url = regex("oidc-provider/(.+)$", var.oidc_provider_arn)[0]
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ── IAM — IRSA for the ESO controller's own service account ──────────────────────
# ClusterSecretStore has no explicit `auth` block (see below), so ESO reads
# credentials from whatever identity its own pod runs as — this role, via IRSA.

data "aws_iam_policy_document" "eso_irsa" {
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
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eso" {
  name               = "${var.name}-eso"
  assume_role_policy = data.aws_iam_policy_document.eso_irsa.json
}

data "aws_iam_policy_document" "eso_permissions" {
  statement {
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.name}/*",
    ]
  }
}

resource "aws_iam_role_policy" "eso" {
  name   = "ssm-read"
  role   = aws_iam_role.eso.id
  policy = data.aws_iam_policy_document.eso_permissions.json
}

# ── External Secrets Operator ─────────────────────────────────────────────────────

resource "helm_release" "eso" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  namespace  = "external-secrets"
  version    = var.eso_version

  create_namespace = true

  set = [
    {
      name  = "serviceAccount.name"
      value = "external-secrets"
    },
    {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.eso.arn
    },
    {
      # Default webhook port (10250) collides with Fargate's own internal
      # kubelet-equivalent listener on that same port on the pod's node IP -
      # kube-apiserver's webhook call gets answered by that instead of ESO's
      # real webhook, which is why the TLS cert it gets back is scoped to the
      # Fargate node's own IP hostname, not the webhook's Service DNS name
      # (x509: certificate is valid for fargate-ip-..., not
      # external-secrets-webhook.external-secrets.svc). Only surfaced once
      # ESO moved onto its own Fargate profile - never an issue on EC2 nodes.
      # Same fix AWS's own eks-blueprints-addons module landed on for this
      # exact problem (github.com/aws-ia/terraform-aws-eks-blueprints-addons
      # issue #55, PR #373).
      name  = "webhook.port"
      value = "9443"
    }
  ]
}

# Fixed name "cluster-secret-store" — the chess-chart's ExternalSecret templates
# reference it by this literal name (see charts/*/values.yaml secretStoreRef.name).
resource "kubectl_manifest" "cluster_secret_store" {
  depends_on = [helm_release.eso]

  yaml_body = <<-YAML
    apiVersion: external-secrets.io/v1beta1
    kind: ClusterSecretStore
    metadata:
      name: cluster-secret-store
    spec:
      provider:
        aws:
          service: ParameterStore
          region: ${data.aws_region.current.region}
  YAML
}
