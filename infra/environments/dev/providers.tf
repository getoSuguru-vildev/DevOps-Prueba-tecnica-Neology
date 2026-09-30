provider "aws" {
  region = var.aws_region

  # Evita aplicar un ambiente en la cuenta equivocada (por ejemplo dev con credenciales de prod).
  allowed_account_ids = var.offline_plan ? null : [var.aws_account_id]

  # Solo con offline_plan=true: permite "terraform plan" sin cuenta de AWS para revisar el código.
  # Usa llaves falsas y no las valida; como no hay data sources que llamen a la API, el plan sale completo.
  # En uso normal es false y el provider toma las credenciales reales (OIDC en el pipeline, SSO en local).
  access_key                  = var.offline_plan ? "offline-plan" : null
  secret_key                  = var.offline_plan ? "offline-plan" : null
  skip_credentials_validation = var.offline_plan
  skip_requesting_account_id  = var.offline_plan
  skip_metadata_api_check     = var.offline_plan

  default_tags {
    tags = {
      Project     = "parking"
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "DevOps-Prueba-tecnica-Neology"
    }
  }
}
