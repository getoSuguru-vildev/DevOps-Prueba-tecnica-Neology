variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "app_subnet_ids" {
  type = list(string)
}

variable "alb_security_group_id" {
  type = string
}

variable "frontend_security_group_id" {
  type = string
}

variable "backend_security_group_id" {
  type = string
}

variable "ecr_repository_arns" {
  description = "Repositorios de los que el rol de ejecución puede bajar imágenes."
  type        = list(string)
}

variable "backend_image" {
  description = "Imagen del backend, idealmente por digest (repo@sha256:...)."
  type        = string
}

variable "frontend_image" {
  description = "Imagen del frontend, idealmente por digest (repo@sha256:...)."
  type        = string
}

variable "backend_cpu" {
  type = number
}

variable "backend_memory" {
  type = number
}

variable "frontend_cpu" {
  type = number
}

variable "frontend_memory" {
  type = number
}

variable "backend_min_count" {
  type = number
}

variable "backend_max_count" {
  type = number
}

variable "frontend_count" {
  type = number
}

variable "db_address" {
  type = string
}

variable "db_port" {
  type = number
}

variable "db_name" {
  type = string
}

variable "db_secret_arn" {
  description = "ARN del secreto de RDS con username y password."
  type        = string
}

variable "db_pool_max_size" {
  description = "Conexiones máximas del pool Hikari por tarea del backend."
  type        = number
}

variable "public_url" {
  description = "URL pública de la aplicación, se usa para CORS."
  type        = string
}

variable "certificate_arn" {
  description = "Certificado de ACM para HTTPS. Vacío solo en dev sin dominio."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  type = number
}

variable "deletion_protection" {
  type = bool
}

variable "use_fargate_spot" {
  description = "Usar Fargate Spot como capacidad por defecto (más barato, puede interrumpirse). Solo dev."
  type        = bool
  default     = false
}
