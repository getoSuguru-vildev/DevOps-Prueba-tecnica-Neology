# Security groups encadenados: internet -> ALB -> frontend/backend -> PostgreSQL.
# Ninguna regla usa rangos de IP internos: todo se autoriza por security group de origen.

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "ALB publico, solo 80 y 443"
  vpc_id      = var.vpc_id
}

resource "aws_security_group" "frontend" {
  name        = "${var.name}-frontend"
  description = "Tareas del frontend, solo reciben del ALB"
  vpc_id      = var.vpc_id
}

resource "aws_security_group" "backend" {
  name        = "${var.name}-backend"
  description = "Tareas del backend, solo reciben del ALB"
  vpc_id      = var.vpc_id
}

resource "aws_security_group" "database" {
  name        = "${var.name}-database"
  description = "PostgreSQL, solo recibe del backend"
  vpc_id      = var.vpc_id
}

# --- ALB ---

# El ALB es la única entrada pública, por diseño.
#trivy:ignore:AVD-AWS-0107
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS desde internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# Solo para redirigir a HTTPS.
#trivy:ignore:AVD-AWS-0107
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP desde internet, redirige a HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_frontend" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Hacia las tareas del frontend"
  referenced_security_group_id = aws_security_group.frontend.id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_backend" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Hacia las tareas del backend"
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

# --- Frontend ---

resource "aws_vpc_security_group_ingress_rule" "frontend_from_alb" {
  security_group_id            = aws_security_group.frontend.id
  description                  = "Desde el ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

# HTTPS de salida para bajar la imagen de ECR y mandar logs a CloudWatch (vía NAT).
#trivy:ignore:AVD-AWS-0104
resource "aws_vpc_security_group_egress_rule" "frontend_https" {
  security_group_id = aws_security_group.frontend.id
  description       = "HTTPS hacia ECR y CloudWatch"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# --- Backend ---

resource "aws_vpc_security_group_ingress_rule" "backend_from_alb" {
  security_group_id            = aws_security_group.backend.id
  description                  = "Desde el ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "backend_to_db" {
  security_group_id            = aws_security_group.backend.id
  description                  = "Hacia PostgreSQL"
  referenced_security_group_id = aws_security_group.database.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# HTTPS de salida para ECR, CloudWatch y Secrets Manager (vía NAT).
#trivy:ignore:AVD-AWS-0104
resource "aws_vpc_security_group_egress_rule" "backend_https" {
  security_group_id = aws_security_group.backend.id
  description       = "HTTPS hacia ECR, CloudWatch y Secrets Manager"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# --- PostgreSQL ---
# Sin reglas de egress: la base de datos no inicia conexiones.

resource "aws_vpc_security_group_ingress_rule" "database_from_backend" {
  security_group_id            = aws_security_group.database.id
  description                  = "Desde el backend"
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
