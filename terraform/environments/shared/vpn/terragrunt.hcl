include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/vpn"
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id            = "vpc-mock12345"
    cidr              = "10.0.0.0/16"
    public_subnet_ids = ["subnet-mockpublic1"]
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init", "destroy"]
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs = {
    cluster_name = "mock-cluster"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init", "destroy"]
}

inputs = {
  name             = "chess-shared"
  subdomain        = "vpn-shared"
  vpc_id           = dependency.vpc.outputs.vpc_id
  vpc_cidr         = dependency.vpc.outputs.cidr
  public_subnet_id = dependency.vpc.outputs.public_subnet_ids[0]
  cluster_name     = dependency.eks.outputs.cluster_name

  # wg-easy panel password hash is read from SSM (/chess-shared/vpn/wg-easy-password-hash),
  # created manually — same pattern as the ArgoCD admin password hash.
}
