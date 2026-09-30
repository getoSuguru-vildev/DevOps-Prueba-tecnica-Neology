# ALB público + ECS Fargate en subnets privadas.
# El ALB enruta /neo/* y /actuator/health al backend; todo lo demás va al frontend (SPA en nginx).

locals {
  https_enabled = var.certificate_arn != ""

  services = {
    backend = {
      image         = var.backend_image
      cpu           = var.backend_cpu
      memory        = var.backend_memory
      desired_count = var.backend_min_count
      user          = "10001:10001"
      health_path   = "/actuator/health/readiness"
      sg_id         = var.backend_security_group_id
      tmp_mounts    = ["/tmp"]
      environment = {
        SPRING_PROFILES_ACTIVE = "postgres"
        DB_URL                 = "jdbc:postgresql://${var.db_address}:${var.db_port}/${var.db_name}?sslmode=require"
        DB_POOL_MAX_SIZE       = tostring(var.db_pool_max_size)
        FRONTEND_URL           = var.public_url
        LOG_FORMAT             = "json"
      }
      # Llaves del JSON del secreto que administra RDS.
      secrets = {
        DB_USERNAME = "${var.db_secret_arn}:username::"
        DB_PASSWORD = "${var.db_secret_arn}:password::"
      }
      container_health = "wget -q -O /dev/null http://127.0.0.1:8080/actuator/health/liveness || exit 1"
    }
    frontend = {
      image         = var.frontend_image
      cpu           = var.frontend_cpu
      memory        = var.frontend_memory
      desired_count = var.frontend_count
      user          = "101:101"
      health_path   = "/healthz"
      sg_id         = var.frontend_security_group_id
      tmp_mounts    = ["/tmp", "/var/cache/nginx", "/etc/nginx/conf.d"]
      environment = {
        # En AWS el ALB manda /neo/* directo al backend, así que el proxy de nginx no se usa.
        # nginx resuelve el upstream en cada petición, por eso no falla al arrancar.
        BACKEND_UPSTREAM = "localhost:8080"
      }
      secrets          = {}
      container_health = "wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1"
    }
  }
}

# --- Logs ---

resource "aws_cloudwatch_log_group" "this" {
  for_each          = local.services
  name              = "/ecs/${var.name}/${each.key}"
  retention_in_days = var.log_retention_days
}

# --- IAM ---

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Rol de ejecución: lo usa el agente de ECS para bajar la imagen, escribir logs y leer el secreto.
resource "aws_iam_role" "execution" {
  name               = "${var.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "execution" {
  # GetAuthorizationToken no admite restricción por recurso.
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid       = "EcrPull"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = var.ecr_repository_arns
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [for g in aws_cloudwatch_log_group.this : "${g.arn}:*"]
  }

  # Solo el secreto de la base de datos, nada más.
  statement {
    sid       = "DbSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn]
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "pull-logs-secret"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

# Rol de la tarea: la aplicación no llama a ninguna API de AWS, así que no tiene permisos.
resource "aws_iam_role" "task" {
  name               = "${var.name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# --- Cluster ---

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }
}

# --- Task definitions ---

resource "aws_ecs_task_definition" "this" {
  for_each = local.services

  family                   = "${var.name}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  # Volúmenes efímeros para las rutas que necesitan escritura; el resto del filesystem es de solo lectura.
  dynamic "volume" {
    for_each = each.value.tmp_mounts
    content {
      name = "rw-${replace(trim(volume.value, "/"), "/", "-")}"
    }
  }

  container_definitions = jsonencode([
    {
      name                   = each.key
      image                  = each.value.image
      essential              = true
      user                   = each.value.user
      readonlyRootFilesystem = true
      stopTimeout            = 30
      portMappings           = [{ containerPort = 8080, protocol = "tcp" }]
      environment            = [for k, v in each.value.environment : { name = k, value = v }]
      secrets                = [for k, v in each.value.secrets : { name = k, valueFrom = v }]
      mountPoints = [for p in each.value.tmp_mounts : {
        sourceVolume  = "rw-${replace(trim(p, "/"), "/", "-")}"
        containerPath = p
        readOnly      = false
      }]
      healthCheck = {
        command     = ["CMD-SHELL", each.value.container_health]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this[each.key].name
          awslogs-region        = var.region
          awslogs-stream-prefix = each.key
        }
      }
    }
  ])
}

# --- ALB ---

#trivy:ignore:AVD-AWS-0053
resource "aws_lb" "this" {
  name                       = var.name
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = var.public_subnet_ids
  security_groups            = [var.alb_security_group_id]
  drop_invalid_header_fields = true
  enable_deletion_protection = var.deletion_protection
  idle_timeout               = 60
}

resource "aws_lb_target_group" "this" {
  for_each = local.services

  name                 = "${var.name}-${each.key}"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = each.value.health_path
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# Con certificado: 80 redirige a 443. Sin certificado (solo dev) el 80 sirve directo.
#trivy:ignore:AVD-AWS-0054
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = local.https_enabled ? "redirect" : "forward"
    target_group_arn = local.https_enabled ? null : aws_lb_target_group.this["frontend"].arn

    dynamic "redirect" {
      for_each = local.https_enabled ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this["frontend"].arn
  }
}

resource "aws_lb_listener_rule" "backend" {
  listener_arn = local.https_enabled ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this["backend"].arn
  }

  condition {
    path_pattern {
      values = ["/neo/*", "/actuator/health"]
    }
  }
}

# --- Servicios ---

resource "aws_ecs_service" "this" {
  for_each = local.services

  name            = each.key
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this[each.key].arn
  desired_count   = each.value.desired_count

  capacity_provider_strategy {
    capacity_provider = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [each.value.sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this[each.key].arn
    container_name   = each.key
    container_port   = 8080
  }

  # Rolling update sin bajar capacidad. Si las tareas nuevas no pasan health checks,
  # ECS regresa solo a la revisión anterior.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 60

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  enable_execute_command = false
  propagate_tags         = "SERVICE"

  # desired_count lo maneja el autoescalado.
  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_lb_listener.http, aws_lb_listener.https, aws_ecs_cluster_capacity_providers.this]
}

# --- Autoescalado del backend ---

resource "aws_appautoscaling_target" "backend" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this["backend"].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.backend_min_count
  max_capacity       = var.backend_max_count
}

resource "aws_appautoscaling_policy" "backend_cpu" {
  name               = "${var.name}-backend-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.backend.service_namespace
  resource_id        = aws_appautoscaling_target.backend.resource_id
  scalable_dimension = aws_appautoscaling_target.backend.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
