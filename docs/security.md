# Seguridad

Resumen de cómo se manejan secretos, permisos y escaneos, y los riesgos que encontré en la aplicación base con lo que se hizo con cada uno.

## Secretos

**Regla**: ningún secreto vive en el repositorio, en una imagen ni en el estado de Terraform.

| Dónde | Cómo se maneja |
| --- | --- |
| Repositorio | `.gitignore` excluye `.env`, llaves y estado de Terraform. El pipeline corre el escáner de secretos de Trivy en cada push. |
| Imágenes | Los `.dockerignore` son lista blanca (solo `pom.xml`/`src` y los archivos de Angular). La configuración entra por variables de entorno al arrancar, nunca se hornea en la imagen. |
| Local (compose) | Variables en `.env` (ignorado). Sin `.env` se usan valores por defecto que **solo sirven en local** (`change_me_local_only`), para que `docker compose up` funcione tal cual lo corre la guía de evaluación. La base de datos no publica puertos, así que ese valor no es alcanzable desde fuera del host. |
| AWS | La contraseña de PostgreSQL la genera RDS y la guarda en Secrets Manager (`manage_master_user_password`). ECS la inyecta en la tarea con `secrets.valueFrom` al arrancar. Terraform solo conoce el ARN del secreto, nunca el valor. |
| GitHub Actions | Solo el `GITHUB_TOKEN` efímero del workflow. Para desplegar a AWS se usa OIDC (rol asumido por el workflow), no llaves guardadas en secrets. |

### Rotación sin reconstruir nada

La contraseña cambia en Secrets Manager, no en la imagen, así que rotar no requiere build ni cambio de código:

1. RDS rota el secreto (automático cada 7 días, o a mano con `aws secretsmanager rotate-secret --secret-id <arn>`).
2. Las tareas que ya estaban corriendo tienen la contraseña vieja en su entorno. Las conexiones abiertas siguen funcionando, pero las nuevas fallarían.
3. Por eso, al terminar la rotación se fuerza un redeploy: `aws ecs update-service --cluster parking-prod --service backend --force-new-deployment`. Las tareas nuevas leen la contraseña nueva y el rolling update no corta servicio.
4. Para no depender de alguien: una regla de EventBridge sobre el evento `RotationSucceeded` que dispara ese redeploy (SSM Automation o una Lambda chica). La otra opción es usar el AWS JDBC Wrapper con el plugin de Secrets Manager, que relee el secreto cuando la autenticación falla.

En local es cambiar el `.env` y `docker compose up -d`. Si el volumen de PostgreSQL ya existía hay que cambiar la contraseña adentro también (`ALTER USER`), porque la imagen solo la usa al crear la base.

## Privilegio mínimo

**Contenedores**
- Backend con UID 10001, frontend con UID 101 (nginx-unprivileged), PostgreSQL con UID 70. Nada corre como root.
- En compose: `read_only: true` con tmpfs solo donde hace falta escribir, `cap_drop: [ALL]`, `no-new-privileges`, límites de CPU y memoria.
- En ECS: `readonlyRootFilesystem`, el mismo usuario sin root, sin ECS Exec.
- Las imágenes de runtime no traen curl ni gestor de paquetes que se use.

**AWS (IAM y red)**
- Rol de ejecución de ECS: pull solo de sus dos repositorios de ECR, escribir solo en sus log groups y leer solo el secreto de la base. `ecr:GetAuthorizationToken` es la única acción con `*` porque AWS no permite acotarla.
- Rol de la tarea: sin permisos, la aplicación no llama a ninguna API de AWS.
- Security groups encadenados: internet solo llega al ALB; el ALB solo a las tareas; solo el backend llega a PostgreSQL. La capa de base de datos no tiene ruta a internet.
- `allowed_account_ids` en el provider impide aplicar un ambiente en la cuenta equivocada.

**GitHub Actions**
- Permiso por defecto `contents: read`. Solo el job `publish` tiene `packages: write` e `id-token: write`, y solo corre en push a `main` o tags, nunca en PR.
- `pull_request` en lugar de `pull_request_target`: el código de un fork nunca corre con secretos.
- Actions fijadas por SHA, herramientas fijadas por digest.

## Comunicación segura

- Usuario a ALB: HTTPS con política `ELBSecurityPolicy-TLS13-1-2-2021-06`; el puerto 80 solo redirige. En prod el plan falla si no hay certificado.
- ALB a tareas: HTTP dentro de la VPC, en subnets privadas y limitado por security group. Cifrar este tramo (TLS en el contenedor o service mesh) queda como mejora.
- Backend a PostgreSQL: `rds.force_ssl=1` en el parameter group y `sslmode=require` en la URL. El siguiente paso es `sslmode=verify-full` con el bundle de CA de RDS.
- Headers en nginx: CSP estricta, `X-Frame-Options: DENY`, `nosniff`, `Referrer-Policy`, `Permissions-Policy`, `server_tokens off`.

## Escaneo

| Qué | Herramienta | Cuándo | Bloquea |
| --- | --- | --- | --- |
| Dependencias npm y secretos en el repo | Trivy fs | Cada push y PR | CRITICAL con parche |
| Dependencias npm de runtime | `npm audit --omit=dev` | Cada push y PR | critical |
| Imágenes (paquetes del SO y jars de Java) | Trivy image | Cada push y PR | CRITICAL con parche |
| Terraform (misconfiguraciones) | Trivy config | Cada push y PR | HIGH y CRITICAL |
| Dockerfiles, scripts, workflow | hadolint, shellcheck, actionlint | Cada push y PR | cualquier hallazgo |
| Imágenes ya publicadas | Escaneo de ECR al subir | Cada push a ECR | alerta |
| Versiones nuevas | Dependabot (actions, imágenes, maven, npm, terraform) | Semanal | abre PR |

