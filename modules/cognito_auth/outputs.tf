output "user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "domain_prefix" {
  value = aws_cognito_user_pool_domain.domain_unique.domain
}

output "domain_url" {
  value = "https://${aws_cognito_user_pool_domain.domain_unique.domain}.auth.${var.region}.amazoncognito.com"
}

output "user_pool_arn" {
  value = aws_cognito_user_pool.this.arn
}
