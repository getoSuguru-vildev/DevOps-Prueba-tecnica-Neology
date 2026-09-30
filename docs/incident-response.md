# Respuesta a incidente: errores y latencia después de un despliegue

## Escenario

> Después de un despliegue, el frontend responde, pero una parte de las solicitudes al backend devuelve error y la latencia aumenta. PostgreSQL reporta un crecimiento repentino de conexiones.

También cubro la variante más grave (la del enunciado anterior de la prueba): la API devuelve 500 en general, PostgreSQL llega al límite de conexiones y algunos contenedores se reinician.

Lo que ya dice el enunciado: el frontend está bien, así que el ALB y nginx funcionan; el problema está entre el backend y la base, y empezó con el despliegue. Eso no descarta nada todavía, pero dice por dónde empezar.

## Primeros 5 minutos

1. **Declarar el incidente** y asignar roles aunque sea una sola persona al inicio: quién coordina (incident commander), quién investiga y quién comunica. Abrir un canal y un documento con la línea de tiempo.
2. **Severidad**: degradación parcial con errores visibles = SEV2. Si el error rate pasa de 50% o hay reinicios en cadena, SEV1.
3. **Congelar despliegues**: nadie mezcla ni despliega nada más hasta cerrar el incidente.
4. **No reiniciar todo a ciegas**: reiniciar el backend abre conexiones nuevas de golpe y puede empeorar justo el síntoma que tenemos.

## Señales a revisar (en este orden)

| # | Qué | Dónde | Qué busco |
| --- | --- | --- | --- |
| 1 | Qué cambió | Resumen del pipeline, `git log`, historial de task definitions | Hora del deploy, digest nuevo, diff de código, migraciones de Flyway nuevas, cambios en variables (por ejemplo `DB_POOL_MAX_SIZE`) o en Terraform |
| 2 | Errores y latencia | Dashboard (CloudWatch o Grafana): 5xx y p95 por endpoint | ¿Empezó exactamente con el deploy? ¿Todos los endpoints o solo algunos? |
| 3 | Pool de conexiones | `hikaricp_connections_active/pending/max` por instancia | Pool lleno y peticiones esperando = la app no suelta conexiones o las queries tardan |
| 4 | PostgreSQL | `DatabaseConnections`, CPU, Performance Insights (top SQL), `pg_stat_activity` | Quién tiene las conexiones, en qué estado y desde cuándo |
| 5 | Tareas de ECS | Número de tareas, eventos del servicio, `stoppedReason` | ¿El autoescalado subió tareas? ¿Hay tareas de las dos revisiones a la vez? ¿Reinicios por OOM o por health check? |
| 6 | Logs | CloudWatch Logs Insights | Tipo de error y en qué revisión ocurre |

Consultas que tendría listas:

```sql
-- PostgreSQL: quién tiene las conexiones
select usename, application_name, client_addr, state, wait_event_type,
       count(*), max(now() - state_change) as mas_antigua
from pg_stat_activity
where datname = 'parking'
group by 1, 2, 3, 4, 5
order by count(*) desc;

-- Transacciones abiertas que no hacen nada (fuga clásica)
select pid, now() - xact_start as duracion, left(query, 80)
from pg_stat_activity
where state = 'idle in transaction'
order by duracion desc;
```

```sql
# Logs Insights: errores por tipo en los últimos 30 minutos
fields @timestamp, @logStream, level, message
| filter level = "ERROR" or status >= 500
| stats count(*) by message
| sort count(*) desc
| limit 20
```

```promql
# ¿Solo fallan las instancias nuevas?
sum by (instance) (rate(http_server_requests_seconds_count{status=~"5.."}[5m]))
max by (instance) (hikaricp_connections_pending)
```

Si el backend loguea `Connection is not available, request timed out after 5000ms`, el pool de Hikari está agotado: las peticiones esperaron 5 segundos una conexión y fallaron. Esa sola línea explica a la vez los errores y la latencia.

## Hipótesis

