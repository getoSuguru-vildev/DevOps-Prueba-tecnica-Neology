variable "name" {
  description = "Prefijo para nombrar recursos."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "container_port" {
  description = "Puerto en el que escuchan los contenedores (8080 en ambos)."
  type        = number
  default     = 8080
}
