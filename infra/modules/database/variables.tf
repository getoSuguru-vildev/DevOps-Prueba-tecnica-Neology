variable "name" {
  type = string
}

variable "subnet_ids" {
  description = "Subnets de la capa db (sin ruta a internet)."
  type        = list(string)
}

variable "security_group_id" {
  type = string
}

variable "engine_version" {
  description = "Versión mayor de PostgreSQL. RDS aplica las menores solo."
  type        = string
  default     = "16"
}

variable "instance_class" {
  type = string
}

variable "allocated_storage_gb" {
  type    = number
  default = 20
}

variable "max_allocated_storage_gb" {
  description = "Tope del autoescalado de almacenamiento."
  type        = number
  default     = 100
}

variable "db_name" {
  type    = string
  default = "parking"
}

variable "master_username" {
  type    = string
  default = "parking_admin"
}

variable "multi_az" {
  description = "Réplica síncrona en otra AZ con failover automático."
  type        = bool
}

variable "backup_retention_days" {
  type = number
}

variable "deletion_protection" {
  type = bool
}

variable "final_snapshot" {
  description = "Tomar snapshot final al destruir la instancia."
  type        = bool
}
