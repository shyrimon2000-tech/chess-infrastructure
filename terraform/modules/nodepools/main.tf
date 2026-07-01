resource "kubectl_manifest" "nodepool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: general
    spec:
      template:
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          requirements:
            - key: karpenter.sh/capacity-type
              operator: In
              values: ${var.use_spot ? jsonencode(["spot"]) : jsonencode(["on-demand"])}
            - key: node.kubernetes.io/instance-type
              operator: In
              values:
                - t3.medium
                - t3.large
                - t3a.medium
                - t3a.large
      disruption:
        consolidationPolicy: ${var.consolidation_policy}
        consolidateAfter: ${var.consolidate_after}
        expireAfter: 720h
        budgets:
          - nodes: "1"
      limits:
        cpu: "${var.cpu_limit}"
        memory: ${var.memory_limit}
  YAML

  depends_on = [kubectl_manifest.ec2_node_class]
}

resource "time_sleep" "wait_for_node_termination" {
  depends_on = [kubectl_manifest.nodepool]

  destroy_duration = "90s"
}

# Lives here, not in the eks module, because its controller pod needs an actual
# EC2 node to schedule onto — Fargate doesn't support the privileged/hostPath
# access this driver requires. Applying it after the NodePool exists means
# Karpenter can provision a node for the unschedulable pod instead of the
# addon polling against zero available nodes until it times out.
module "irsa_ebs_csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name                  = "${var.cluster_name}-ebs-csi-driver"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name              = var.cluster_name
  addon_name                = "aws-ebs-csi-driver"
  service_account_role_arn  = module.irsa_ebs_csi.arn

  # The earlier failed attempt (when this addon still lived in the eks module)
  # got far enough to create the ebs-csi-controller-sa ServiceAccount and
  # annotate it with the *old* IRSA role's ARN before timing out. The default
  # conflict mode refuses to overwrite that stale annotation with this module's
  # (different) role ARN — OVERWRITE lets EKS reconcile it instead of erroring.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [kubectl_manifest.nodepool]
}

# EKS ships a default "gp2" StorageClass (legacy in-tree provisioner) but
# nothing that uses the EBS CSI driver or gp3 — the Helm chart's DB/Redis
# StatefulSets request `storageClassName: gp3` explicitly, which doesn't
# exist until something creates it. Installing the aws-ebs-csi-driver addon
# only gives you the provisioner; it doesn't create any StorageClass objects
# on its own.
resource "kubectl_manifest" "gp3_storage_class" {
  yaml_body = <<-YAML
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: gp3
    provisioner: ebs.csi.aws.com
    volumeBindingMode: WaitForFirstConsumer
    reclaimPolicy: Delete
    allowVolumeExpansion: true
    parameters:
      type: gp3
  YAML

  depends_on = [aws_eks_addon.ebs_csi]
}

resource "kubectl_manifest" "ec2_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiFamily: AL2023
      amiSelectorTerms:
        - alias: al2023@latest
      role: ${var.node_iam_role_name}
      subnetSelectorTerms:
        - tags:
            kubernetes.io/role/internal-elb: "1"
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
  YAML
}
