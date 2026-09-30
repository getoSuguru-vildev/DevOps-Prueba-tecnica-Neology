# Alertas mínimas y un dashboard. Todas las alarmas notifican a un tópico SNS
# (correo, o de ahí a Slack/PagerDuty).

# Llave propia para el tópico: con la llave administrada alias/aws/sns CloudWatch no puede publicar
# (su key policy no se puede editar) y las alarmas se perderían sin avisar.
data "aws_iam_policy_document" "alerts_key" {
  statement {
    sid       = "AdminCuenta"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.aws_account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchPublicaAlarmas"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }
  }
}

resource "aws_kms_key" "alerts" {
  description             = "Cifrado del topico de alertas ${var.name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.alerts_key.json
}

resource "aws_sns_topic" "alerts" {
  name              = "${var.name}-alerts"
  kms_master_key_id = aws_kms_key.alerts.arn
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  alarm_actions = [aws_sns_topic.alerts.arn]
}

# SLI de disponibilidad: % de respuestas 5xx del backend sobre el total.
resource "aws_cloudwatch_metric_alarm" "api_5xx_rate" {
  alarm_name          = "${var.name}-api-5xx-rate"
  alarm_description   = "Mas de ${var.error_rate_threshold_pct}% de respuestas 5xx en el backend durante 5 minutos. Consume presupuesto de error del SLO."
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.error_rate_threshold_pct
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  metric_query {
    id          = "rate"
    expression  = "IF(requests > 0, 100 * errors / requests, 0)"
    label       = "Porcentaje 5xx"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = var.alb_arn_suffix
        TargetGroup  = var.backend_target_group_arn_suffix
      }
    }
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = var.alb_arn_suffix
        TargetGroup  = var.backend_target_group_arn_suffix
      }
    }
  }
}

# SLI de latencia: p95 del backend visto desde el ALB.
resource "aws_cloudwatch_metric_alarm" "api_latency_p95" {
  alarm_name          = "${var.name}-api-latency-p95"
  alarm_description   = "p95 de latencia del backend arriba de ${var.latency_p95_threshold_seconds}s durante 5 minutos."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = var.latency_p95_threshold_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.backend_target_group_arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  for_each = var.target_group_arn_suffixes

  alarm_name          = "${var.name}-${each.key}-unhealthy-targets"
  alarm_description   = "Hay tareas de ${each.key} fallando el health check del ALB."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = each.value
  }
}

# Conexiones a PostgreSQL cerca del límite: el síntoma del incidente de la prueba.
resource "aws_cloudwatch_metric_alarm" "db_connections" {
  alarm_name          = "${var.name}-db-connections"
  alarm_description   = "Conexiones a PostgreSQL arriba del 80% de max_connections (${var.db_max_connections})."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = floor(var.db_max_connections * 0.8)
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.db_instance_id
  }
}

resource "aws_cloudwatch_metric_alarm" "db_cpu" {
  alarm_name          = "${var.name}-db-cpu"
  alarm_description   = "CPU de PostgreSQL arriba de 80% por 10 minutos."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.db_instance_id
  }
}

resource "aws_cloudwatch_metric_alarm" "db_free_storage" {
  alarm_name          = "${var.name}-db-free-storage"
  alarm_description   = "Queda menos de 2 GB libres en PostgreSQL."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2 * 1024 * 1024 * 1024
  comparison_operator = "LessThanThreshold"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.db_instance_id
  }
}

resource "aws_cloudwatch_metric_alarm" "service_memory" {
  for_each = var.service_names

  alarm_name          = "${var.name}-${each.key}-memory"
  alarm_description   = "Memoria de ${each.key} arriba de 85%. Riesgo de OOM y reinicios."
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = each.value
  }
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.name

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "Peticiones y errores del backend"
          region = var.region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.backend_target_group_arn_suffix],
            [".", "HTTPCode_Target_5XX_Count", ".", ".", ".", "."],
            [".", "HTTPCode_Target_4XX_Count", ".", ".", ".", "."]
          ]
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "Latencia del backend (p50, p95, p99)"
          region = var.region
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.backend_target_group_arn_suffix, { stat = "p50" }],
            ["...", { stat = "p95" }],
            ["...", { stat = "p99" }]
          ]
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "PostgreSQL: conexiones y CPU"
          region = var.region
          period = 60
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.db_instance_id, { stat = "Maximum" }],
            [".", "CPUUtilization", ".", ".", { stat = "Average", yAxis = "right" }]
          ]
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "ECS: CPU y memoria por servicio"
          region = var.region
          period = 60
          stat   = "Average"
          metrics = flatten([
            for k, s in var.service_names : [
              ["AWS/ECS", "CPUUtilization", "ClusterName", var.cluster_name, "ServiceName", s],
              [".", "MemoryUtilization", ".", ".", ".", "."]
            ]
          ])
        }
      }
    ]
  })
}
