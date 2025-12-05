variable "lambda_role_arn" {
  type        = string
  description = "ARN de un rol IAM ya existente (del lab). Si viene, no se crea uno nuevo."
  default     = null
}


variable "domain_url" {
  type = string
}


variable "project" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "region" {
  type = string
}

# VPC
variable "lambda_subnet_ids" {
  type = list(string)
}

variable "lambda_sg_id" {
  type = string
}

# DB
variable "db_host" {
  type = string
}

variable "db_user" {
  type = string
}

variable "db_password" {
  type = string
}

variable "db_name" {
  type = string
}

# SNS
variable "sns_topic_arn" {
  type = string
}

# Front/CORS (pueden venir null desde root)
variable "frontend_hostname" {
  type    = string
  default = null
}

variable "cors_origin" {
  type    = string
  default = null
}

# Cognito
variable "user_pool_id" {
  type = string
}

# Código (rutas)
variable "lambda_backend_dir" {
  type = string
}

variable "lambda_callback_dir" {
  type = string
}

variable "lambda_dbinit_dir" {
  type = string
}

variable "lambda_signout_dir" {
  type = string
}
variable "stage_name" {
  type        = string
  description = "Nombre del stage de API Gateway"
  default     = "prod"
}

variable "user_pool_arn" {
  type        = string
  description = "ARN del User Pool de Cognito"
}






