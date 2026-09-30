variable "name" {
  description = "Prefijo para nombrar recursos (proyecto-ambiente)."
  type        = string
}

variable "region" {
  description = "Región de AWS, se usa para los endpoints de VPC."
  type        = string
}

variable "cidr_block" {
  description = "CIDR de la VPC. Cada capa usa /24 dentro de este rango."
  type        = string
}

variable "azs" {
  description = "Zonas de disponibilidad. Van como variable para no depender de un data source (permite plan sin cuenta)."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2
    error_message = "Se necesitan al menos 2 AZ (RDS y el ALB lo requieren)."
  }
}

variable "single_nat_gateway" {
  description = "true = un solo NAT (más barato, dev). false = un NAT por AZ (prod)."
  type        = bool
}

variable "flow_logs_retention_days" {
  description = "Días que se guardan los flow logs."
  type        = number
}
