locals {
  oidc_provider_url = regex("oidc-provider/(.+)$", var.oidc_provider_arn)[0]
}

# ── IAM — IRSA for the controller's own service account ──────────────────────
# Policy JSON is AWS's own published policy (fetched verbatim from
# kubernetes-sigs/aws-load-balancer-controller's docs/install/iam_policy.json,
# not hand-written) — the controller needs a genuinely large set of EC2/ELB
# permissions to create/manage ALBs, target groups, listeners and security
# groups on its own, so this is copied from the authoritative source rather
# than reconstructed from memory.

data "aws_iam_policy_document" "alb_controller_irsa" {
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
      values   = ["system:serviceaccount:aws-load-balancer-controller:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_irsa.json
}

resource "aws_iam_role_policy" "this" {
  name   = "alb-controller-permissions"
  role   = aws_iam_role.this.id
  policy = file("${path.module}/iam_policy.json")
}

# ── Security group — ALB reachable only from CloudFront, never directly ───────
# The controller normally auto-creates the ALB's security group with whatever
# CIDRs `inbound-cidrs` specifies (open to the internet by default). Instead,
# this Terraform-created group is referenced by the Ingress's
# `alb.ingress.kubernetes.io/security-groups` annotation (matched by this
# `Name` *tag*, not the SG's groupName — see README ALB/ExternalDNS section),
# which bypasses that auto-creation entirely. AWS's managed prefix list for
# CloudFront's origin-facing IPs is the authoritative, AWS-maintained source
# for "which IPs is CloudFront allowed to originate from" — hand-maintaining
# that CIDR list would go stale as AWS adds/rotates edge IPs.

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  vpc_id      = var.vpc_id

  # Single rule covering both listeners (443: main API, mTLS; 8443: game's
  # WebSocket, no mTLS - see README Troubleshooting) rather than two
  # separate ingress blocks. AWS counts a security-group rule referencing a
  # managed prefix list as one "slot" per entry *in that list*, not one
  # slot per rule - found live: the CloudFront prefix list currently has 45
  # entries, so two separate rules referencing it would cost 90 of this
  # account's 60-rule-per-SG quota (RulesPerSecurityGroupLimitExceeded) even
  # though only two literal ingress blocks were declared. One rule spanning
  # the port range keeps the prefix list "charged" only once (~45 slots).
  # Ports 444-8442 are incidentally allowed too, but nothing listens there -
  # the ALB itself only has listeners on 443 and 8443, so this is no wider
  # in practice than two separate, more precisely-scoped rules would be.
  ingress {
    description     = "HTTPS (443) + WebSocket (8443) from CloudFront only"
    from_port       = 443
    to_port         = 8443
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-alb-cloudfront-only"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── AWS Load Balancer Controller ──────────────────────────────────────────────
# Only creates the controller itself — it does NOT create an ALB (there's
# nothing to route to yet). The controller creates the actual ALB later, on
# its own, once chess-chart's Ingress resources (ArgoCD-deployed,
# ingressClassName: alb) exist in the cluster. See README ALB/ExternalDNS
# section for the full sequencing.

resource "helm_release" "this" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "aws-load-balancer-controller"
  version    = var.chart_version

  create_namespace = true

  set = [
    {
      name  = "clusterName"
      value = var.cluster_name
    },
    {
      name  = "vpcId"
      value = var.vpc_id
    },
    {
      name  = "serviceAccount.create"
      value = "true"
    },
    {
      name  = "serviceAccount.name"
      value = "aws-load-balancer-controller"
    },
    {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.this.arn
    },
    {
      # This project only uses the controller for Ingress -> ALB (path-based
      # routing, see README). The Service -> NLB flow this webhook exists for
      # requires the newer `aws-load-balancer-type: external` annotation,
      # which nothing here uses (ingress-nginx's NLB uses the legacy `nlb`
      # annotation, reconciled by EKS's built-in cloud provider, not by this
      # controller). Left enabled, the webhook still registers to intercept
      # every Service create/update cluster-wide (no objectSelector), so any
      # other Helm chart creating a Service (karpenter, ingress-nginx) that
      # lands in the same terragrunt run-all wave as this controller races
      # its still-starting pod and fails admission ("no endpoints
      # available"). Disabling it removes that unrelated interception
      # entirely; Ingress admission (mingress.elbv2.k8s.aws) is untouched.
      name  = "enableServiceMutatorWebhook"
      value = "false"
    }
  ]
}
