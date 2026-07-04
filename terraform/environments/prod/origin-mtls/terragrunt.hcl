include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Excluded from `run --all destroy` only (still fully part of `run --all
# apply`/`plan`) — same reasoning as frontend/terragrunt.hcl: the self-signed
# CA, client cert, ALB trust store and ALB's own server cert here cost
# effectively nothing to leave sitting idle, but every one of them gets a new
# ARN if destroyed and recreated. Since frontend (client_certificate_arn) and
# chess-chart's values-prod.yaml (alb_certificate_arn, trust_store_arn) all
# reference these ARNs, tearing this unit down on every cost-saving
# destroy/apply cycle would force re-pasting values every single time instead
# of once at bootstrap.
exclude {
  if      = get_terraform_command() == "destroy"
  actions = ["all"]
}

terraform {
  source = "../../../modules/origin-mtls"
}

# No dependency blocks — self-signed CA + client cert (ACM) + ALB trust
# store (S3) are all independent of vpc/eks, same as frontend. Applies in
# parallel with everything else; frontend depends on this unit's
# client_certificate_arn output, alb-controller consumes the trust store ARN
# indirectly via chess-chart's values-prod.yaml (Terraform/Helm boundary, not
# a Terraform dependency).
inputs = {
  name = "chess-prod"
}
