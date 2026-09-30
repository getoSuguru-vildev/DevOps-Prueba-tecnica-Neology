variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "aws_account_id" {
  description = "Cuenta de AWS, para la key policy de la llave de alertas."
  type        = string
}

variable "alert_email" {
  description = "Correo que recibe las alertas. Vacío = sin suscripción."
  type        = string
  default     = ""
}

variable "alb_arn_suffix" {
  type = string
}

variable "backend_target_group_arn_suffix" {
  type = string
}

variable "target_group_arn_suffixes" {
  type = map(string)
}

variable "cluster_name" {
  type = string
}

variable "service_names" {
  type = map(string)
}

variable "db_instance_id" {
  type = string
}

variable "db_max_connections" {
  description = "max_connections de la instancia RDS (depende del tamaño)."
  type        = number
}

variable "error_rate_threshold_pct" {
  description = "Porcentaje de 5xx que dispara la alerta."
  type        = number
  default     = 1
}

variable "latency_p95_threshold_seconds" {
  description = "Umbral de p95 en segundos (el SLO es 300 ms)."
  type        = number
  default     = 0.3
}
