include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/rds"
}

# Only depends on vpc — deliberately no dependency on eks. RDS provisioning
# (allocate storage, Multi-AZ standby, DNS) takes 10-15+ minutes regardless
# of the cluster, so applying it in parallel with eks/karpenter/nodepools
# means the database is already up and ready by the time chess-chart
# actually gets deployed, instead of queuing behind the cluster first.
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

  # Applying this module (mysql_database/mysql_user/mysql_grant) requires a
  # live MySQL connection to the RDS instance — only reachable from inside
  # the VPC (private database subnets, publicly_accessible = false). Run
  # this while connected to prod's VPN, same requirement as any kubectl/helm
  # provider call against the EKS API.
}
