include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/elasticache"
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

# Applies after rds — needs its DATABASE_URL/JWT outputs to compose the
# final /chess-prod/room and /chess-prod/game secrets (see rds module's
# main.tf for why rds itself doesn't write those two parameters).
dependency "rds" {
  config_path = "../rds"

  mock_outputs = {
    database_urls = {
      auth = "mysql+pymysql://mock:mock@mock:3306/auth_db"
      room = "mysql+pymysql://mock:mock@mock:3306/room_db"
      game = "mysql+pymysql://mock:mock@mock:3306/game_db"
    }
    jwt_secret_key = "mock-jwt-secret"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init", "destroy"]
}

inputs = {
  name = "chess-prod"

  vpc_id              = dependency.vpc.outputs.vpc_id
  vpc_cidr            = dependency.vpc.outputs.cidr
  database_subnet_ids = dependency.vpc.outputs.database_subnet_ids

  room_database_url = dependency.rds.outputs.database_urls["room"]
  game_database_url = dependency.rds.outputs.database_urls["game"]
  jwt_secret_key     = dependency.rds.outputs.jwt_secret_key
}
