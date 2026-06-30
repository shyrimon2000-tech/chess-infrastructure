module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.name
  cidr = var.cidr

  azs              = var.azs
  public_subnets   = var.public_subnets
  private_subnets  = var.private_subnets
  database_subnets = var.database_subnets

  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  private_subnet_tags = merge(var.private_subnet_tags, {
    "kubernetes.io/cluster/${var.name}" = "shared"
  })

  public_subnet_tags = merge(var.public_subnet_tags, {
    "kubernetes.io/cluster/${var.name}" = "shared"
  })
}
