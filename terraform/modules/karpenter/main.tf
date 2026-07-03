locals {
  oidc_provider_url = regex("oidc-provider/(.+)$", var.oidc_provider_arn)[0]
}

data "aws_iam_policy_document" "karpenter_irsa" {
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
      values   = ["system:serviceaccount:karpenter:karpenter"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

module "karpenter" {
  source       = "terraform-aws-modules/eks/aws//modules/karpenter"
  version      = "~> 21.0"

  cluster_name                              = var.cluster_name
  create_pod_identity_association           = false
  iam_role_override_assume_policy_documents = [data.aws_iam_policy_document.karpenter_irsa.json]
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  namespace  = "karpenter"
  version    = var.karpenter_version

  create_namespace = true

  set = [
    {
      name  = "settings.clusterName"
      value = var.cluster_name
    },
    {
      name  = "settings.clusterEndpoint"
      value = var.cluster_endpoint
    },
    {
      name  = "settings.interruptionQueue"
      value = module.karpenter.queue_name
    },
    {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = module.karpenter.iam_role_arn
    }
  ]
}