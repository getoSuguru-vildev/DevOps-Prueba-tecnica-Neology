output "app_url" {
  description = "URL de la aplicación (DNS del ALB mientras no haya dominio)."
  value       = var.certificate_arn != "" ? var.public_url : "http://${module.ecs.alb_dns_name}"
}

output "alb_dns_name" {
  description = "Para crear el registro DNS (CNAME o alias)."
  value       = module.ecs.alb_dns_name
}

output "ecr_repository_urls" {
  description = "A dónde empuja las imágenes el pipeline."
  value       = module.ecr.repository_urls
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "ecs_service_names" {
  value = module.ecs.service_names
}

output "ecs_task_definition_arns" {
  description = "Revisión actual; para rollback se vuelve a la anterior."
  value       = module.ecs.task_definition_arns
}

output "log_group_names" {
  value = module.ecs.log_group_names
}

output "db_endpoint" {
  value = "${module.database.address}:${module.database.port}"
}

output "db_master_secret_arn" {
  description = "Secreto con usuario y contraseña de PostgreSQL (el valor nunca sale por Terraform)."
  value       = module.database.master_secret_arn
}

output "db_instance_id" {
  description = "Para restaurar snapshots o hacer point in time recovery."
  value       = module.database.instance_id
}

output "alerts_topic_arn" {
  value = module.observability.alerts_topic_arn
}

output "dashboard_name" {
  value = module.observability.dashboard_name
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "nat_public_ips" {
  value = module.network.nat_public_ips
}
