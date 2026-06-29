module "karpenter" {
  source       = "terraform-aws-modules/eks/aws//modules/karpenter"
  version      = "~> 21.0"

  cluster_name = var.cluster_name

  enable_pod_identity             = true
  create_pod_identity_association = true
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  namespace  = "karpenter"
  version    = var.karpenter_version

  create_namespace = true

  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }

  set {
    name  = "settings.clusterEndpoint"
    value = var.cluster_endpoint
  }

  set {
    name  = "settings.interruptionQueue"
    value = module.karpenter.queue_name
  }
}