| Hipótesis | Cómo se confirma | Cómo se descarta |
| --- | --- | --- |
| **1. La versión nueva no libera conexiones** (una transacción que se queda abierta, un cambio en `@Transactional`, una llamada lenta dentro de una transacción) | Pool lleno solo en tareas de la revisión nueva, sesiones `idle in transaction` crecientes, avisos de `leak-detection-threshold` en el log | Las tareas viejas y nuevas se comportan igual |
| **2. Demasiadas conexiones por configuración o escala** (subió `DB_POOL_MAX_SIZE`, o tareas x pool pasa `max_connections`). Durante el rolling update corren las dos revisiones a la vez (hasta 200%), el doble de pools. Si la latencia sube, el autoescalado agrega tareas y cada una abre otro pool: círculo vicioso | `DatabaseConnections` sube en escalones que coinciden con tareas nuevas; `tareas x pool` cerca de `max_connections` | Conexiones estables aunque cambie el número de tareas |
| **3. Una query lenta o un lock** (query nueva sin índice, o una migración de Flyway que bloquea una tabla) | Performance Insights muestra una query dominante; `pg_stat_activity` con `wait_event_type = Lock`; la migración nueva altera una tabla grande | Top SQL sin cambios respecto a antes del deploy |
| **4. Tormenta de reintentos o reinicios** (los health checks fallan por la lentitud, ECS mata tareas, las nuevas reconectan de golpe) | Eventos de ECS con tareas detenidas por health check; picos de conexiones cada vez que arranca una tarea | Sin tareas detenidas |
| **5. Problema de infraestructura** (failover de RDS, CPU al 100%, almacenamiento lleno, créditos de CPU agotados en instancias `t4g`) | Eventos de RDS, `CPUUtilization`, `FreeStorageSpace`, `CPUCreditBalance` | Métricas de RDS normales antes de que suban las conexiones |

**¿Aplicación, infraestructura o base de datos?**
- Si solo fallan las tareas nuevas y las viejas están bien: es la aplicación (hipótesis 1 o 3).
- Si todo empeora a la vez y RDS muestra eventos o CPU saturado sin cambio de carga: infraestructura o base (5).
- Si las conexiones suben en escalones con el número de tareas: configuración o escala (2).
- Si hay reinicios en cadena: es una consecuencia (4); hay que buscar qué los provoca.

## Contención

En orden, de lo más seguro a lo más invasivo:

1. **Rollback si se cumple el criterio** (abajo). Es lo más rápido y lo que menos hay que entender en el momento.
2. **Poner tope al autoescalado** para que no agregue más pools mientras se estabiliza:
   ```bash
   aws application-autoscaling register-scalable-target --service-namespace ecs \
     --resource-id service/parking-prod/backend --scalable-dimension ecs:service:DesiredCount \
     --min-capacity 2 --max-capacity 4
   ```
3. **Liberar conexiones colgadas** en PostgreSQL, solo las `idle in transaction` viejas (el parámetro `idle_in_transaction_session_timeout` de 60 s ya lo hace solo, pero se puede adelantar):
   ```sql
   select pg_terminate_backend(pid) from pg_stat_activity
   where state = 'idle in transaction' and now() - state_change > interval '30 seconds';
   ```
4. Si es una migración bloqueando: esperar si está por terminar; cancelarla solo si es seguro (Flyway corre cada migración en su transacción, así que cancelar la revierte).
5. Si el tráfico es anormal (abuso o bot): regla de rate limit en WAF.

### Criterios de rollback

Se regresa a la versión anterior si **cualquiera** de estas se cumple:
- El problema empezó en los 30 minutos posteriores al deploy.
- La alerta `ApiErrorBudgetBurnFast` o `api-5xx-rate` está disparada, o el error rate pasa de 2%.
- El p95 pasa de 300 ms por más de 5 minutos.
- Hay peticiones esperando conexión solo en las instancias nuevas.
- No hay un arreglo claro que se pueda desplegar en menos de 15 minutos.

La duda se resuelve a favor del rollback. Se puede regresar sin miedo porque las migraciones son compatibles hacia atrás (ver `docs/backup-recovery.md`): la versión anterior funciona con el esquema nuevo.

```bash
terraform -chdir=infra/environments/prod apply -var backend_image_digest=<digest anterior>
# o, si urge:
aws ecs update-service --cluster parking-prod --service backend --task-definition parking-prod-backend:<revisión anterior>
```

