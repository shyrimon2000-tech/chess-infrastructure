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
      configuration_values = jsonencode({
        nodeSelector = {
          "eks.amazonaws.com/compute-type" = "ec2"
        }
      })
    }
    aws-ebs-csi-driver = {
      service_account_role_arn = module.irsa_ebs_csi.arn
      configuration_values = jsonencode({
        controller = { affinity = {} }
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

  enable_cluster_creator_admin_permissions = true

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

module "irsa_ebs_csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name                  = "${var.cluster_name}-ebs-csi-driver"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}
