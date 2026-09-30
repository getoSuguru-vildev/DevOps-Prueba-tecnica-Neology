# Respaldo, restauración y rollback

## Objetivos

| Ambiente | RPO (cuánto dato se puede perder) | RTO (cuánto puede tardar volver) | Cómo se logra |
| --- | --- | --- | --- |
| Producción | 15 minutos (en la práctica ~5) | 1 hora | RDS con backups automáticos y point in time recovery, Multi-AZ para fallas de zona |
| Dev | 24 horas | 4 horas | Backup automático diario de RDS, 7 días |
| Local (compose) | lo que diga el último `backup.sh` | segundos | `scripts/backup.sh` y `scripts/restore.sh` |

Por qué estos números: la base guarda estancias y cobros del mes en curso. Perder más de unos minutos significa cobros que no se pueden reconstruir, así que el RPO tiene que ser chico. Una hora sin sistema es molesta pero el estacionamiento puede operar con registro manual, así que el RTO puede ser más holgado y no justifica una réplica en otra región desde el día uno.

**Medido**: el simulacro local restaura en ~8 segundos y el ciclo completo (respaldo, borrar volumen, restaurar, verificar) tarda ~28 segundos. En AWS no lo pude medir sin cuenta; la estimación del RTO está abajo.

## Local (docker compose)

```bash
./scripts/backup.sh                                   # genera backups/parking-<fecha>.dump y su .sha256
./scripts/restore.sh backups/parking-<fecha>.dump     # pide confirmación
./scripts/restore-drill.sh --yes                      # simulacro completo, borra la base local
```

**backup.sh**
- Corre `pg_dump --format=custom` dentro del contenedor con las variables del propio contenedor: la contraseña nunca aparece en el script, en el host ni en el historial.
- Escribe primero a un `.partial` y solo lo renombra si pasó las validaciones: que no esté vacío, que `pg_restore --list` lo pueda leer y que traiga los datos de `vehicles`.
- Guarda el `sha256` al lado y borra los respaldos de más de `BACKUP_RETENTION_DAYS` días (7 por defecto).
- Archivos con permisos 600 en una carpeta 700 que git ignora.

**restore.sh**
- Verifica el checksum y que el archivo se pueda leer antes de tocar nada.
- Pide escribir `restaurar` (o `--yes` en automatización).
- Saca un respaldo del estado actual en `backups/antes-de-restaurar/`: si se restauró el archivo equivocado, se puede regresar.
- Detiene el backend para que nadie escriba a la mitad, restaura con `--single-transaction` (si falla, se revierte y la base queda como estaba) y vuelve a levantar el backend aunque algo falle.

**restore-drill.sh** corre en el pipeline (job `e2e`) en cada push: si un cambio rompe los respaldos, el pipeline lo detecta antes de producción.

Para programarlo en un servidor con compose, un cron alcanza:

```cron
0 */6 * * * cd /opt/parking && ./scripts/backup.sh >> /var/log/parking-backup.log 2>&1
```

Si los respaldos salen del host, van cifrados: a S3 con SSE-KMS o con `age`/`gpg` antes de copiarlos.

## AWS (RDS PostgreSQL)

Configurado en `infra/modules/database`:

| Qué | Dev | Prod |
| --- | --- | --- |
| Backups automáticos (snapshot diario + logs de transacciones cada ~5 min) | 7 días | 14 días |
| Point in time recovery | dentro de la retención | dentro de la retención |
| Cifrado en reposo (KMS) | sí | sí |
| Multi-AZ (réplica síncrona, failover automático en 1 a 2 min) | no | sí |
| Snapshot final al destruir | no | sí |
| Deletion protection | no | sí |

Multi-AZ no es un respaldo: protege contra la caída de una zona, pero un `DELETE` sin `WHERE` se replica igual. Para eso está el point in time recovery.

**Siguientes pasos para prod** (no incluidos para no inflar costo desde el día uno):
- Replicar los backups automáticos a otra región (`aws_db_instance_automated_backups_replication`) para sobrevivir a la pérdida de una región.
- AWS Backup con un vault con Vault Lock, para que ni un administrador comprometido pueda borrar los respaldos.
- Un `pg_dump` semanal a S3 con lifecycle a Glacier: retención larga y portabilidad fuera de RDS.

### Restauración en AWS (procedimiento comprobable)

Nunca se restaura encima de la instancia actual: se crea una instancia nueva, se valida y luego se cambia el tráfico.

1. Elegir el momento: justo antes del incidente, en UTC.
2. Restaurar a una instancia nueva:

