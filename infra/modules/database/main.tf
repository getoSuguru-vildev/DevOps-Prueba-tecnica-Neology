# PostgreSQL administrado (RDS). La contraseña maestra la genera y rota RDS dentro de Secrets Manager:
# nunca aparece en Terraform, en el estado ni en variables.

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = var.subnet_ids
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.name}-postgres16"
  family = "postgres16"

  # Solo conexiones cifradas.
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  # Queries de más de 500 ms quedan en el log: primera pista cuando sube la latencia.
  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  # Corta transacciones abiertas y olvidadas que retienen conexiones y locks.
  parameter {
    name  = "idle_in_transaction_session_timeout"
    value = "60000"
  }

  parameter {
    name  = "statement_timeout"
    value = "30000"
  }
}

resource "aws_db_instance" "this" {
  identifier = "${var.name}-postgres"

  engine                     = "postgres"
  engine_version             = var.engine_version
  auto_minor_version_upgrade = true
  instance_class             = var.instance_class
  parameter_group_name       = aws_db_parameter_group.this.name

  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name                             = var.db_name
  username                            = var.master_username
  manage_master_user_password         = true
  iam_database_authentication_enabled = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  # Respaldos automáticos + point in time recovery dentro de la retención.
  backup_retention_period  = var.backup_retention_days
  backup_window            = "08:00-09:00"
  maintenance_window       = "sun:09:30-sun:10:30"
  copy_tags_to_snapshot    = true
  delete_automated_backups = false

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = !var.final_snapshot
  final_snapshot_identifier = var.final_snapshot ? "${var.name}-postgres-final" : null

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]
}
