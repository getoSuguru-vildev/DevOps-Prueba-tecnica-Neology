# Valores de prod. No hay secretos aquí: la contraseña de la base la maneja RDS en Secrets Manager.
environment = "prod"
aws_region  = "us-east-1"

# Cuenta de ejemplo; cada ambiente va en su propia cuenta dentro de AWS Organizations.
aws_account_id = "444455556666"

vpc_cidr           = "10.30.0.0/16"
azs                = ["us-east-1a", "us-east-1b", "us-east-1c"]
single_nat_gateway = false

# El pipeline despliega por digest (-var backend_image_digest=sha256:...), el mismo que ya pasó por dev.
image_tag = "sha-0000000"

backend_cpu       = 1024
backend_memory    = 2048
backend_min_count = 2
backend_max_count = 10
frontend_cpu      = 256
frontend_memory   = 512
frontend_count    = 2
use_fargate_spot  = false

db_instance_class        = "db.m7g.large"
db_max_connections       = 800
db_pool_max_size         = 15
db_multi_az              = true
db_backup_retention_days = 14
db_final_snapshot        = true

# Certificado de ACM del dominio real. Este ARN es un ejemplo con formato válido para poder hacer plan.
public_url          = "https://parking.example.com"
certificate_arn     = "arn:aws:acm:us-east-1:444455556666:certificate/00000000-0000-0000-0000-000000000000"
deletion_protection = true
log_retention_days  = 30
alert_email         = "oncall@example.com"
