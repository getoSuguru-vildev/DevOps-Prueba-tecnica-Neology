# Observabilidad

Qué se mide, qué se alerta y cómo seguir una petición desde el navegador hasta la base de datos. Lo que está implementado se puede probar en local; lo que es propuesta está marcado.

## Probarlo en local

```bash
docker compose --profile observability up --build --detach
```

| Qué | Dónde |
| --- | --- |
| Métricas del backend (formato Prometheus) | <http://localhost:8080/actuator/prometheus> (no se publica por nginx ni por el ALB) |
| Prometheus, targets y alertas | <http://localhost:9090/alerts> |
| Grafana, dashboard "Parking API" | <http://localhost:3000> (usuario `admin`, contraseña `GRAFANA_ADMIN_PASSWORD` del `.env`, por defecto `change_me_local_only`) |
| Logs | `docker compose logs -f backend frontend` |

## Logs

Todo sale por stdout en JSON, una línea por evento. Docker los rota (10 MB x 3 archivos por contenedor) y en AWS el driver `awslogs` los manda a CloudWatch Logs.

**nginx** (una línea por petición):

```json
{"time":"2026-09-30T01:43:51+00:00","request_id":"prueba-correlacion-1","remote_addr":"172.19.0.1","method":"GET","uri":"/neo/vehiculos","status":200,"bytes_sent":236,"request_time":0.041,"upstream_status":"200","upstream_response_time":"0.041","user_agent":"curl/8.7.1"}
```

**backend** (cada log de la aplicación, más una línea por petición del `CorrelationIdFilter`):

```json
{"time":"2026-09-30T01:44:35.092Z","message":"GET /neo/vehiculos status=200 duration_ms=75","logger_name":"mx.neology.parking.config.CorrelationIdFilter","level":"INFO","requestId":"prueba-2","method":"GET","path":"/neo/vehiculos","status":200,"duration_ms":75,"service":"parking-api"}
```

`LOG_FORMAT=text` regresa al formato normal de Spring Boot para desarrollo, con el `requestId` entre corchetes.

No se loguean cuerpos de petición ni credenciales. Las placas aparecen en las rutas; si se consideran dato personal, el siguiente paso es enmascararlas en el filtro.

## Métricas

| Capa | Métricas | Fuente |
| --- | --- | --- |
| API (RED) | `http_server_requests_seconds` (conteo, errores por status, histograma de latencia por ruta) | Micrometer, `/actuator/prometheus` |
| Pool de conexiones | `hikaricp_connections_active/idle/pending/max`, tiempos de espera | Micrometer |
| JVM y proceso | heap, GC, threads, `process_start_time_seconds` (reinicios) | Micrometer |
| Balanceador | `RequestCount`, `HTTPCode_Target_5XX_Count`, `TargetResponseTime`, `UnHealthyHostCount` por target group | CloudWatch (ALB) |
| Contenedores | CPU y memoria por servicio | CloudWatch Container Insights |
| PostgreSQL | `DatabaseConnections`, CPU, almacenamiento libre, queries lentas (log > 500 ms), Performance Insights | CloudWatch (RDS) |
| Frontend | Disponibilidad y latencia del target group del frontend en el ALB. **Propuesta**: CloudWatch RUM para Web Vitals y errores de JavaScript en el navegador. | CloudWatch |

En local, para PostgreSQL y nginx se puede sumar `postgres_exporter` y `nginx-prometheus-exporter`; no los agregué para no inflar el compose.

## Health checks

| Endpoint | Qué revisa | Quién lo usa |
| --- | --- | --- |
| `/actuator/health/liveness` | Que la JVM responde. No depende de la base: si la base cae, reiniciar el backend no arregla nada. | `HEALTHCHECK` de la imagen, health check del contenedor en ECS |
| `/actuator/health/readiness` | Que la app puede atender, incluida la conexión a PostgreSQL. | compose (`depends_on: service_healthy`), target group del ALB |
| `/actuator/health` | Estado general. | `smoke-test.sh`, único endpoint del actuator publicado por nginx |
| `/healthz` (nginx) | Que nginx responde, sin depender del backend. | compose y target group del frontend |

## SLI y SLO de la API

Alcance: peticiones a `/neo/**` medidas en el backend (en AWS también en el ALB).

| SLI | Definición | SLO (30 días) |
| --- | --- | --- |
| Disponibilidad | peticiones sin 5xx / peticiones totales | 99.5% |
| Latencia | peticiones que responden en menos de 300 ms / peticiones totales | 95% |

El 99.5% deja un **presupuesto de error de 0.5%**: con un millón de peticiones al mes son 5,000 errores. Si el presupuesto se acaba, se congelan los despliegues que no sean arreglos hasta recuperarlo.

Por qué estos valores: es una aplicación interna de un estacionamiento, no un sistema de pagos. 99.5% permite unas 3.6 horas de falla total al mes, suficiente para mantenimientos y para no alertar por ruido; se puede subir cuando haya historia real.

## Alertas

Las reglas están en `observability/prometheus/rules/parking-api.yml` y tienen pruebas unitarias con `promtool test rules` (corren en el pipeline). En AWS el equivalente son las alarmas de `infra/modules/observability`.