## Recuperación

1. Confirmar que el error rate, el p95 y las conexiones regresan a la línea base y se mantienen 30 minutos.
2. Confirmar que no quedan sesiones `idle in transaction` ni conexiones de más.
3. Regresar el autoescalado a sus valores (o dejar que Terraform lo haga en el siguiente apply).
4. Revisar cuánto presupuesto de error se consumió y si hay que congelar despliegues el resto del periodo.
5. Descongelar despliegues solo con el arreglo probado.

## Evitar pérdida de información

- La API es transaccional: una petición que falla con 5xx hace rollback y no deja datos a medias. La entrada o salida que falló no se registró y el usuario la puede reintentar.
- **No** se restaura la base por un incidente de conexiones: los datos están bien. Restaurar haría perder todo lo registrado desde el punto elegido.
- Antes de cualquier intervención manual en la base (terminar sesiones, tocar parámetros): snapshot manual de RDS.
- Nada de `docker compose down -v` ni de borrar tareas o logs mientras se investiga. Los logs de CloudWatch se guardan 30 días; guardar la salida de `pg_stat_activity` y las gráficas para el postmortem.
- Si alguna operación quedó dudosa (por ejemplo una salida cobrada pero con error en pantalla), el `requestId` del log permite verificarla una por una.

## Comunicación

Mensaje inicial (en los primeros 10 minutos), actualizaciones cada 30 minutos aunque no haya novedades, y cierre.

```text
[Incidente SEV2] Parking API con errores intermitentes
Desde: 14:05 (hora centro)
Impacto: parte de los registros de entrada/salida fallan o tardan. El sitio carga.
Qué hacemos: investigando, coincide con el despliegue de las 14:00; evaluando rollback.
Recomendación a operación: si un registro falla, reintentar; si persiste, usar la bitácora manual.
Siguiente actualización: 14:40.
```

Al cerrar: hora de fin, causa raíz resumida, qué se hizo y la fecha del postmortem. Audiencias: equipo técnico (canal del incidente), operación del estacionamiento (qué hacer mientras tanto) y responsables del negocio (impacto y tiempo estimado).

## Línea de tiempo esperada

| Tiempo | Acción |
| --- | --- |
| T+0 | Alerta de burn rate o de conexiones. Se declara el incidente. |
| T+5 | Se identifica que coincide con el deploy; pool lleno en instancias nuevas. |
| T+10 | Se cumple el criterio: rollback. Tope al autoescalado. Primer mensaje. |
| T+20 | Tareas viejas sanas, conexiones bajando. |
| T+50 | 30 minutos estables. Se cierra el incidente y se agenda el postmortem. |

## Acciones preventivas

**Aplicación y base de datos**
- RDS Proxy entre ECS y PostgreSQL: multiplexa conexiones, absorbe los picos de tareas nuevas durante deploys y escalados, y hace el failover más rápido. Es la mejora más directa para este escenario.
- Mantener `connection-timeout` corto (5 s), `leak-detection-threshold` (30 s) y `statement_timeout` en la base, que ya están configurados.
- Pruebas de integración con Testcontainers y PostgreSQL real para detectar transacciones que no cierran.

**Pipeline**
- Despliegue canary o blue/green con CodeDeploy: 10% del tráfico por 10 minutos y rollback automático si se dispara una alarma.
- Prueba de carga corta (k6) en staging con un gate sobre conexiones y p95.
- Revisar migraciones con un linter (por ejemplo squawk) para detectar operaciones que bloquean tablas.
- La validación de Terraform que ya existe (`tareas x pool <= 80% de max_connections`) evita la hipótesis 2 por configuración.

**Monitoreo**
- Alerta de `hikaricp_connections_pending > 0` (ya existe) y de conexiones de RDS al 80% (ya existe).
- Métricas y logs etiquetados con la versión desplegada para comparar revisiones en el mismo panel.
- Anotaciones de deploy en los dashboards para ver al instante si un cambio coincide con el problema.

**Proceso**
- Postmortem sin culpables en menos de 5 días hábiles, con dueños y fechas para cada acción.
- Practicar este escenario en el game day trimestral.
