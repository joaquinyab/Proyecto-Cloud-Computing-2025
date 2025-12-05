terraform {
  required_providers {
    aws    = { source = "hashicorp/aws" }
    random = { source = "hashicorp/random" }
  }
}

# sufijo único para el dominio
resource "random_id" "suffix" {
  byte_length = 3
}

resource "aws_cognito_user_pool" "this" {
  name = "${var.project}-pool"
  tags = var.tags

  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  auto_verified_attributes = ["email"]
  username_attributes      = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = false
    require_numbers   = false
    require_symbols   = false
    require_uppercase = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

# Dominio único para evitar choques
resource "aws_cognito_user_pool_domain" "domain_unique" {
  domain       = lower("${var.project}-${random_id.suffix.hex}")
  user_pool_id = aws_cognito_user_pool.this.id
}

