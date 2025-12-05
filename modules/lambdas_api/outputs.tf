output "api_invoke_url" {
  value = local.api_invoke_url
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.client.id
}
output "lambda_dbinit_name" {
  value = aws_lambda_function.dbinit.function_name
}