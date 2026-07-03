include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/argocd"
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs = {
    cluster_name                       = "mock-cluster"
    cluster_endpoint                   = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority_data = "bW9jaw=="
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init", "destroy"]
}

# Ordering-only dependency — argocd's own Ingress resource is validated by
# ingress-nginx's admission webhook. Without this, both units can apply in
# parallel and argocd's helm_release fails with "no endpoints available for
# service ingress-nginx-controller-admission" if it races ahead. Its output
# isn't consumed here; the block itself is what enforces the apply order.
dependency "ingress_nginx" {
  config_path = "../ingress-nginx"

  mock_outputs = {
    load_balancer_hostname = "mock-nlb-1234567890.elb.us-east-1.amazonaws.com"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init", "destroy"]
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
  name = "chess-shared"

  environments = [
    {
      name            = "dev"
      namespace       = "dev"
      values_file     = "values-dev.yaml"
      target_revision = "dev"
      automated       = true
      prune           = true
      self_heal       = false
    },
    {
      name            = "staging"
      namespace       = "staging"
      values_file     = "values-staging.yaml"
      target_revision = "dev"
      automated       = false
      prune           = false
      self_heal       = false
    }
  ]

  ingress_enabled = true
}