| Alerta | Condición | Severidad | Equivalente en AWS |
| --- | --- | --- | --- |
| `ApiErrorBudgetBurnFast` | error ratio > 7.2% en 1 h **y** en 5 min (14.4x el presupuesto) | page | `api-5xx-rate` (> 1% por 5 min) |
| `ApiErrorBudgetBurnSlow` | error ratio > 3% en 6 h y en 30 min (6x) | ticket | |
| `ApiLatencyP95High` | p95 > 300 ms por 10 min | page | `api-latency-p95` |
| `DbPoolSaturated` | pool > 90% o peticiones esperando conexión por 3 min | page | `db-connections` (> 80% de `max_connections`) |
| `BackendDown` | Prometheus no puede leer el backend por 1 min | page | `unhealthy-targets` |
| `BackendRestarting` | más de 2 reinicios en 15 min | page | `memory` de ECS (> 85%) |
| `JvmHeapHigh` | heap > 90% por 10 min | ticket | |
| | | | `db-cpu`, `db-free-storage` |

Las alertas de burn rate con dos ventanas (larga y corta) son las del libro de SRE de Google: la ventana larga evita alertar por un pico de un minuto y la corta hace que la alerta se apague rápido cuando se arregla.

### Ejemplo de regla

```yaml
- alert: ApiErrorBudgetBurnFast
  expr: sli:api_error_ratio:rate1h > (14.4 * 0.005) and sli:api_error_ratio:rate5m > (14.4 * 0.005)
  for: 2m
  labels:
    severity: page
  annotations:
    summary: "La API está consumiendo el presupuesto de error muy rápido"
    runbook: "docs/runbook.md#incidente"
```

### Consultas útiles (PromQL)

```promql
# Porcentaje de errores 5xx en los últimos 5 minutos
sli:api_error_ratio:rate5m

# p95 por endpoint
histogram_quantile(0.95, sum by (le, uri) (rate(http_server_requests_seconds_bucket{uri=~"/neo/.*"}[5m])))

# Endpoints que más fallan
topk(5, sum by (uri, status) (rate(http_server_requests_seconds_count{status=~"5.."}[5m])))

# Qué tan lleno está el pool de conexiones
max(hikaricp_connections_active / hikaricp_connections_max)
```

## Correlación frontend y backend

```text
navegador            nginx (local)              backend                         logs
─────────            ─────────────              ───────                         ────
interceptor genera   registra request_id   ->   CorrelationIdFilter lo pone     el mismo id aparece
X-Request-ID    ->   y reenvía el header        en el MDC y en la respuesta     en nginx y en backend
                                                todos sus logs lo llevan
error 5xx: el mensaje en pantalla muestra "(referencia: <id>)"
```

1. `request-id.interceptor.ts` agrega `X-Request-ID` a cada llamada a `/neo`.
2. nginx respeta ese id (o genera uno si no viene), lo escribe en su log y lo manda al backend. En AWS el ALB manda `/neo/*` directo al backend y el header llega igual.
3. `CorrelationIdFilter` lo mete en el MDC: todas las líneas de log de esa petición lo llevan. También lo regresa en la respuesta.
4. Si falla con 5xx, el usuario ve el id en el mensaje de error y lo puede reportar.

Buscar una petición en local:

```bash
docker compose logs backend frontend | grep <id>
```

En AWS, CloudWatch Logs Insights sobre los log groups `/ecs/parking-prod/backend` y `/ecs/parking-prod/frontend`:

```sql
fields @timestamp, @log, level, message, status, duration_ms
| filter requestId = "<id>" or request_id = "<id>"
| sort @timestamp asc
```

Otras consultas:

```sql
# errores 5xx por minuto
fields @timestamp
| filter status >= 500
| stats count(*) as errores by bin(1m)

# las 20 peticiones más lentas de la última hora
fields @timestamp, requestId, method, path, status, duration_ms
| filter ispresent(duration_ms)
| sort duration_ms desc
| limit 20
```

## Trazas (propuesta)

No lo implementé para no meter un agente sin poder probarlo contra un backend de trazas real, pero el camino corto es:

- Agente de OpenTelemetry para Java sin tocar código: `JAVA_TOOL_OPTIONS=-javaagent:/otel/opentelemetry-javaagent.jar`, instrumenta Spring MVC, JDBC y Hikari.
- Exporta por OTLP a un sidecar de AWS Distro for OpenTelemetry en la tarea de ECS, que manda a X-Ray (o a Tempo/Jaeger).
- Propagación W3C `traceparent`. El `X-Request-ID` actual se puede agregar como atributo del span para no perder la correlación que ya existe.
- En el navegador, el SDK web de OpenTelemetry (o CloudWatch RUM con X-Ray activado) para que la traza empiece en el clic del usuario.

## Dashboards

- Local: Grafana provisionado con `observability/grafana/dashboards/parking-api.json`: SLI de disponibilidad y latencia contra el SLO, presupuesto de error restante, alertas activas, peticiones por status, p50/p95/p99, pool de conexiones y heap.
- AWS: `aws_cloudwatch_dashboard` en Terraform con peticiones y errores del backend, latencias del ALB, conexiones y CPU de PostgreSQL, y CPU/memoria de ECS.

## Retención

| Dato | Dev | Prod |
| --- | --- | --- |
| Logs de aplicación (CloudWatch) | 14 días | 30 días |
| Flow logs de VPC | 14 días | 30 días |
| Métricas de CloudWatch | 15 meses (por defecto de AWS) | 15 meses |
| Prometheus local | 7 días | n/a |
| Performance Insights | 7 días | 7 días |

Para auditoría de largo plazo, una subscription de CloudWatch Logs hacia S3 con lifecycle a Glacier es barata y no cambia nada en la aplicación.
