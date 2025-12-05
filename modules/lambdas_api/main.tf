terraform {
  required_providers {
    aws     = { source = "hashicorp/aws" }
    archive = { source = "hashicorp/archive" }
  }
}

locals {
  name       = var.project
  api_name   = "${var.project}-api"
  stage_name = var.stage_name

  frontend_host_fallback = "${var.project}-web.s3-website-${var.region}.amazonaws.com"
  frontend_host          = coalesce(var.frontend_hostname, local.frontend_host_fallback)
  allow_origin           = coalesce(var.cors_origin, "http://${local.frontend_host}")

  api_id         = aws_api_gateway_rest_api.api.id
  api_invoke_url = "https://${local.api_id}.execute-api.${var.region}.amazonaws.com/${local.stage_name}"

  callback_path = "callback"
  signout_path  = "signout"
  guardar_path  = "guardar"
  listar_path   = "listar"
  unirse_path   = "unirse"
}

# ============================================================
# IAM ROLE LAMBDA
# ============================================================
resource "aws_iam_role" "lambda_role" {
  count = var.lambda_role_arn == null ? 1 : 0
  name  = "${var.project}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "basic_logs" {
  count      = var.lambda_role_arn == null ? 1 : 0
  role       = aws_iam_role.lambda_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "sns_inline" {
  count = var.lambda_role_arn == null ? 1 : 0
  name  = "${var.project}-sns-inline"
  role  = aws_iam_role.lambda_role[0].id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "CloudWatchLogs",
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "*"
      },
      {
        Sid    = "SnsPerTripTopics",
        Effect = "Allow",
        Action = [
          "sns:CreateTopic",
          "sns:Publish",
          "sns:Subscribe",
          "sns:GetTopicAttributes",
          "sns:ListSubscriptionsByTopic",
          "sns:GetSubscriptionAttributes",
          "sns:SetSubscriptionAttributes",
          "sns:SetTopicAttributes"
        ],
        Resource = "arn:aws:sns:*:*:${var.project}-*"
      }
    ]
  })
}

# ============================================================
# ZIPs LAMBDAS
# ============================================================
data "archive_file" "zip_backend" {
  type        = "zip"
  source_dir  = var.lambda_backend_dir
  output_path = "${path.module}/.zips/backend.zip"
}

data "archive_file" "zip_callback" {
  type        = "zip"
  source_dir  = var.lambda_callback_dir
  output_path = "${path.module}/.zips/callback.zip"
}

data "archive_file" "zip_dbinit" {
  type        = "zip"
  source_dir  = var.lambda_dbinit_dir
  output_path = "${path.module}/.zips/dbinit.zip"
}

data "archive_file" "zip_signout" {
  type        = "zip"
  source_dir  = var.lambda_signout_dir
  output_path = "${path.module}/.zips/signout.zip"
}

# ============================================================
# LAMBDAS
# ============================================================
resource "aws_lambda_function" "backend" {
  function_name = "${var.project}-backend"
  role          = var.lambda_role_arn != null ? var.lambda_role_arn : aws_iam_role.lambda_role[0].arn

  handler = "index.handler"
  runtime = "nodejs20.x"

  filename         = data.archive_file.zip_backend.output_path
  source_code_hash = data.archive_file.zip_backend.output_base64sha256

  vpc_config {
    subnet_ids         = var.lambda_subnet_ids
    security_group_ids = [var.lambda_sg_id]
  }

  environment {
    variables = {
      DB_HOST      = var.db_host
      DB_USER      = var.db_user
      DB_PASSWORD  = var.db_password
      DB_NAME      = var.db_name
      SNS_TOPIC    = var.sns_topic_arn
      CORS_ORIGIN  = local.allow_origin
      TOPIC_PREFIX = "${var.project}-"
    }
  }

  tags = var.tags
}

