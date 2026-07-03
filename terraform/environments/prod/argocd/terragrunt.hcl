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

# Ordering-only dependency — same reason as shared/argocd/terragrunt.hcl:
# argocd's own Ingress resource is validated by ingress-nginx's admission
# webhook, so ingress-nginx must fully apply first. Its output isn't
# consumed here; the block itself is what enforces the apply order.
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
  name = "chess-prod"

  # Root Application watches helm/git-ops/prod/ — a single hand-written
  # manual-bucket ApplicationSet there (no automated env exists for prod).
  gitops_dir             = "prod"
  gitops_target_revision = "main"

  # VPN-only, private — same nginx+Ingress pattern as shared, not the public
  # ALB. The chess services themselves still go through the ALB; only the
  # admin-facing ArgoCD UI needs to stay off the public internet.
  ingress_enabled  = true
  ingress_hostname = "argocd.chess-prod.internal"
}
