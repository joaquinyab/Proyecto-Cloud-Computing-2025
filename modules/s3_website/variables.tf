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

variable "website_bucket_name" {
  type        = string
  description = "Nombre del bucket (si null -> <project>-web)"
  default     = null
}

# Rutas a tus HTML base en disco
variable "login_file_path" {
  type = string
}

variable "app_file_path" {
  type = string
}

# Contenido JS renderizado por el root (se injecta al final del HTML)
variable "login_inline_js" {
  type        = string
  description = "Contenido JS renderizado para login.html"
  default     = ""
}

variable "app_inline_js" {
  type        = string
  description = "Contenido JS renderizado para app.html"
  default     = ""
}
