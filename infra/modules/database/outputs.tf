output "address" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "db_name" {
  value = aws_db_instance.this.db_name
}

output "instance_id" {
  value = aws_db_instance.this.identifier
}

output "master_secret_arn" {
  description = "Secreto de Secrets Manager con username y password (JSON), administrado y rotado por RDS."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}
