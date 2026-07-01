include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/eso"
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs = {
    cluster_name                       = "mock-cluster"
    cluster_endpoint                   = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority_data = "bW9jaw=="
    oidc_provider_arn                  = "arn:aws:iam::123456789012:oidc-provider/mock"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init", "destroy", "import"]
}

# Ordering-only dependency — the ESO controller pod runs in the "external-secrets"
# namespace, which isn't covered by any Fargate profile in the eks module (only
# karpenter/argocd/grafana/ingress-nginx/kube-dns are), so it can only schedule on
# a real EC2 node. Without this, eso can apply in parallel with karpenter/nodepools
# and its helm_release times out waiting for a pod that has nowhere to run yet —
# same root cause as the EBS CSI Driver's ordering fix. nodepools has no outputs;
# this block exists purely to force apply order.
dependency "nodepools" {
  config_path = "../nodepools"

  # "apply" included too, unlike other dependency blocks in this repo — nodepools
  # has no real outputs at all (empty outputs.tf), so there's never a "real" value
  # to resolve even after a successful apply. Safe here specifically because this
  # dependency exists only for ordering (see comment above) and no input ever
  # reads dependency.nodepools.outputs.*.
  mock_outputs                            = {}
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init", "destroy", "apply", "import"]
}

generate "helm_provider" {
  path      = "helm_provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "helm" {
  kubernetes = {
    host                   = "${dependency.eks.outputs.cluster_endpoint}"
    cluster_ca_certificate = base64decode("${dependency.eks.outputs.cluster_certificate_authority_data}")
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", "${dependency.eks.outputs.cluster_name}"]
    }
  }
}
EOF
}

generate "kubectl_provider" {
  path      = "kubectl_provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "kubectl" {
  host                   = "${dependency.eks.outputs.cluster_endpoint}"
  cluster_ca_certificate = base64decode("${dependency.eks.outputs.cluster_certificate_authority_data}")
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", "${dependency.eks.outputs.cluster_name}"]
  }
}
EOF
}

inputs = {
  name              = "chess-shared"
  oidc_provider_arn = dependency.eks.outputs.oidc_provider_arn
}