```bash
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier parking-prod-postgres \
  --target-db-instance-identifier parking-prod-postgres-restore \
  --restore-time 2026-09-30T14:05:00Z \
  --db-subnet-group-name parking-prod-db \
  --vpc-security-group-ids <database_security_group_id> \
  --db-parameter-group-name parking-prod-postgres16 \
  --multi-az
aws rds wait db-instance-available --db-instance-identifier parking-prod-postgres-restore
```

3. Validar los datos desde dentro de la VPC, con una tarea de ECS de un solo uso con `psql` (misma subnet y security group que el backend): conteo de `vehicles` y `parking_stays`, última estancia registrada y `flyway_schema_history` en la versión esperada.
4. Cambiar la aplicación a la instancia restaurada: en Terraform se importa la instancia nueva o se renombran las instancias (`aws rds modify-db-instance --new-db-instance-identifier`) para que el endpoint quede igual, y `terraform apply`. ECS reinicia las tareas con el endpoint correcto.
5. Correr el smoke test contra la URL pública y revisar el dashboard (5xx, latencia, conexiones).
6. Guardar la instancia vieja detenida unos días para análisis, luego borrarla con snapshot final.

Estimación de tiempos: restaurar una base chica como esta tarda de 15 a 30 minutos en RDS, validar 10, el cambio y redeploy 10. Queda dentro de la hora de RTO con algo de margen; el simulacro mensual es lo que confirma ese número.

### Pruebas periódicas

| Prueba | Frecuencia | Quién |
| --- | --- | --- |
| `restore-drill.sh` en el pipeline | cada push | automático |
| Restaurar el backup más reciente de prod en una instancia temporal de staging y correr el smoke test, anotando el tiempo | mensual | ingeniero de guardia |
| Game day: simular la pérdida de la base de prod en staging siguiendo este documento de principio a fin | trimestral | equipo de plataforma con el dueño de la aplicación |

Cada prueba deja registro de fecha, tiempo de restauración y problemas encontrados. Si el tiempo medido supera el RTO, se revisa el procedimiento o el objetivo.

### Responsables

| Tarea | Responsable |
| --- | --- |
| Configuración de backups y retención (Terraform) | equipo de plataforma / DevOps |
| Monitorear que los backups se completen | guardia (alarma de AWS Backup o evento de RDS) |
| Decidir restaurar producción | líder técnico con el dueño del negocio (implica perder datos posteriores al punto elegido) |
| Ejecutar la restauración | guardia de plataforma |
| Validar los datos restaurados | dueño de la aplicación |

## Rollback de aplicación

Las imágenes son inmutables y se despliegan por digest, así que regresar es volver a apuntar al digest anterior. No se reconstruye nada.

| Situación | Qué hacer | Tiempo |
| --- | --- | --- |
| Las tareas nuevas no pasan health checks | Nada: el circuit breaker de ECS regresa solo a la revisión anterior | 5 a 10 min |
| El deploy quedó sano pero hay errores o latencia | `terraform apply -var backend_image_digest=<digest anterior>` (el digest sale del resumen del pipeline o de ECR por tag `sha-<commit>`) | 5 a 10 min |
| Emergencia, sin tiempo para Terraform | `aws ecs update-service --cluster parking-prod --service backend --task-definition parking-prod-backend:<revisión anterior>`, y luego alinear Terraform | ~5 min |
| Local | `IMAGE_TAG=<tag anterior> docker compose up -d --no-build` | segundos |

Criterio: si después de un deploy la alerta de burn rate rápida se dispara o el p95 pasa de 300 ms por más de 5 minutos, primero se regresa y después se investiga.

## Rollback de configuración

- **Infraestructura y variables de entorno**: viven en Terraform (tfvars y task definitions). Rollback = `git revert` del cambio y `terraform apply`, que genera una revisión nueva de la task definition con la configuración anterior.
- **Secretos**: Secrets Manager guarda la versión anterior (`AWSPREVIOUS`). Para regresar: `aws secretsmanager update-secret-version-stage --secret-id <arn> --version-stage AWSCURRENT --move-to-version-id <id anterior>` y forzar redeploy del backend para que lo lea.
- **Esquema de base de datos**: Flyway solo va hacia adelante. Por eso las migraciones se hacen compatibles hacia atrás (primero agregar columnas o tablas, desplegar la app, y quitar lo viejo en un deploy posterior). Así, regresar la aplicación nunca obliga a regresar el esquema. Si una migración es destructiva, antes se saca un snapshot manual y el plan B es el point in time recovery.
