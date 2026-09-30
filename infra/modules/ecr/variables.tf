variable "name_prefix" {
  description = "Prefijo del nombre del repositorio, por ejemplo parking-dev."
  type        = string
}

variable "repositories" {
  description = "Nombres de los repositorios a crear."
  type        = list(string)
  default     = ["backend", "frontend"]
}

variable "keep_last_images" {
  description = "Cuántas imágenes sha-* se conservan por repositorio (margen para rollback)."
  type        = number
  default     = 30
}
