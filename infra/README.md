# Infraestructura (Terraform, AWS)

Propuesta para correr la aplicación en AWS con ECS Fargate, ALB y RDS PostgreSQL. No está aplicada en ninguna cuenta; el código valida y hace `plan` sin credenciales.

```text
infra/
├── modules/
│   ├── network/        VPC, subnets public/app/db, NAT, endpoint S3, flow logs
│   ├── security/       security groups ALB -> app -> db
│   ├── ecr/            repositorios inmutables con escaneo
│   ├── database/       RDS PostgreSQL 16, password en Secrets Manager
│   ├── ecs/            ALB, cluster, task definitions, servicios, autoescalado
│   └── observability/  SNS, alarmas y dashboard de CloudWatch
├── environments/
│   ├── dev/            1 NAT, sin Multi-AZ, Fargate Spot
│   └── prod/           NAT por AZ, Multi-AZ, HTTPS obligatorio, deletion protection
└── scripts/plan-offline.sh
```

## Validar sin cuenta de AWS

Directorio para la evaluación: `infra/environments/dev` (o `prod`).

```bash
cd infra/environments/dev
terraform fmt -check -recursive ../..
terraform init -backend=false
terraform validate
terraform plan -var offline_plan=true
```

`offline_plan=true` hace que el provider use llaves falsas sin validarlas. Funciona porque no hay data sources que consulten la API (las AZ y el account id van como variables). Sin esa variable, `plan` necesita credenciales reales de AWS como cualquier proyecto.

Todo junto, para los dos ambientes y con Terraform en Docker si no está instalado:

```bash
./infra/scripts/plan-offline.sh
```

## Desplegar de verdad

1. Bucket de estado (una vez, en la cuenta de administración): versionado, cifrado y sin acceso público.
2. Activar el backend remoto:

```bash
cd infra/environments/dev
cp backend.s3.tf.example backend.tf
cp backend.hcl.example backend.hcl        # ajustar bucket
terraform init -backend-config=backend.hcl
```

3. Aplicar con la imagen que publicó el pipeline, por digest:

```bash
terraform apply \
  -var backend_image_digest=sha256:... \
  -var frontend_image_digest=sha256:...
```

La primera vez hay que subir una imagen a ECR antes de que los servicios queden sanos (el pipeline lo hace).

## Decisiones

- **Estado remoto**: S3 con `use_lockfile` (lock nativo, sin DynamoDB), una llave por ambiente. Idealmente cada ambiente en su propia cuenta; `allowed_account_ids` evita aplicar dev en la cuenta de prod.
- **Secretos**: la contraseña de PostgreSQL la genera y rota RDS en Secrets Manager (`manage_master_user_password`). ECS la inyecta como variable de entorno al arrancar la tarea; nunca pasa por Terraform ni por el estado.
- **Variables por ambiente**: `terraform.tfvars` de cada carpeta, sin secretos.
- **Despliegue**: por digest. El circuit breaker de ECS regresa solo a la revisión anterior si las tareas nuevas no pasan health checks.
- **Conexiones**: una validación de variables falla el plan si `backend_max_count * db_pool_max_size` supera el 80% de `max_connections`, para que el autoescalado no pueda agotar PostgreSQL.

Más detalle en `docs/architecture.md`.
