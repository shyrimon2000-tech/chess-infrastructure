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

# Ordering-only dependency — this unit's mysql_database/mysql_user/mysql_grant
# resources (provider "mysql") need a live TCP:3306 connection to the private
# RDS instance, reachable only through the VPN, on *both* apply and destroy.
# Without this edge, `terragrunt run --all destroy` has no reason to keep vpn
# alive until rds finishes: it could tear vpn down first (or in parallel),
# stranding these resources with no path to reach RDS to drop them. Terragrunt
# destroys in reverse dependency order, so this makes rds (and elasticache,
# which already depends on rds) destroy *before* vpn, not after — vpn stays up
# exactly as long as it's needed. No output is ever read from this dependency.
#
# Trade-off: vpn itself depends on eks (needs cluster_name), so this makes rds
# transitively depend on eks too — rds's apply can no longer run fully
# parallel with eks/karpenter/nodepools (RDS's own 10-15+ min provisioning
# used to overlap with cluster bring-up). Correctness on destroy was judged
# more important than apply-time parallelism here.
dependency "vpn" {
  config_path = "../vpn"

  mock_outputs                            = {}
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init", "destroy", "apply"]
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
