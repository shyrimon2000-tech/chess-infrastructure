include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/rds"
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id              = "vpc-mock12345"
    cidr                = "192.168.0.0/16"
    database_subnet_ids = ["subnet-mockdb1", "subnet-mockdb2", "subnet-mockdb3"]
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init", "destroy"]
}

inputs = {
  name = "chess-prod"

  vpc_id              = dependency.vpc.outputs.vpc_id
  vpc_cidr            = dependency.vpc.outputs.cidr
  database_subnet_ids = dependency.vpc.outputs.database_subnet_ids

  # No live MySQL connection needed at apply/destroy time - this module only
  # creates the RDS instance and publishes desired credentials to SSM (pure
  # AWS API). The actual database/user/grant creation happens via a Helm hook
  # Job in chess-chart, which runs inside the cluster - see README
  # Troubleshooting. Restored to depending on vpc alone (not vpn/eks), same as
  # before that constraint existed - RDS's own 10-15+ min provisioning can run
  # fully parallel with eks/karpenter/nodepools again.
}
