remote_state {
  backend = "s3"
  config = {
    bucket = "chess-terraform-state-221556121262"
    # path_relative_to_include() returns OS-native path separators —
    # backslashes on Windows, forward slashes on Linux (the GitHub Actions
    # runner). Left unnormalized, applies from the two platforms computed
    # different S3 keys for the exact same unit (e.g.
    # "environments\prod\vpc/terraform.tfstate" from a Windows apply vs
    # "environments/prod/vpc/terraform.tfstate" from CI) — the CI role
    # would see no state at all for anything only ever applied from a
    # laptop, and plan as if creating it from scratch. replace() forces a
    # single, consistent key regardless of which OS runs the apply.
    key          = "${replace(path_relative_to_include(), "\\", "/")}/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = "us-east-1"
}
EOF
}