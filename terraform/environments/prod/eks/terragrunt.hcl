include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/eks"
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id             = "vpc-00000000000000000"
    private_subnet_ids = ["subnet-00000000000000000", "subnet-11111111111111111", "subnet-22222222222222222"]
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init", "destroy"]
}

inputs = {
  cluster_name       = "chess-prod"
  vpc_id             = dependency.vpc.outputs.vpc_id
  private_subnet_ids = dependency.vpc.outputs.private_subnet_ids

  # Never commit the real ARN (account ID + IAM username) — export before apply:
  # export ADMIN_PRINCIPAL_ARN=$(aws sts get-caller-identity --query Arn --output text)
  admin_principal_arn = get_env("ADMIN_PRINCIPAL_ARN", "")
}