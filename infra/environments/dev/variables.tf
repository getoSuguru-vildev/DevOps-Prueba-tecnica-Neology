variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "aws_account_id" {
  description = "Cuenta de AWS del ambiente (no es secreto). Va como variable para no depender de un data source."
  type        = string
}

variable "offline_plan" {
  description = "true solo para validar/planear sin cuenta de AWS (ver infra/scripts/plan-offline.sh)."
  type        = bool
  default     = false
}

# --- Red ---

variable "vpc_cidr" {
  type = string
}

variable "azs" {
  type = list(string)
}

variable "single_nat_gateway" {
  type = bool
}

# --- Imágenes ---

variable "image_tag" {
  description = "Tag a desplegar (sha-<commit>) cuando no se pasa digest."
  type        = string
}

variable "backend_image_digest" {
  description = "sha256:... de la imagen del backend. El pipeline lo pasa con -var."
  type        = string
  default     = ""
}

variable "frontend_image_digest" {
  description = "sha256:... de la imagen del frontend. El pipeline lo pasa con -var."
  type        = string
  default     = ""
}

# --- Cómputo ---

variable "backend_cpu" {
  type = number
}

variable "backend_memory" {
  type = number
}

variable "backend_min_count" {
  type = number
}

variable "backend_max_count" {
  type = number
}

variable "frontend_cpu" {
  type = number
}

variable "frontend_memory" {
  type = number
}

variable "frontend_count" {
  type = number
}

variable "use_fargate_spot" {
  type = bool
}

# --- Base de datos ---

variable "db_instance_class" {
  type = string
}

variable "db_max_connections" {
  description = "max_connections aproximado de la clase de instancia (RDS lo calcula según la memoria)."
  type        = number
}

variable "db_pool_max_size" {
  description = "Conexiones máximas del pool Hikari por tarea del backend."
  type        = number

  # Si el autoescalado llega al máximo, todas las tareas juntas no deben poder agotar PostgreSQL.
  validation {
    condition     = var.backend_max_count * var.db_pool_max_size <= floor(var.db_max_connections * 0.8)
    error_message = "backend_max_count * db_pool_max_size supera el 80% de max_connections de RDS. Bajar el pool, el máximo de tareas o subir la instancia."
  }
}

variable "db_multi_az" {
  type = bool
}

variable "db_backup_retention_days" {
  type = number
}

variable "db_final_snapshot" {
  type = bool
}

# --- Operación ---

variable "public_url" {
  type = string
}

variable "certificate_arn" {
  type    = string
  default = ""

  validation {
    condition     = var.environment != "prod" || var.certificate_arn != ""
    error_message = "prod necesita certificate_arn: no se sirve la aplicación por HTTP plano."
  }
}

variable "deletion_protection" {
  type = bool
}

variable "log_retention_days" {
  type = number
}

variable "alert_email" {
  type    = string
  default = ""
}
