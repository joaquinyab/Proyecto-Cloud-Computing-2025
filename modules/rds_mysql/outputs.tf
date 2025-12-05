output "endpoint" {
  value = aws_db_instance.this.address
}

output "id" {
  description = "El ID de la instancia RDS"
  value       = aws_db_instance.this.identifier
}
