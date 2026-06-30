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
