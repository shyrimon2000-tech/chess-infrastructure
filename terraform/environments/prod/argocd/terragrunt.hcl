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

# Ordering-only dependency — chess-chart's rds-bootstrap Job (Helm
# post-install/post-upgrade hook) needs the RDS instance and its SSM secrets
# to already exist, or it fails on first sync. Prod's sync policy is manual
# anyway (a human decides when to sync), but this makes it structurally
# impossible for ArgoCD itself to exist before RDS does, rather than relying
# only on the human not syncing too early. No output is ever read from this
# dependency.
dependency "rds" {
  config_path = "../rds"

  mock_outputs                            = {}
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init", "destroy", "apply"]
}

# Same reasoning as the rds dependency above, for the other half of the
# bootstrap Job's credentials — room/game's DATABASE_URL secrets are written
# by elasticache, not rds (rds deliberately leaves them unwritten, see its
# own SSM-ownership comment). Without this, the Job could fail parsing an
# empty ROOM_DATABASE_URL/GAME_DATABASE_URL on a sync that races ahead of
# elasticache's own apply.
dependency "elasticache" {
  config_path = "../elasticache"

  mock_outputs                            = {}
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init", "destroy", "apply"]
}

# Same reasoning again, different failure mode — chess-chart's own Ingress
# objects use `ingressClassName: alb`, and aws-load-balancer-controller's
# Ingress-validating webhook (`vingress.elbv2.k8s.aws`, still active - only
# the *Service*-mutating webhook was disabled, see README Troubleshooting's
# ALB webhook race entry) must be up before any Ingress create can pass
# admission - same class of race already handled for ingress-nginx above.
dependency "alb_controller" {
  config_path = "../alb-controller"

  mock_outputs                            = {}
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init", "destroy", "apply"]
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

  # Single namespace here, no split needed — see app_projects description
  # in variables.tf.
  app_projects = {
    "apps" = ["production"]
  }

  # VPN-only, private — same nginx+Ingress pattern as shared, not the public
  # ALB. The chess services themselves still go through the ALB; only the
  # admin-facing ArgoCD UI needs to stay off the public internet.
  ingress_enabled  = true
  ingress_hostname = "argocd.chess-prod.internal"
}
