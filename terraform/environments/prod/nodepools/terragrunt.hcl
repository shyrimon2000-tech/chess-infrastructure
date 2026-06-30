include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/nodepools"
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs = {
    cluster_name                       = "mock-cluster"
    cluster_endpoint                   = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority_data = "bW9jaw=="
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "karpenter" {
  config_path = "../karpenter"

  mock_outputs = {
    node_iam_role_name = "mock-node-role"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
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
  cluster_name       = dependency.eks.outputs.cluster_name
  node_iam_role_name = dependency.karpenter.outputs.node_iam_role_name
  simplified         = false
}
