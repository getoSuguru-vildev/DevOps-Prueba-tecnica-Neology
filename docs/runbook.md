# Runbook

Pasos cortos para operar. El porqué y los detalles están en los documentos enlazados.

- [Despliegue](#despliegue)
- [Rollback](#rollback)
- [Respaldo](#respaldo)
- [Restauración](#restauración)
- [Incidente](#incidente)

## Despliegue

### Local

```bash
docker compose up --build --wait         # o con .env propio: cp .env.example .env
docker compose ps                        # database, backend y frontend en (healthy)
./scripts/smoke-test.sh                  # SMOKE TEST CORRECTO
```

### AWS, primera vez por ambiente

```bash
cd infra/environments/prod
cp backend.s3.tf.example backend.tf
cp backend.hcl.example backend.hcl       # bucket de estado real
terraform init -backend-config=backend.hcl
terraform plan -out tfplan               # revisar: nada de destroy inesperado
terraform apply tfplan
```

Luego subir las imágenes a los repositorios de ECR del output `ecr_repository_urls` (lo hace el pipeline) y desplegar como abajo.

### AWS, cada versión

1. Merge a `main` (o tag `vX.Y.Z`). El pipeline prueba, escanea y publica. Tomar los digests del resumen del job `publish`.
2. Dev:
   ```bash
   terraform -chdir=infra/environments/dev apply \
     -var backend_image_digest=sha256:<backend> -var frontend_image_digest=sha256:<frontend>
   ```
3. Revisar en dev: smoke test contra la URL (`API_URL=https://... FRONTEND_URL=https://... ./scripts/smoke-test.sh`), dashboard sin errores 10 minutos.
4. Prod: el mismo comando en `infra/environments/prod` con **los mismos digests**, con aprobación.
5. Vigilar 30 minutos: 5xx, p95, conexiones a PostgreSQL. Si algo se sale, [rollback](#rollback).

No se despliega los viernes por la tarde ni sin alguien de guardia disponible.

## Rollback

Criterio: el problema empezó después del deploy y hay alerta de burn rate, error rate arriba de 2% o p95 arriba de 300 ms por más de 5 minutos. Ante la duda, regresar.

| Caso | Comando |
| --- | --- |
| Tareas nuevas no sanas | Ninguno: el circuit breaker de ECS regresa solo. Confirmar en los eventos del servicio. |
| Aplicación, versión anterior | `terraform -chdir=infra/environments/prod apply -var backend_image_digest=<digest anterior> -var frontend_image_digest=<digest anterior>` |
| Urgente, sin Terraform | `aws ecs update-service --cluster parking-prod --service backend --task-definition parking-prod-backend:<revisión anterior>` y después alinear Terraform |
| Configuración (variables, tamaños, red) | `git revert <commit>` y `terraform apply` |
| Secreto | `aws secretsmanager update-secret-version-stage --secret-id <arn> --version-stage AWSCURRENT --move-to-version-id <versión anterior>` y `aws ecs update-service ... --force-new-deployment` |
| Local | `IMAGE_TAG=<tag anterior> docker compose up -d --no-build` |

El esquema de la base no se regresa: las migraciones son compatibles hacia atrás. Detalle en [backup-recovery.md](backup-recovery.md#rollback-de-aplicación).

## Respaldo

**Local**

```bash
./scripts/backup.sh
# RESPALDO CORRECTO: backups/parking-<fecha>.dump (y su .sha256)
```

**AWS**: automático (RDS, diario + logs cada ~5 min, 14 días en prod). Antes de un cambio riesgoso, snapshot manual:

```bash
aws rds create-db-snapshot --db-instance-identifier parking-prod-postgres \
  --db-snapshot-identifier parking-prod-manual-$(date -u +%Y%m%d%H%M)
aws rds wait db-snapshot-available --db-snapshot-identifier <identificador>
```

## Restauración

**Local**

```bash
./scripts/restore.sh backups/parking-<fecha>.dump    # pide escribir "restaurar"
./scripts/smoke-test.sh
```

Guarda antes un respaldo del estado actual en `backups/antes-de-restaurar/`.

**AWS** (instancia nueva, nunca encima de la actual):

```bash
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier parking-prod-postgres \
  --target-db-instance-identifier parking-prod-postgres-restore \
  --restore-time <AAAA-MM-DDTHH:MM:SSZ> \
  --db-subnet-group-name parking-prod-db --vpc-security-group-ids <sg de la base> \
  --db-parameter-group-name parking-prod-postgres16 --multi-az
aws rds wait db-instance-available --db-instance-identifier parking-prod-postgres-restore
```

Validar conteos desde una tarea de ECS con `psql`, cambiar la aplicación a la instancia restaurada y correr el smoke test. Pasos completos en [backup-recovery.md](backup-recovery.md#restauración-en-aws-procedimiento-comprobable).

**Simulacro** (borra la base local): `./scripts/restore-drill.sh --yes`.

## Incidente

Guía completa: [incident-response.md](incident-response.md).

1. Declarar incidente, asignar quién coordina, quién investiga y quién comunica. Congelar despliegues.
2. ¿Qué cambió? Último deploy, migraciones, variables, autoescalado.
3. Revisar en este orden: 5xx y p95 por endpoint, pool de Hikari (`pending`), conexiones y top SQL de PostgreSQL, eventos y reinicios de ECS, logs por `requestId`.
4. Si coincide con un deploy: [rollback](#rollback). Poner tope al autoescalado si las conexiones siguen subiendo.
5. No reiniciar todo junto, no restaurar la base por un problema de conexiones, snapshot manual antes de tocar la base.
6. Mensaje inicial en 10 minutos, actualizaciones cada 30.
7. Cerrar después de 30 minutos estables. Postmortem en menos de 5 días.

Comandos útiles:

```bash
# Local
docker compose ps
docker compose logs --tail=200 backend frontend database
docker compose logs backend | grep <requestId>
curl -s localhost:8080/actuator/prometheus | grep hikaricp_connections
docker compose exec database sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select state, count(*) from pg_stat_activity group by 1"'

# AWS
aws ecs describe-services --cluster parking-prod --services backend --query 'services[0].events[:10]'
aws ecs list-tasks --cluster parking-prod --service-name backend --desired-status STOPPED
aws logs tail /ecs/parking-prod/backend --since 30m --filter-pattern '"ERROR"'
```
