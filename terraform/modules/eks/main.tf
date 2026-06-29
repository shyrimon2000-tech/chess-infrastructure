module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  addons = {
    coredns                = {
      configuration_values = jsonencode({
        computeType = "Fargate"
      })
    }
    kube-proxy             = {}
    eks-pod-identity-agent = { before_compute = true }
    vpc-cni                = { before_compute = true }
    aws-ebs-csi-driver     = {}
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

  endpoint_public_access  = false
  endpoint_private_access = true

  enable_cluster_creator_admin_permissions = true

  tags = var.tags
}
