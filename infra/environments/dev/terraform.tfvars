# Valores de dev. No hay secretos aquí: la contraseña de la base la maneja RDS en Secrets Manager.
environment = "dev"
aws_region  = "us-east-1"

# Cuenta de ejemplo; cada ambiente va en su propia cuenta dentro de AWS Organizations.
aws_account_id = "111122223333"

vpc_cidr           = "10.20.0.0/16"
azs                = ["us-east-1a", "us-east-1b"]
single_nat_gateway = true

# El pipeline sobrescribe con -var image_tag=sha-<commit> o con los digests.
image_tag = "sha-0000000"

backend_cpu       = 512
backend_memory    = 1024
backend_min_count = 1
backend_max_count = 2
frontend_cpu      = 256
frontend_memory   = 512
frontend_count    = 1
use_fargate_spot  = true

db_instance_class        = "db.t4g.micro"
db_max_connections       = 80
db_pool_max_size         = 10
db_multi_az              = false
db_backup_retention_days = 7
db_final_snapshot        = false

public_url          = "http://localhost"
certificate_arn     = ""
deletion_protection = false
log_retention_days  = 14
