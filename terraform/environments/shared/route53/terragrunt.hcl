include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/route53"
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id = "vpc-mock12345"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init", "destroy"]
}

dependency "ingress_nginx" {
  config_path = "../ingress-nginx"

  mock_outputs = {
    load_balancer_hostname = "mock-nlb-1234567890.elb.us-east-1.amazonaws.com"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init", "destroy"]
}

inputs = {
  vpc_id                  = dependency.vpc.outputs.vpc_id
  load_balancer_hostname  = dependency.ingress_nginx.outputs.load_balancer_hostname
}
