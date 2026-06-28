output "vpc_id" {
    description = "ID of the VPC"
    value       = module.vpc.vpc_id
}

output "public_subnets" {
    description = "ID of the public subnets"
    value       = module.vpc.public_subnets
}

output "private_subnets" {
    description = "ID of the private subnets"
    value       = module.vpc.private_subnets
}

output "database_subnets" {
    description = "ID of the database subnets"
    value       = module.vpc.database_subnets
}