include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Excluded from `run --all destroy` only (still fully part of `run --all
# apply`/`plan`). IAM roles/OIDC providers are free to leave idle (unlike
# origin-mtls/frontend, this isn't about ARN stability — an IAM role's ARN
# is deterministic from account ID + name, so it wouldn't actually change on
# recreate). The real reason: destroying this alongside everything else
# would leave the CI pipeline with no role to assume the next time it needs
# to re-apply anything, including re-provisioning shared/prod themselves —
# a chicken-and-egg that'd force a manual bootstrap apply every single
# destroy/apply cycle instead of once, ever.
exclude {
  if      = get_terraform_command() == "destroy"
  actions = ["all"]
}

terraform {
  source = "../../../modules/github-oidc"
}

# Account-wide, not tied to shared or prod — hence "global" rather than
# living under either environment folder. Only ever applied once (or when
# adding a new trusted branch), not part of the shared/prod apply cycle.
inputs = {
  github_repo = "shyrimon2000-tech/chess-infrastructure"
}