resource "aws_lambda_function" "callback" {
  function_name = "${var.project}-callback"
  role          = var.lambda_role_arn != null ? var.lambda_role_arn : aws_iam_role.lambda_role[0].arn

  handler          = "index.handler"
  runtime          = "nodejs20.x"
  filename         = data.archive_file.zip_callback.output_path
  source_code_hash = data.archive_file.zip_callback.output_base64sha256
  tags             = var.tags

  environment {
    variables = {
      COGNITO_DOMAIN    = var.domain_url
      CLIENT_ID         = aws_cognito_user_pool_client.client.id
      CLIENT_SECRET     = aws_cognito_user_pool_client.client.client_secret
      REDIRECT_URI      = "${local.api_invoke_url}/callback"
      FRONTEND_REDIRECT = "http://${local.frontend_host}/app.html"
    }
  }
}

resource "aws_lambda_function" "dbinit" {
  function_name = "${var.project}-dbinit"
  role          = var.lambda_role_arn != null ? var.lambda_role_arn : aws_iam_role.lambda_role[0].arn
  
  handler = "index.handler"
  runtime = "nodejs20.x"

  filename         = data.archive_file.zip_dbinit.output_path
  source_code_hash = data.archive_file.zip_dbinit.output_base64sha256

  vpc_config {
    subnet_ids         = var.lambda_subnet_ids
    security_group_ids = [var.lambda_sg_id]
  }

  environment {
    variables = {
      DB_HOST     = var.db_host
      DB_USER     = var.db_user
      DB_PASSWORD = var.db_password
      DB_NAME     = var.db_name
    }
  }

  timeout = 300

  tags = var.tags
}

resource "aws_lambda_function" "signout" {
  function_name = "${var.project}-signout"
  role          = var.lambda_role_arn != null ? var.lambda_role_arn : aws_iam_role.lambda_role[0].arn

  handler = "index.handler"
  runtime = "nodejs20.x"

  filename         = data.archive_file.zip_signout.output_path
  source_code_hash = data.archive_file.zip_signout.output_base64sha256

  environment {
    variables = {
      LOGIN_URL = "http://${local.frontend_host}/login.html"
    }
  }

  tags = var.tags
}

# ============================================================
# API GATEWAY: REST API Y RESOURCES
# ============================================================
resource "aws_api_gateway_rest_api" "api" {
  name        = local.api_name
  description = "TripMate REST API"
  tags        = var.tags
}

# Paths base
resource "aws_api_gateway_resource" "res_guardar" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = local.guardar_path
}

resource "aws_api_gateway_resource" "res_listar" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = local.listar_path
}

resource "aws_api_gateway_resource" "res_unirse" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = local.unirse_path
}

resource "aws_api_gateway_resource" "res_callback" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = local.callback_path
}

resource "aws_api_gateway_resource" "res_signout" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = local.signout_path
}

# /viajes/{id}/actividades y /votar
resource "aws_api_gateway_resource" "res_viajes" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "viajes"
}

resource "aws_api_gateway_resource" "res_viaje_id" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.res_viajes.id
  path_part   = "{id}"
}

resource "aws_api_gateway_resource" "res_actividades" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.res_viaje_id.id
  path_part   = "actividades"
}

resource "aws_api_gateway_resource" "res_act_id" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.res_actividades.id
  path_part   = "{actId}"
}

resource "aws_api_gateway_resource" "res_votar" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.res_act_id.id
  path_part   = "votar"
}

# /viajes/{id}/actividades/{actId}/pagar
resource "aws_api_gateway_resource" "res_pagar" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.res_act_id.id
  path_part   = "pagar"
}

# /viajes/{id}/resumen
resource "aws_api_gateway_resource" "res_resumen" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.res_viaje_id.id
  path_part   = "resumen"
}

# ============================================================
# MÉTODOS E INTEGRACIONES
# ============================================================

# ===== LISTAR =====
resource "aws_api_gateway_method" "method_listar" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.res_listar.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "int_listar" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.res_listar.id
  http_method             = aws_api_gateway_method.method_listar.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.backend.invoke_arn
}

resource "aws_api_gateway_method" "options_listar" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.res_listar.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "int_options_listar" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.res_listar.id
  http_method = aws_api_gateway_method.options_listar.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\":200}"
  }
}

resource "aws_api_gateway_method_response" "resp_options_listar" {
  rest_api_id     = aws_api_gateway_rest_api.api.id
  resource_id     = aws_api_gateway_resource.res_listar.id
  http_method     = aws_api_gateway_method.options_listar.http_method
  status_code     = "200"
  response_models = { "application/json" = "Empty" }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = true
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
  }
}

