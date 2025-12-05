output "website_url" { value = module.s3_website.website_url }
output "api_invoke_url" { value = module.lambdas_api.api_invoke_url }
output "cognito_domain" { value = module.cognito_auth.domain_url }
output "rds_endpoint" { value = module.rds_mysql.endpoint }
output "sns_topic_arn" { value = module.sns.topic_arn }


output "login_url_ready" {
  value = "https://${replace(module.cognito_auth.domain_url, "https://", "")}/oauth2/authorize?client_id=${module.lambdas_api.cognito_client_id}&response_type=code&scope=openid%20email%20profile&redirect_uri=${urlencode("${module.lambdas_api.api_invoke_url}/callback")}"
}
