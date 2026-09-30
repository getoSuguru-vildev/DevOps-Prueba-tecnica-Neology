# Evidencia de las validaciones

Todo se corrió el 2026-09-30 sobre el commit indicado en cada archivo, en una Mac con Apple Silicon usando Colima (Docker 29, 4 CPU, 6 GB). No hay Java ni Maven instalados en esa máquina, por eso `verify.sh` se reemplazó por `verify-docker.sh`, que corre exactamente las mismas pruebas y el mismo build dentro de contenedores.

## Resumen

| Validación | Resultado | Archivo |
| --- | --- | --- |
| Archivos sensibles versionados (grep de la guía) | ninguno | [01](01-guia-evaluacion.txt) |
| Pruebas Java | 7 ejecutadas, 0 fallas (4 originales + 3 del filtro de correlación) | [02](02-verify-docker.txt) |
| `npm ci` + build de producción de Angular | correcto | [02](02-verify-docker.txt) |
| `docker compose config` | sin errores | [01](01-guia-evaluacion.txt) |
| `docker compose build --no-cache` | correcto | [01](01-guia-evaluacion.txt) |
| `docker compose up` sin `.env` | 3 contenedores `(healthy)` | [01](01-guia-evaluacion.txt) |
| `smoke-test.sh` | `SMOKE TEST CORRECTO` | [01](01-guia-evaluacion.txt) |
| Logs de backend, frontend y base | 0 líneas WARN o ERROR | [03](03-logs-extracto.txt) |
| Simulacro de respaldo y restauración | correcto, restauración en 7 s, ciclo completo en 26 s | [04](04-restore-drill.txt) |
| hadolint, shellcheck, actionlint | sin hallazgos | [05](05-linters.txt) |
| promtool (config, 15 reglas, pruebas de alertas) | correcto | [05](05-linters.txt) |
| Terraform fmt, validate y plan sin cuenta | dev 79 recursos, prod 93 | [06](06-terraform.txt) |
| Trivy imagen backend | 0 CRITICAL, 15 HIGH (jars de Spring); SO Ubuntu 24.04 sin HIGH/CRITICAL | [07](07-trivy.txt) |
| Trivy imagen frontend | 0 HIGH/CRITICAL | [07](07-trivy.txt) |
| Trivy config sobre Terraform | 0 HIGH/CRITICAL | [07](07-trivy.txt) |
| Correlación por `X-Request-ID` | mismo id en respuesta, log de nginx y log del backend | [08](08-correlacion-y-runtime.txt) |
| Runtime | procesos sin root, filesystem de solo lectura, sin curl, métricas y consola H2 no publicadas, apagado ordenado en 0.2 s | [08](08-correlacion-y-runtime.txt) |
| Pipeline de GitHub Actions | pendiente del primer push | |

## Antes y después

| | Base (`253aaf4`) | Esta rama |
| --- | --- | --- |
| `npm ci` | falla (lock generado con npm 11) | correcto con npm 10 y 11 |
| `./scripts/*.sh` | `permission denied` (modo 644) | ejecutables |
| `cp .env.example .env` del README | el archivo no existía | existe; compose funciona con o sin él |
| CVE CRITICAL en la imagen del backend | 7 (Tomcat 10.1.31) | 0 |
| curl en imágenes de runtime | backend y nginx | ninguno |
| Tamaño que se mueve en cada deploy del backend | 53 MB (jar completo) | ~250 kB (capa de la aplicación) |
| Filesystem de los contenedores | escribible | solo lectura |
| Actuator publicado por nginx | todo `/actuator/` | solo `/actuator/health` |
| Esquema de base de datos | `ddl-auto: update` | migraciones Flyway, `validate` |
| Contraseña por defecto dentro del jar | `parking_dev_password` | ninguna |

## Cómo reproducirlo

```bash
./scripts/verify-docker.sh
docker compose config && docker compose build --no-cache && docker compose up --detach
docker compose ps && ./scripts/smoke-test.sh
./scripts/restore-drill.sh --yes
./infra/scripts/plan-offline.sh
docker compose down
```

El pipeline corre lo mismo en GitHub Actions en cada push (ver [docs/ci-cd.md](../ci-cd.md)).
