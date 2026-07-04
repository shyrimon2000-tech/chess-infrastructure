include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Excluded from `run --all destroy` only (still fully part of `run --all
# apply`/`plan`) — unlike EKS/EC2/NAT, S3 + CloudFront cost cents to sit
# idle, there's no reason to tear this down in the same cost-driven
# destroy/apply cycle as the rest of `shared`/`prod`. Tearing it down and
# reapplying also isn't instant like the other units — CloudFront takes
# 15-30 minutes to propagate to edge locations, so destroying it on every
# cost-saving cycle would make chess.alexit.online unreachable for that
# whole window on every single redeploy for no reason.
exclude {
  if      = get_terraform_command() == "destroy"
  actions = ["all"]
}

terraform {
  source = "../../../modules/frontend"
}

# Only dependency: origin-mtls's client certificate, which this distribution
# presents to the ALB. Still no dependency on vpc/eks — frontend hosting
# (S3 + CloudFront) stays fully independent of the EKS cluster (see
# CLAUDE.md: "Prod: S3 + CloudFront, no pod in cluster").
dependency "origin_mtls" {
  config_path = "../origin-mtls"

  mock_outputs = {
    client_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/mock"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init", "destroy"]
}

inputs = {
  name      = "chess-prod"
  subdomain = "chess"

  origin_mtls_client_certificate_arn = dependency.origin_mtls.outputs.client_certificate_arn
}
