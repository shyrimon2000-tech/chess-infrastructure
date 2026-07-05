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
                # small added alongside medium/large - no downside: Karpenter
                # only ever picks the cheapest option that actually fits the
                # pending pod(s) it's sizing a node for, never forces a
                # workload onto an undersized node. Rarely the winning pick
                # once real chess-service load exists (bin-packed on purpose,
                # so requests usually exceed one small's capacity already),
                # but a cheaper option for a cold cluster's very first node or
                # a lone leftover pod.
                - t3.small
                - t3.medium
                - t3.large
                - t3a.small
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

# Polls AWS directly for actual instance termination instead of trusting a
# fixed sleep duration (the previous `time_sleep(90s)` — real termination of
# N Spot/on-demand instances isn't bounded by a guessed constant, and if
# Karpenter's own controller is destroyed before nodes finish draining, they
# become orphaned with nothing left to terminate them at all, blocking the
# node security group's deletion indefinitely (`DependencyViolation`, hit for
# real 2026-07-02: 3 leftover instances, needed a manual
# `aws ec2 terminate-instances` to unblock destroy).
resource "null_resource" "wait_for_node_termination" {
  triggers = {
    node_iam_role_name    = var.node_iam_role_name
    local_exec_shell_path = var.local_exec_shell_path
  }

  depends_on = [kubectl_manifest.nodepool]

  # Interpreter is parameterized (routed through triggers, since destroy-time
  # provisioners can only reference `self.*`), not hardcoded —
  # this provisioner runs on whatever machine is actually applying Terraform,
  # which varies: a Linux CI runner (the eventual ecs-runner / GitHub Actions
  # concept) has a real /bin/sh; this project is currently still applied from
  # a Windows laptop, which doesn't. Three failed attempts taught real
  # lessons about *which* shell actually exists before landing on this:
  #   1. `interpreter = ["/bin/sh", "-c"]` hardcoded — not a real Windows
  #      path, failed instantly (`exec: "/bin/sh": executable file not found`).
  #   2. No interpreter (OS default = cmd.exe on Windows) with a plain
  #      `aws ec2 wait ...` command, on the theory that a single flat command
  #      needs no shell-specific syntax — wrong: cmd.exe's quote-parsing
  #      still isn't POSIX-compatible, and it mangled the `--filters` value
  #      (`Expected: '=', received: '"'`).
  #   3. `sh`/`bash` resolved via bare PATH lookup — found, but both hits
  #      (`C:\Windows\System32\bash.exe`, `...\WindowsApps\bash.exe`) are WSL
  #      launcher stubs that fail with `execvpe(/bin/bash) failed: No such
  #      file or directory` when WSL itself isn't set up — same failure class
  #      as the documented `python3`-vs-`python` Windows Store alias gotcha
  #      elsewhere in this project.
  # What actually works, confirmed directly (not assumed): Git for Windows'
  # own bash.exe, at its real absolute install location — set via
  # TF_VAR_local_exec_shell_path (or the Terragrunt env-var passthrough, same
  # pattern as ADMIN_PRINCIPAL_ARN) on machines where /bin/sh isn't real.
  # `aws ec2 wait instance-terminated` does NOT treat a zero-match filter as
  # instant success — confirmed for real 2026-07-02: with genuinely zero
  # matching instances in the account, it still burned its full default
  # attempt budget and failed with "Max attempts exceeded" instead of
  # returning immediately. Checking the count first and only invoking the
  # waiter when there's something to actually wait for avoids this.
  provisioner "local-exec" {
    when        = destroy
    interpreter = [self.triggers.local_exec_shell_path, "-c"]
    command     = <<-EOT
      set -eu
      filters=(--filters "Name=iam-instance-profile.arn,Values=*${self.triggers.node_iam_role_name}*" "Name=instance-state-name,Values=pending,running,shutting-down,stopping")
      count=$(aws ec2 describe-instances --region us-east-1 "$${filters[@]}" --query 'length(Reservations[].Instances[])' --output text)
      if [ "$count" != "0" ]; then
        aws ec2 wait instance-terminated --region us-east-1 "$${filters[@]}"
      fi
    EOT
  }
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
