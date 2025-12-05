terraform {
  required_providers {
    aws    = { source = "hashicorp/aws" }
    random = { source = "hashicorp/random" }
  }
}

# Sufijo único para evitar colisiones entre cuentas/equipos
resource "random_id" "sns" {
  byte_length = 3
}

resource "aws_sns_topic" "this" {
  name = "${var.project}-topic-${random_id.sns.hex}"
  tags = var.tags
}

# Suscripción por email OPCIONAL (solo si var.email no está vacío)
resource "aws_sns_topic_subscription" "email" {
  count     = length(trimspace(var.email)) > 0 ? 1 : 0
  topic_arn = aws_sns_topic.this.arn
  protocol  = "email"
  endpoint  = var.email
}
