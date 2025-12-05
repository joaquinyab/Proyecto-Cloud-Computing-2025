output "app_subnet_ids" {
  description = "Subnets privadas para Lambdas"
  value       = module.vpc.private_subnets
}

output "db_subnet_ids" {
  description = "Subnets privadas para RDS"
  value       = module.vpc.database_subnets
}

output "sg_lambda_id" {
  description = "Security Group para Lambdas"
  value       = aws_security_group.lambda.id
}

output "sg_rds_id" {
  description = "Security Group para RDS"
  value       = aws_security_group.rds.id
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "Rango de IP de la VPC"
  value       = module.vpc.vpc_cidr_block
}
