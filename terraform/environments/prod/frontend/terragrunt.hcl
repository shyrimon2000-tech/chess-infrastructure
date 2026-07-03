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

inputs = {
  name      = "chess-prod"
  subdomain = "chess"

  # No dependency blocks — frontend hosting (S3 + CloudFront) is fully
  # independent of the EKS cluster (see CLAUDE.md: "Prod: S3 + CloudFront,
  # no pod in cluster"). Can apply/destroy on its own schedule regardless of
  # whether the rest of prod is up.

  # Must match helm/chess-chart/values-prod.yaml's ingress.alb.originVerifySecret
  # verbatim — see the frontend module's variable description for why this
  # is committed in plaintext (public pet-project repo tradeoff, documented
  # in README ALB/ExternalDNS section).
  origin_verify_secret = "096d4fbd66f78caa511abee115339b1f50d5d84c836e168a10d2e6c82b163ba2"
}