resource "aws_api_gateway_integration_response" "int_resp_options_listar" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.res_listar.id
  http_method = aws_api_gateway_method.options_listar.http_method
  status_code = aws_api_gateway_method_response.resp_options_listar.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'OPTIONS,GET,POST'"
  }
}

# ===== GUARDAR =====
resource "aws_api_gateway_method" "method_guardar" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.res_guardar.id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "int_guardar" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.res_guardar.id
  http_method             = aws_api_gateway_method.method_guardar.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.backend.invoke_arn
}

resource "aws_api_gateway_method" "options_guardar" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.res_guardar.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "int_options_guardar" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.res_guardar.id
  http_method = aws_api_gateway_method.options_guardar.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\":200}"
  }
}

resource "aws_api_gateway_method_response" "resp_options_guardar" {
  rest_api_id     = aws_api_gateway_rest_api.api.id
  resource_id     = aws_api_gateway_resource.res_guardar.id
  http_method     = aws_api_gateway_method.options_guardar.http_method
  status_code     = "200"
  response_models = { "application/json" = "Empty" }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = true
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
  }
}

resource "aws_api_gateway_integration_response" "int_resp_options_guardar" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.res_guardar.id
  http_method = aws_api_gateway_method.options_guardar.http_method
  status_code = aws_api_gateway_method_response.resp_options_guardar.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'OPTIONS,GET,POST'"
  }
}

# ===== UNIRSE =====
resource "aws_api_gateway_method" "method_unirse" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.res_unirse.id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "int_unirse" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.res_unirse.id
  http_method             = aws_api_gateway_method.method_unirse.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.backend.invoke_arn
}

resource "aws_api_gateway_method" "options_unirse" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.res_unirse.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "int_options_unirse" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.res_unirse.id
  http_method = aws_api_gateway_method.options_unirse.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\":200}"
  }
}

resource "aws_api_gateway_method_response" "resp_options_unirse" {
  rest_api_id     = aws_api_gateway_rest_api.api.id
  resource_id     = aws_api_gateway_resource.res_unirse.id
  http_method     = aws_api_gateway_method.options_unirse.http_method
  status_code     = "200"
  response_models = { "application/json" = "Empty" }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = true
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
  }
}

resource "aws_api_gateway_integration_response" "int_resp_options_unirse" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.res_unirse.id
  http_method = aws_api_gateway_method.options_unirse.http_method
  status_code = aws_api_gateway_method_response.resp_options_unirse.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'OPTIONS,GET,POST'"
  }
}

# ===== CALLBACK =====
resource "aws_api_gateway_method" "method_callback" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.res_callback.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "int_callback" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.res_callback.id
  http_method             = aws_api_gateway_method.method_callback.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.callback.invoke_arn
}

# ===== SIGNOUT =====
resource "aws_api_gateway_method" "method_signout" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.res_signout.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "int_signout" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.res_signout.id
  http_method             = aws_api_gateway_method.method_signout.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.signout.invoke_arn
}

# ===== ACTIVIDADES (GET/POST) =====
resource "aws_api_gateway_method" "get_actividades" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.res_actividades.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "int_get_actividades" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.res_actividades.id
  http_method             = aws_api_gateway_method.get_actividades.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.backend.invoke_arn
}

resource "aws_api_gateway_method" "post_actividades" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.res_actividades.id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "int_post_actividades" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.res_actividades.id
  http_method             = aws_api_gateway_method.post_actividades.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.backend.invoke_arn
}

resource "aws_api_gateway_method" "options_actividades" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.res_actividades.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "int_options_actividades" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.res_actividades.id
  http_method = aws_api_gateway_method.options_actividades.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\":200}"
  }
}

resource "aws_api_gateway_method_response" "resp_options_actividades" {
  rest_api_id     = aws_api_gateway_rest_api.api.id
  resource_id     = aws_api_gateway_resource.res_actividades.id
  http_method     = aws_api_gateway_method.options_actividades.http_method
  status_code     = "200"
  response_models = { "application/json" = "Empty" }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = true
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
  }
}

