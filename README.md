# Estacionamiento Neology: prueba técnica DevOps

Aplicación de estacionamiento (Spring Boot + Angular + PostgreSQL) preparada para construirse, probarse, desplegarse y operarse de forma segura y reproducible. La funcionalidad es la de la aplicación base; lo que cambia es todo lo de alrededor.

**Entrega**: rama `candidato/karen-villasenor`.

## Qué se hizo

| Actividad | Dónde | Resumen |
| --- | --- | --- |
| 1. Contenedores y ejecución local | `backend/Dockerfile`, `frontend/Dockerfile`, `frontend/nginx.conf`, `docker-compose.yml` | Multi-stage con bases fijadas por digest, sin root, sin curl, filesystem de solo lectura, redes separadas, health checks sin dependencias extra, apagado ordenado con SIGTERM. SO de las imágenes sin HIGH/CRITICAL y cada deploy del backend mueve ~250 kB (capas de Spring Boot) en lugar de 53 MB. Se arreglaron dos fallas de la base: `npm ci` no funcionaba (lock generado con npm 11) y los scripts no tenían permiso de ejecución. |
| 2. CI/CD | `.github/workflows/ci.yml`, `docs/ci-cd.md` | Pruebas, build, lint, Trivy (dependencias, imágenes, Terraform), SBOM, compose completo con smoke test y simulacro de restauración, publicación solo desde `main` o tags, con firma. |
| 3. Infraestructura como código | `infra/` | Terraform para AWS: VPC en 3 capas, ALB, ECS Fargate, RDS PostgreSQL, ECR, Secrets Manager, CloudWatch. Ambientes dev y prod. Valida y hace plan sin cuenta de AWS. |
| 4. Seguridad | `docs/security.md` | Sin secretos en repo ni imágenes, inyección desde Secrets Manager, privilegio mínimo, 10 riesgos encontrados con su tratamiento. Tomcat parchado: de 7 CVE CRITICAL a 0. |
| 5. Observabilidad | `docs/observability.md`, `observability/` | Logs JSON con `requestId` de punta a punta, métricas Prometheus, SLI/SLO con alertas de burn rate (con pruebas), Grafana y alarmas de CloudWatch. |
| 6. Recuperación | `scripts/backup.sh`, `scripts/restore.sh`, `scripts/restore-drill.sh`, `docs/backup-recovery.md` | Respaldo validado con checksum, restauración transaccional, simulacro medido (~8 s de restauración), RPO/RTO, rollback de app y configuración. Migraciones con Flyway. |
| 7. Incidente | `docs/incident-response.md` | Señales, hipótesis, contención, criterios de rollback, comunicación y prevención. |

Documentación: [arquitectura y decisiones](docs/architecture.md) · [runbook](docs/runbook.md) · [CI/CD](docs/ci-cd.md) · [seguridad](docs/security.md) · [observabilidad](docs/observability.md) · [respaldo y recuperación](docs/backup-recovery.md) · [incidente](docs/incident-response.md) · [infraestructura](infra/README.md) · [evidencia](docs/evidencia/README.md)

## Levantar todo con Docker Compose

Requisitos: Docker con Compose v2 y los puertos 4200 y 8080 libres.

```bash
docker compose up --build
```

Funciona sin `.env`, con valores que solo sirven para local. Para cambiarlos:

```bash
cp .env.example .env      # PowerShell: Copy-Item .env.example .env
```

| Qué | URL |
| --- | --- |
| Frontend | <http://localhost:4200> |
| Salud del backend | <http://localhost:8080/actuator/health> |
| API | <http://localhost:8080/neo/vehiculos> |
| Métricas (solo desde el host) | <http://localhost:8080/actuator/prometheus> |

```bash
docker compose ps                                  # los tres en (healthy)
docker compose logs --tail=100 backend frontend
docker compose down                                # detener, conserva datos
docker compose down --volumes                      # detener y borrar la base
```

Con Prometheus y Grafana (dashboard y alertas ya cargados):

```bash
docker compose --profile observability up --build
# Prometheus http://localhost:9090   Grafana http://localhost:3000 (admin / change_me_local_only)
```

## Levantar localmente con H2 (sin Docker)

Requisitos: Java 17, Maven 3.9, Node.js 22 LTS con npm 10 o superior.

```bash
# Terminal 1: backend con H2 en memoria (el perfil local activa la consola H2)
cd backend
mvn spring-boot:run

# Terminal 2: frontend
cd frontend
npm ci
npm start
```

Abrir <http://localhost:4200>. La consola H2 queda en <http://localhost:8080/h2-console> (JDBC URL `jdbc:h2:mem:parking`, usuario `sa`, sin contraseña). Solo existe con `mvn spring-boot:run`; el jar y las imágenes no la incluyen.

## Validaciones

| Comando | Qué valida | Necesita |
| --- | --- | --- |
| `./scripts/verify-docker.sh` | Pruebas del backend y build de producción del frontend | Docker |
| `./scripts/verify.sh` | Lo mismo, con herramientas locales | Java 17, Maven, Node |
| `./scripts/verify-local-stack.sh` | Backend con H2 + frontend + smoke test | Java 17, Maven, Node |
| `./scripts/smoke-test.sh` | Salud, alta, entrada, salida, reporte y frontend contra un stack arriba | curl |
| `./scripts/restore-drill.sh --yes` | Respaldo, borrado de la base, restauración y verificación (borra la base local) | Docker |
| `./infra/scripts/plan-offline.sh` | `terraform fmt`, `validate` y `plan` de dev y prod sin cuenta de AWS | Docker o Terraform |

