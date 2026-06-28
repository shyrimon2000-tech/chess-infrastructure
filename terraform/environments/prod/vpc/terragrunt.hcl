include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/vpc"
}

inputs = {
  name = "chess-prod"
  cidr = "192.168.0.0/16"
  azs  = ["us-east-1a", "us-east-1b", "us-east-1c"]
  
  public_subnets   = ["192.168.1.0/24", "192.168.2.0/24", "192.168.3.0/24"]
  private_subnets  = ["192.168.10.0/24", "192.168.11.0/24", "192.168.12.0/24"]
  database_subnets = ["192.168.20.0/24", "192.168.21.0/24", "192.168.22.0/24"]
}