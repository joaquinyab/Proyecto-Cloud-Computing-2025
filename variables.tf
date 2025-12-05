variable "aws_region" {
  type        = string
  description = "Región AWS"
  default     = "us-east-1"
}

variable "aws_profile" {
  type        = string
  description = "Perfil de AWS CLI (opcional)"
  default     = ""
}

variable "project_name" {
  type        = string
  description = "Nombre del proyecto"
  default     = "tripmate"
}

variable "tags" {
  type        = map(string)
  description = "Tags comunes"
  default     = {}
}

variable "website_bucket_name" {
  type        = string
  description = "Nombre del bucket website (único global). Si vacío, usa <project>-web"
  default     = ""
}

# DB
variable "db_username" {
  type    = string
  default = "admin"
}
variable "db_password" {
  type    = string
  default = "admin2025lula"
}
variable "db_name" {
  type    = string
  default = "basededatostripmate2025bd"
}

# SNS
variable "sns_email_subscription" {
  type        = string
  description = "Email para suscripción SNS (opcional)"
  default     = ""
}

# Cognito
variable "cognito_domain_prefix" {
  type        = string
  description = "Prefijo único para el dominio de Cognito Hosted UI"
  default     = "tripmate-joaco"
}