resource "aws_api_gateway_integration_response" "int_resp_options_actividades" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.res_actividades.id
  http_method = aws_api_gateway_method.options_actividades.http_method
  status_code = aws_api_gateway_method_response.resp_options_actividades.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'OPTIONS,GET,POST'"
  }
}

# ===== VOTAR (POST + OPTIONS) =====
resource "aws_api_gateway_method" "post_votar" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.res_votar.id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "int_post_votar" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.res_votar.id
  http_method             = aws_api_gateway_method.post_votar.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.backend.invoke_arn
}

resource "aws_api_gateway_method" "options_votar" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.res_votar.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "int_options_votar" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.res_votar.id
  http_method = aws_api_gateway_method.options_votar.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\":200}"
  }
}

resource "aws_api_gateway_method_response" "resp_options_votar" {
  rest_api_id     = aws_api_gateway_rest_api.api.id
  resource_id     = aws_api_gateway_resource.res_votar.id
  http_method     = aws_api_gateway_method.options_votar.http_method
  status_code     = "200"
  response_models = { "application/json" = "Empty" }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = true
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
  }
}

resource "aws_api_gateway_integration_response" "int_resp_options_votar" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.res_votar.id
  http_method = aws_api_gateway_method.options_votar.http_method
  status_code = aws_api_gateway_method_response.resp_options_votar.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'OPTIONS,GET,POST'"
  }
  depends_on = [
    aws_api_gateway_integration.int_options_votar
  ]
}

# ===== PAGAR (POST + OPTIONS) =====
resource "aws_api_gateway_method" "post_pagar" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.res_pagar.id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id

}

resource "aws_api_gateway_integration" "int_post_pagar" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.res_pagar.id
  http_method             = aws_api_gateway_method.post_pagar.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.backend.invoke_arn
}

resource "aws_api_gateway_method" "options_pagar" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.res_pagar.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "int_options_pagar" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.res_pagar.id
  http_method = aws_api_gateway_method.options_pagar.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\":200}"
  }
}

resource "aws_api_gateway_method_response" "resp_options_pagar" {
  rest_api_id     = aws_api_gateway_rest_api.api.id
  resource_id     = aws_api_gateway_resource.res_pagar.id
  http_method     = aws_api_gateway_method.options_pagar.http_method
  status_code     = "200"
  response_models = { "application/json" = "Empty" }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = true
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
  }
}

resource "aws_api_gateway_integration_response" "int_resp_options_pagar" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.res_pagar.id
  http_method = aws_api_gateway_method.options_pagar.http_method
  status_code = aws_api_gateway_method_response.resp_options_pagar.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'OPTIONS,GET,POST'"
  }
  depends_on = [
    aws_api_gateway_integration.int_options_pagar
  ]
}

# ===== RESUMEN (GET + OPTIONS) =====
resource "aws_api_gateway_method" "get_resumen" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.res_resumen.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id

}

resource "aws_api_gateway_integration" "int_get_resumen" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.res_resumen.id
  http_method             = aws_api_gateway_method.get_resumen.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.backend.invoke_arn
}

resource "aws_api_gateway_method" "options_resumen" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.res_resumen.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "int_options_resumen" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.res_resumen.id
  http_method = aws_api_gateway_method.options_resumen.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\":200}"
  }
}

resource "aws_api_gateway_method_response" "resp_options_resumen" {
  rest_api_id     = aws_api_gateway_rest_api.api.id
  resource_id     = aws_api_gateway_resource.res_resumen.id
  http_method     = aws_api_gateway_method.options_resumen.http_method
  status_code     = "200"
  response_models = { "application/json" = "Empty" }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = true
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
  }
}

resource "aws_api_gateway_integration_response" "int_resp_options_resumen" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.res_resumen.id
  http_method = aws_api_gateway_method.options_resumen.http_method
  status_code = aws_api_gateway_method_response.resp_options_resumen.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'OPTIONS,GET,POST'"
  }
  depends_on = [
    aws_api_gateway_integration.int_options_resumen
  ]
}

