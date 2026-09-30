output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_arn_suffix" {
  value = aws_lb.this.arn_suffix
}

output "target_group_arn_suffixes" {
  value = { for k, tg in aws_lb_target_group.this : k => tg.arn_suffix }
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_names" {
  value = { for k, s in aws_ecs_service.this : k => s.name }
}

output "task_definition_arns" {
  value = { for k, t in aws_ecs_task_definition.this : k => t.arn }
}

output "log_group_names" {
  value = { for k, g in aws_cloudwatch_log_group.this : k => g.name }
}