Secuencia de la guía de evaluación, tal cual:

```bash
./scripts/verify.sh            # o ./scripts/verify-docker.sh si no hay Java/Maven
docker compose config
docker compose build --no-cache
docker compose up --detach
docker compose ps
./scripts/smoke-test.sh
docker compose logs --tail=150 backend frontend database
docker compose down
```

Terraform, en `infra/environments/dev` (o `prod`):

```bash
terraform fmt -check -recursive ../..
terraform init -backend=false
terraform validate
terraform plan -var offline_plan=true
```

`offline_plan=true` permite el plan sin credenciales de AWS. Con credenciales reales se omite.

## Respaldo y restauración

```bash
./scripts/backup.sh                                  # backups/parking-<fecha>.dump + .sha256
./scripts/restore.sh backups/parking-<fecha>.dump    # confirma, respalda lo actual y restaura
```

Detalle, RPO/RTO y procedimiento en AWS: [docs/backup-recovery.md](docs/backup-recovery.md).

## Pipeline

Corre en cada push a `main` y `candidato/**`, en pull requests a `main` y en tags `vX.Y.Z`. En la rama de entrega valida todo y no publica. Detalle en [docs/ci-cd.md](docs/ci-cd.md).

## Estructura

```text
.
├── .github/                 pipeline y dependabot
├── backend/                 API Spring Boot 3 + Java 17 (Dockerfile, migraciones Flyway)
├── frontend/                SPA Angular 18 + nginx (Dockerfile, nginx.conf)
├── infra/                   Terraform AWS: modules/ y environments/dev|prod
├── observability/           Prometheus (reglas y pruebas) y Grafana
├── scripts/                 verificación, smoke test, respaldo, restauración y simulacro
├── docs/                    arquitectura, runbook, seguridad, observabilidad, recuperación, incidente, evidencia
├── .env.example
└── docker-compose.yml
```

## Limitaciones conocidas

- La infraestructura no se aplicó en una cuenta real de AWS; está validada con `validate`, `plan` y Trivy.
- El despliegue a AWS desde el pipeline está documentado pero no implementado.
- Angular 18 y Spring Boot 3.3 están fuera de soporte: 0 CRITICAL, pero quedan HIGH que se arreglan actualizando el framework (plan en `docs/security.md`).
- La API no tiene autenticación; la propuesta está en `docs/security.md`.
- No hay pruebas de frontend en el proyecto base.

Más detalle en [docs/architecture.md](docs/architecture.md#limitaciones-conocidas).

## Aplicación base

### Funcionalidad

- Alta de vehículos oficiales, residentes y no residentes.
- Registro de entrada y salida; no permite dos entradas abiertas para la misma placa.
- Residentes: `$0.05` por minuto acumulado en el mes. No residentes: `$0.50` por minuto al salir. Oficiales: sin cobro.
- Cada minuto iniciado se cobra completo; los importes usan `BigDecimal`.
- Listado y filtro de vehículos, detalle con estancias, reporte mensual de residentes.
- Inicio de un nuevo mes, siempre que no haya estancias abiertas.

### API

| Método | Ruta | Objetivo |
| --- | --- | --- |
| `GET` | `/neo/vehiculos` | Listar vehículos |
| `GET` | `/neo/vehiculos/{placa}` | Consultar vehículo y estancias |
| `POST` | `/neo/vehiculos/oficiales` | Alta de vehículo oficial |
| `POST` | `/neo/vehiculos/residentes` | Alta de vehículo residente |
| `POST` | `/neo/vehiculos/no-residentes` | Alta de vehículo no residente |
| `POST` | `/neo/estancias/entrada` | Registrar entrada |
| `POST` | `/neo/estancias/salida` | Registrar salida y calcular cobro |
| `GET` | `/neo/residentes/pagos` | Generar reporte de residentes |
| `POST` | `/neo/mes/iniciar` | Reiniciar el mes |
| `GET` | `/actuator/health` | Verificar salud del backend |

```bash
curl -i -X POST http://localhost:8080/neo/vehiculos/residentes \
  -H 'Content-Type: application/json' -d '{"placa":"ABC-123"}'
curl -i -X POST http://localhost:8080/neo/estancias/entrada \
  -H 'Content-Type: application/json' -d '{"placa":"ABC-123"}'
```

Cada respuesta trae el header `X-Request-ID`; con ese valor se encuentra la petición en los logs de nginx y del backend.

### Validación manual

1. Abrir el frontend y registrar una placa como `RESIDENTE`.
2. **Registrar entrada**: el estado cambia a **Dentro**.
3. **Registrar salida**, abrir **Reporte de residentes** y revisar tiempo e importe.
4. Abrir el detalle del vehículo y revisar la estancia cerrada.
5. Iniciar un nuevo mes y confirmar que el acumulado queda en cero.
