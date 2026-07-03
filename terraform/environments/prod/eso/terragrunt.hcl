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

# Ordering-only dependency — see shared/eso/terragrunt.hcl for why: the ESO
# controller pod needs a real EC2 node (no Fargate profile covers its
# namespace), so it must apply after nodepools gives Karpenter something to
# provision from.
dependency "nodepools" {
  config_path = "../nodepools"

  # "apply" included too, unlike other dependency blocks in this repo — nodepools
  # has no real outputs at all (empty outputs.tf), so there's never a "real" value
  # to resolve even after a successful apply. Safe here specifically because this
  # dependency exists only for ordering and no input ever reads
  # dependency.nodepools.outputs.*.
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
  name              = "chess-prod"
  oidc_provider_arn = dependency.eks.outputs.oidc_provider_arn
}
