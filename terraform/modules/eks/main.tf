module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  addons = {
    coredns = {
      configuration_values = jsonencode({
        computeType = "Fargate"
      })
    }
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
      # "nodeSelector" is not a valid top-level key in this addon's config schema
      # (verified via `aws eks describe-addon-configuration`) — only "affinity" is.
      configuration_values = jsonencode({
        affinity = {
          nodeAffinity = {
            requiredDuringSchedulingIgnoredDuringExecution = {
              nodeSelectorTerms = [
                {
                  # NotIn "fargate", not In "ec2" (bug fixed 2026-07-02): real
                  # Karpenter-provisioned EC2 nodes carry
                  # eks.amazonaws.com/compute-type set to an opaque per-node
                  # identifier, not the literal string "ec2" — only Fargate
                  # nodes reliably have the literal value "fargate". `In
                  # ["ec2"]` matched zero real nodes, so the aws-node DaemonSet
                  # sat at DESIRED=0 everywhere — no CNI pod anywhere means no
                  # node (Fargate or EC2) can ever report NetworkReady, which
                  # is exactly why the 2 EC2 nodes stayed NotReady for 40+
                  # minutes with "cni plugin not initialized".
                  matchExpressions = [
                    {
                      key      = "eks.amazonaws.com/compute-type"
                      operator = "NotIn"
                      values   = ["fargate"]
                    }
                  ]
                }
              ]
            }
          }
        }
      })
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  fargate_profiles = {
    karpenter = {
      selectors = [
        { namespace = "karpenter" }
      ]
      subnet_ids = var.private_subnet_ids
    }
    argocd = {
      selectors = [
        { namespace = "argocd" }
      ]
      subnet_ids = var.private_subnet_ids
    }
    grafana = {
      selectors = [
        { namespace = "grafana" }
      ]
      subnet_ids = var.private_subnet_ids
    }
    ingress_nginx = {
      selectors = [
        { namespace = "ingress-nginx" }
      ]
      subnet_ids = var.private_subnet_ids
    }
    kube_system = {
      selectors = [
        {
          namespace = "kube-system"
          labels    = { "k8s-app" = "kube-dns" }
        }
      ]
      subnet_ids = var.private_subnet_ids
    }
  }

  endpoint_public_access  = true # temporary: still applying from a laptop, not yet through the VPN — flip to false once VPN is actually applied and connected
  endpoint_private_access = true

  # false: this module's own "cluster_creator" access entry collided with AWS's
  # apparent implicit bootstrap entry (409 ResourceInUseException) on the first
  # attempt, but `aws eks list-access-entries` afterwards showed no entry for the
  # applying principal at all — whatever created the conflicting entry didn't
  # leave a durable, usable grant. Not relying on that implicit path: admin access
  # comes only from the explicit access_entries.personal block below, unconditionally.
  enable_cluster_creator_admin_permissions = false

  access_entries = var.admin_principal_arn != "" ? {
    personal = {
      principal_arn = var.admin_principal_arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  } : {}

  tags = var.tags
}

# Fargate pods (CoreDNS, ArgoCD, Karpenter controller, ingress-nginx) get
# attached to the AWS-native "primary" cluster security group automatically
# at cluster-creation time (`cluster_primary_security_group_id` — this is
# NOT the same as `cluster_security_group_id`, which is a *separate*,
# additional SG this Terraform module creates and manages itself, used only
# for specific control-plane<->node webhook rules). Karpenter-provisioned EC2
# nodes use a third, distinct node security group. Nothing bridges the
# primary cluster SG and the node SG by default — the node SG's only DNS rule
# is self-referencing (node-to-node within the same SG), and the primary
# cluster SG only accepts traffic from itself + the VPN. Without this rule,
# every pod running on an EC2 node (not just the EBS CSI driver) fails to
# resolve any DNS at all, because CoreDNS itself only runs on Fargate:
# `nslookup` against the in-cluster resolver times out ("no servers could be
# reached"), while `nslookup ... 8.8.8.8` (bypassing CoreDNS) works fine —
# confirmed via a throwaway debug pod on the affected node, then confirmed
# again that `module.eks.cluster_security_group_id` (first attempt) pointed
# at the wrong SG entirely by comparing it against the security group actually
# attached to CoreDNS's Fargate ENI (`aws ec2 describe-network-interfaces`).
# Not scoped to just port 53: any EC2-hosted workload may need to reach a
# Fargate-hosted cluster service later (ArgoCD, ESO), so this opens full
# traffic between the two groups rather than chasing one port at a time.
resource "aws_security_group_rule" "node_to_cluster" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = module.eks.cluster_primary_security_group_id
  source_security_group_id = module.eks.node_security_group_id
  description              = "Allow all traffic from EC2 (Karpenter) nodes to Fargate-hosted cluster services"
}

# Reverse direction — a Fargate-hosted controller (ArgoCD, ESO) initiating a
# connection to an EC2-hosted pod (e.g. a webhook or health check) would hit
# the same gap in the other direction. Not yet observed as a failure, but
# cheap to close now given it's already intra-VPC-only traffic.
resource "aws_security_group_rule" "cluster_to_node" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = module.eks.cluster_primary_security_group_id
  description              = "Allow all traffic from Fargate-hosted cluster services to EC2 (Karpenter) nodes"
}
