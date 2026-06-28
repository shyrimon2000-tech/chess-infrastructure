module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  addons = {
    coredns                = {}
    kube-proxy             = {}
    eks-pod-identity-agent = { before_compute = true }
    vpc-cni                = { before_compute = true }
    aws-ebs-csi-driver     = {}
  }

  eks_managed_node_groups = {
    infra = {
      instance_types = [var.infra_node_instance_type]
      min_size       = var.infra_node_count
      max_size       = var.infra_node_count
      desired_size   = var.infra_node_count

      labels = {
        role = "infra"
      }

      taints = {
        dedicated = {
          key    = "dedicated"
          value  = "infra"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  endpoint_public_access  = false
  endpoint_private_access = true

  enable_cluster_creator_admin_permissions = true

  tags = var.tags
}