Cada imagen genera un SBOM CycloneDX que queda como artefacto del pipeline, así se puede buscar rápido si una librería vulnerable está en producción.

### Parches de imágenes

Las imágenes base van fijadas por versión y digest. Dependabot propone cada semana el digest nuevo; el PR pasa por todo el pipeline (incluido Trivy) antes de mezclarse. Aunque el código no cambie, conviene reconstruir y desplegar al menos una vez por semana para recoger parches del sistema operativo. Tiempos objetivo: CRITICAL en 7 días, HIGH en 30.

## Riesgos detectados y tratamiento

| # | Riesgo en la base | Impacto | Tratamiento |
| --- | --- | --- | --- |
| 1 | `package-lock.json` generado con npm 11: `npm ci` falla con npm 10 (el de Node 20 y 22). | No se podía construir el frontend ni correr `verify.sh`; builds no reproducibles. | Lock regenerado sin cambiar versiones, probado con npm 10.8, 10.9 y 11. El pipeline usa `npm ci`, que falla si se vuelve a desalinear. |
| 2 | Contraseña por defecto `parking_dev_password` dentro del jar (`application-postgres.yml`) y en compose. | Si falta la variable, la app arranca con una contraseña conocida y publicada. | Quitada del perfil `postgres`: sin `DB_PASSWORD` la app no arranca. Compose usa un valor local explícito y en AWS se usa Secrets Manager. |
| 3 | Consola H2 prendida en el perfil por defecto. | Si el jar corre sin perfil, `/h2-console` permite ejecutar SQL desde el navegador (y en versiones vulnerables, código remoto). | Apagada por defecto; solo se prende con el perfil `local`, que `mvn spring-boot:run` activa para desarrollo. |
| 4 | nginx publicaba todo `/actuator/`. | Cualquier endpoint de actuator que se habilite queda expuesto a internet. | Solo `/actuator/health` pasa por nginx y por el ALB; el resto responde 404. Las métricas quedan internas. |
| 5 | Imagen del backend con curl instalado solo para el healthcheck y el jar completo en una sola capa; nginx también traía curl. | Más paquetes = más CVE y herramientas útiles para un atacante; cada deploy movía los 53 MB del jar. | Temurin JRE sobre Ubuntu 24.04 LTS sin curl (el healthcheck usa wget, que ya trae la imagen), 0 HIGH/CRITICAL en el SO. curl eliminado también de nginx. El jar va en capas: cada deploy mueve ~250 kB. Probé primero Liberica sobre Alpaquita (mucho más chica), pero Trivy no reconoce ese SO y el gate habría quedado ciego a sus paquetes. |
| 6 | Tomcat embebido 10.1.31 (el que trae Spring Boot 3.3.5) con 7 CVE CRITICAL, entre ellos CVE-2025-24813. | Ejecución remota de código bajo ciertas configuraciones. | `tomcat.version` sobrescrito a 10.1.60 en el `pom.xml`, misma línea 10.1, sin tocar la aplicación. De 7 CRITICAL / 29 HIGH a 0 / 15. |
| 7 | Frontend en Angular 18 (fuera de soporte): 15 CVE HIGH, el parche solo existe en Angular 19+. | XSS/filtrado de token XSRF en escenarios específicos. | Riesgo residual aceptado para esta entrega (actualizar Angular es cambiar la aplicación). Mitigado con CSP estricta y API en el mismo origen. Plan: migrar a Angular 20 LTS. |
| 8 | La API no tiene autenticación; `POST /neo/mes/iniciar` borra todas las estancias. | Cualquiera con acceso a la URL puede borrar datos. | Fuera del alcance de DevOps cambiar la app, pero la propuesta es: autenticación OIDC en el listener del ALB (Cognito o el IdP de la empresa) y AWS WAF con rate limiting; a mediano plazo Spring Security con roles. |
| 9 | `ddl-auto: update`: Hibernate altera el esquema al arrancar. | Cambios de esquema no revisados ni reversibles en producción. | Migraciones versionadas con Flyway y `ddl-auto: validate` en el perfil `postgres` (ver `docs/backup-recovery.md`). |
| 10 | Sin `.gitignore`, scripts sin permiso de ejecución. | Riesgo de subir `.env` o artefactos; la guía de evaluación fallaba con `permission denied`. | `.gitignore` agregado y scripts con modo 755 en git. |

## Estado de los escaneos (2026-09-30)

| Objetivo | Antes | Ahora | Qué queda |
| --- | --- | --- | --- |
| Imagen backend (SO + jars) | 7 CRITICAL, 29 HIGH | 0 CRITICAL, 15 HIGH | jackson 2.17, spring-core/webmvc/expression 6.1, spring-boot 3.3, spring-data 3.3, driver postgresql 42.7.4, micrometer 1.13. Todos se arreglan subiendo Spring Boot a 3.5.x. El sistema operativo (Ubuntu 24.04, 126 paquetes) no tiene HIGH ni CRITICAL. |
| Imagen frontend (nginx + estáticos) | | 0 | |
| `package-lock.json` | 15 HIGH | 15 HIGH | Angular 18; se arregla con Angular 19 o superior. |
| Terraform | | 0 HIGH/CRITICAL | Las excepciones (ALB público, salida HTTPS de las tareas, listener 80 que redirige) están marcadas con `#trivy:ignore` y su motivo en el código. |

**Plan para el riesgo residual**: una rama aparte que suba Spring Boot a 3.5.x y Angular a 20 LTS, con el pipeline como red de seguridad. Cuando eso entre, el gate pasa a bloquear también HIGH.
