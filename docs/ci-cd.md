# CI/CD

El pipeline está en `.github/workflows/ci.yml`. La idea es simple: nada se publica si algo falla antes, y lo que se publica es exactamente la imagen que se probó.

## Cuándo corre

| Evento | Qué hace |
| --- | --- |
| Pull request hacia `main` | Valida todo. No publica nada. |
| Push a `main` | Valida todo y publica imágenes con tag `sha-<commit>` y `main`. |
| Push a `candidato/**` | Valida todo. No publica (así se revisa esta entrega sin tocar el registro). |
| Tag `vX.Y.Z` | Valida todo y publica `X.Y.Z`, `X.Y` y `sha-<commit>`. |
| Manual (`workflow_dispatch`) | Igual que un push a la rama elegida. |

## Etapas

```text
backend ─┐
frontend ─┼─> images (backend, frontend) ─> e2e ─┐
lint ────┘                                        ├─> publish (solo main o tags)
dependencias ─────────────────────────────────────┘
```

| Job | Qué valida | Si falla |
| --- | --- | --- |
| `backend` | `mvn verify`: compila y corre las pruebas. Sube los reportes de surefire aunque falle. | No se construyen imágenes. |
| `frontend` | `npm ci` (falla si el lock no cuadra con package.json), build de producción con `strictTemplates`, `npm audit` de dependencias de runtime. | No se construyen imágenes. |
| `lint` | hadolint en los dos Dockerfiles, shellcheck en `scripts/`, actionlint en el workflow y `docker compose config`. | No se construyen imágenes. |
| `dependencias` | Trivy sobre el repo: lock de npm y secretos. Truena con CRITICAL que ya tenga parche. | No se publica. |
| `images` | Build con buildx, Trivy sobre la imagen (incluye los jars de Java y los paquetes del sistema), SBOM CycloneDX. | No se corre e2e ni se publica. |
| `e2e` | Carga las imágenes ya escaneadas, levanta el `docker-compose.yml` completo con `--wait` y corre `scripts/smoke-test.sh`. Si falla imprime `ps` y logs. | No se publica. |
| `publish` | Solo en push a `main` o tag. Etiqueta y sube la imagen probada a GHCR y la firma con cosign (keyless, OIDC). | |

Cada job tiene `timeout-minutes` para que nada se quede colgado.

### Por qué Trivy corre desde su imagen y no con la action

Uso `aquasec/trivy` fijada por digest, la misma que en local. Es una action de terceros menos en el pipeline (después de lo de `tj-actions/changed-files` en 2025 prefiero no depender de tags que se pueden mover). Las actions que sí se usan están fijadas por SHA y Dependabot las actualiza.

### Umbral del gate

El gate bloquea CRITICAL con parche disponible. Los HIGH se reportan en el log y en el SBOM pero no bloquean, porque hoy el frontend tiene 15 HIGH de Angular 18 que solo se arreglan subiendo a Angular 19 o más (ver `docs/security.md`). Para producción real el siguiente paso es bloquear también HIGH y manejar las excepciones en `.trivyignore` con fecha de vencimiento.

## Versionado de imágenes

- Siempre: `sha-<7 caracteres del commit>`. Es el identificador que se usa para desplegar y rastrear.
- En tags de git `vX.Y.Z`: `X.Y.Z` y `X.Y` (semver).
- En `main`: `main`, solo como referencia de la última versión integrada. Nunca se despliega por `main` o `latest`.
- Las imágenes llevan labels OCI con versión y commit (`org.opencontainers.image.revision`).
- En AWS el repositorio de ECR es `IMMUTABLE`: un tag no se puede sobrescribir.

Para desplegar se usa el **digest** (`imagen@sha256:...`), no el tag. Así dev y prod corren exactamente los mismos bytes.

## Publicación

No hace falta un registro real para revisar la prueba: en ramas `candidato/**` el job `publish` se salta. Si se corre en `main` de un fork, publica en `ghcr.io/<dueño>/parking-backend` y `parking-frontend` usando el `GITHUB_TOKEN` del propio workflow, sin secretos adicionales. Ese es el único job con `packages: write` e `id-token: write`; el resto solo tiene `contents: read`.

La firma se puede verificar así:

```bash
cosign verify ghcr.io/<dueño>/parking-backend@sha256:<digest> \
  --certificate-identity-regexp 'https://github.com/<dueño>/DevOps-Prueba-tecnica-Neology/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Promoción a AWS (propuesta)

Esto no está implementado porque no hay cuenta de AWS, pero el flujo que seguiría es:

1. `publish` sube a ECR (o GHCR) con tag `sha-<commit>`.
2. Job `deploy-dev`: se autentica en AWS con OIDC (`aws-actions/configure-aws-credentials` con un rol que solo puede registrar task definitions y actualizar los servicios de dev, sin llaves de larga duración), registra una nueva revisión de la task definition con el digest y hace `aws ecs update-service`. El circuit breaker de ECS regresa solo a la revisión anterior si los health checks fallan.
3. Job `deploy-prod`: mismo digest, detrás de un `environment: prod` con aprobación manual.

El rollback es volver a desplegar la revisión anterior de la task definition (ver `docs/runbook.md`).

## Caché

| Qué | Cómo | Por qué no rompe la reproducibilidad |
| --- | --- | --- |
| Dependencias Maven | `setup-java` con `cache: maven`, llave = hash de `pom.xml` | Las versiones salen del pom; la caché solo evita descargarlas. |
| Dependencias npm | `setup-node` con `cache: npm`, llave = hash de `package-lock.json` | `npm ci` instala exactamente el lock y verifica integridad. |
| Capas Docker | `cache-from/to: type=gha` separada por servicio | Las bases van fijadas por digest y las capas de dependencias dependen del lock/pom. |

GitHub aísla la caché por rama: un PR puede leer la caché de `main` pero no escribir en ella, así que un PR no puede envenenar lo que usa `main`. Además el workflow usa `pull_request` y no `pull_request_target`, así que el código de un fork nunca corre con secretos.

## Cómo correrlo

- Automático al hacer push a la rama de la entrega o al abrir un PR.
- Manual: pestaña Actions, workflow `ci`, "Run workflow".
- Las mismas validaciones en local:

```bash
./scripts/verify-docker.sh          # pruebas + build, sin instalar Java ni Node
docker compose up --build --wait    # stack completo
./scripts/smoke-test.sh
```

## Protección recomendada del repositorio

- `main` protegida: PR obligatorio y checks `backend`, `frontend`, `lint`, `dependencias`, `images` y `e2e` requeridos.
- Environment `prod` con revisores obligatorios.
- Permisos por defecto del `GITHUB_TOKEN` en solo lectura a nivel repositorio.
