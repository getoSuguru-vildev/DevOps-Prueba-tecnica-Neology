locals {
  name = "parking-${var.environment}"

  # Se despliega por digest cuando el pipeline lo manda; si no, por tag (sha-<commit>).
  backend_image = var.backend_image_digest != "" ? "${module.ecr.repository_urls["backend"]}@${var.backend_image_digest}" : "${module.ecr.repository_urls["backend"]}:${var.image_tag}"

  frontend_image = var.frontend_image_digest != "" ? "${module.ecr.repository_urls["frontend"]}@${var.frontend_image_digest}" : "${module.ecr.repository_urls["frontend"]}:${var.image_tag}"
}

module "network" {
  source = "../../modules/network"

  name                     = local.name
  region                   = var.aws_region
  cidr_block               = var.vpc_cidr
  azs                      = var.azs
  single_nat_gateway       = var.single_nat_gateway
  flow_logs_retention_days = var.log_retention_days
}

module "security" {
  source = "../../modules/security"

  name   = local.name
  vpc_id = module.network.vpc_id
}

module "ecr" {
  source = "../../modules/ecr"

  name_prefix = local.name
}

module "database" {
  source = "../../modules/database"

  name                  = local.name
  subnet_ids            = module.network.db_subnet_ids
  security_group_id     = module.security.database_security_group_id
  instance_class        = var.db_instance_class
  multi_az              = var.db_multi_az
  backup_retention_days = var.db_backup_retention_days
  deletion_protection   = var.deletion_protection
  final_snapshot        = var.db_final_snapshot
}

module "ecs" {
  source = "../../modules/ecs"

  name   = local.name
  region = var.aws_region

  vpc_id                     = module.network.vpc_id
  public_subnet_ids          = module.network.public_subnet_ids
  app_subnet_ids             = module.network.app_subnet_ids
  alb_security_group_id      = module.security.alb_security_group_id
  frontend_security_group_id = module.security.frontend_security_group_id
  backend_security_group_id  = module.security.backend_security_group_id
  ecr_repository_arns        = values(module.ecr.repository_arns)

  backend_image     = local.backend_image
  frontend_image    = local.frontend_image
  backend_cpu       = var.backend_cpu
  backend_memory    = var.backend_memory
  backend_min_count = var.backend_min_count
  backend_max_count = var.backend_max_count
  frontend_cpu      = var.frontend_cpu
  frontend_memory   = var.frontend_memory
  frontend_count    = var.frontend_count
  use_fargate_spot  = var.use_fargate_spot

  db_address       = module.database.address
  db_port          = module.database.port
  db_name          = module.database.db_name
  db_secret_arn    = module.database.master_secret_arn
  db_pool_max_size = var.db_pool_max_size

  public_url          = var.public_url
  certificate_arn     = var.certificate_arn
  log_retention_days  = var.log_retention_days
  deletion_protection = var.deletion_protection
}

module "observability" {
  source = "../../modules/observability"

  name           = local.name
  region         = var.aws_region
  aws_account_id = var.aws_account_id
  alert_email    = var.alert_email

  alb_arn_suffix                  = module.ecs.alb_arn_suffix
  backend_target_group_arn_suffix = module.ecs.target_group_arn_suffixes["backend"]
  target_group_arn_suffixes       = module.ecs.target_group_arn_suffixes
  cluster_name                    = module.ecs.cluster_name
  service_names                   = module.ecs.service_names
  db_instance_id                  = module.database.instance_id
  db_max_connections              = var.db_max_connections
}