# ============================================================
# PERMISOS LAMBDA <- API GATEWAY
# ============================================================
resource "aws_lambda_permission" "api_to_backend" {
  statement_id  = "AllowAPIGatewayInvokeBackend"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backend.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "api_to_callback" {
  statement_id  = "AllowAPIGatewayInvokeCallback"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.callback.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "api_to_signout" {
  statement_id  = "AllowAPIGatewayInvokeSignout"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.signout.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

# ============================================================
# DEPLOY + STAGE
# ============================================================
resource "aws_api_gateway_deployment" "deploy" {
  rest_api_id = aws_api_gateway_rest_api.api.id

  depends_on = [
    aws_api_gateway_integration.int_listar,
    aws_api_gateway_integration.int_guardar,
    aws_api_gateway_integration.int_unirse,
    aws_api_gateway_integration.int_callback,
    aws_api_gateway_integration.int_signout,
    aws_api_gateway_integration.int_get_actividades,
    aws_api_gateway_integration.int_post_actividades,
    aws_api_gateway_integration.int_post_pagar,
    aws_api_gateway_integration.int_options_pagar,
    aws_api_gateway_integration.int_post_votar,
    aws_api_gateway_integration.int_options_listar,
    aws_api_gateway_integration.int_options_guardar,
    aws_api_gateway_integration.int_options_unirse,
    aws_api_gateway_integration.int_options_actividades,
    aws_api_gateway_integration.int_get_resumen,
    aws_api_gateway_integration.int_options_resumen,
    aws_api_gateway_integration_response.int_resp_options_votar,
    aws_api_gateway_integration_response.int_resp_options_resumen,
    aws_api_gateway_integration.int_get_todos,
    aws_api_gateway_integration.int_post_todos,
    aws_api_gateway_integration.int_options_todos,
    aws_api_gateway_integration_response.int_resp_options_todos,
  ]

  triggers = {
    redeploy = timestamp()
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "stage" {
  stage_name    = local.stage_name
  rest_api_id   = aws_api_gateway_rest_api.api.id
  deployment_id = aws_api_gateway_deployment.deploy.id
}

# ============================================================
# COGNITO APP CLIENT
# ============================================================
resource "aws_cognito_user_pool_client" "client" {
  name                                 = "${var.project}-app-client"
  user_pool_id                         = var.user_pool_id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = ["${local.api_invoke_url}/callback"]
  logout_urls   = ["${local.api_invoke_url}/signout"]
}


# /viajes/{id}/todos
resource "aws_api_gateway_resource" "res_todos" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.res_viaje_id.id
  path_part   = "todos"
}

# ===== TODOS (GET) =====
resource "aws_api_gateway_method" "get_todos" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.res_todos.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id

}

resource "aws_api_gateway_integration" "int_get_todos" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.res_todos.id
  http_method             = aws_api_gateway_method.get_todos.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.backend.invoke_arn
}

# ===== TODOS (POST) =====
resource "aws_api_gateway_method" "post_todos" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.res_todos.id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "int_post_todos" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.res_todos.id
  http_method             = aws_api_gateway_method.post_todos.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.backend.invoke_arn
}

# ===== TODOS (OPTIONS - CORS) =====
resource "aws_api_gateway_method" "options_todos" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.res_todos.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "int_options_todos" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.res_todos.id
  http_method = aws_api_gateway_method.options_todos.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\":200}"
  }
}

resource "aws_api_gateway_method_response" "resp_options_todos" {
  rest_api_id     = aws_api_gateway_rest_api.api.id
  resource_id     = aws_api_gateway_resource.res_todos.id
  http_method     = aws_api_gateway_method.options_todos.http_method
  status_code     = "200"
  response_models = { "application/json" = "Empty" }

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = true
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
  }
}

resource "aws_api_gateway_integration_response" "int_resp_options_todos" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.res_todos.id
  http_method = aws_api_gateway_method.options_todos.http_method
  status_code = aws_api_gateway_method_response.resp_options_todos.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'OPTIONS,GET,POST'"
  }
}

# ============================================================
# COGNITO AUTHORIZER
# ============================================================
resource "aws_api_gateway_authorizer" "cognito" {
  name            = "${var.project}-cognito-auth"
  rest_api_id     = aws_api_gateway_rest_api.api.id
  type            = "COGNITO_USER_POOLS"
  provider_arns   = [var.user_pool_arn]
  identity_source = "method.request.header.Authorization"
}