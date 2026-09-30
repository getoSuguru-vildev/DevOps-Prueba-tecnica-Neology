# syntax=docker/dockerfile:1.7
# Imágenes base fijadas por versión y digest: builds reproducibles.
# Dependabot actualiza tag + digest (ver .github/dependabot.yml).

############################
# Etapa 1: compilación
############################
FROM maven:3.9.16-eclipse-temurin-17@sha256:f1ab639371711ac150c8e344bff7d39d8161c17a531b5dd653d3fa03af554807 AS build

WORKDIR /workspace

# Capa de dependencias: solo se invalida cuando cambia pom.xml.
COPY pom.xml ./
RUN mvn --batch-mode --no-transfer-progress dependency:go-offline

COPY src ./src
# Las pruebas se ejecutan en el job "backend" del pipeline, antes de construir la imagen.
RUN mvn --batch-mode --no-transfer-progress package -DskipTests \
    && mkdir -p /workspace/extracted \
    && java -Djarmode=tools -jar target/parking-api-*.jar extract --layers --launcher --destination /workspace/extracted

############################
# Etapa 2: ejecución
############################
# Liberica JRE 17 sobre Alpaquita (musl): ~44 MB, multi-arquitectura (amd64 y arm64) y es la JVM que usan
# los buildpacks oficiales de Spring Boot. eclipse-temurin:17-jre-alpine solo existe para amd64.
FROM bellsoft/liberica-runtime-container:jre-17.0.20.1_1-slim-musl@sha256:df940cbb015df69a32571c76060fec8734796ccbb2d90515fdbdf8540824e60b AS runtime

ARG VERSION=dev
ARG REVISION=unknown
LABEL org.opencontainers.image.title="parking-api" \
      org.opencontainers.image.description="API Spring Boot del estacionamiento Neology" \
      org.opencontainers.image.source="https://github.com/vmirandaNeo/DevOps-Prueba-tecnica-Neology" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

# Usuario sin privilegios con UID/GID fijos (compatibles con runAsNonRoot).
RUN addgroup -S -g 10001 app \
    && adduser -S -D -H -u 10001 -G app -h /app app

WORKDIR /app

# Capas de Spring Boot de la menos a la más cambiante: mejor reutilización de caché y pulls más pequeños.
COPY --from=build --chown=10001:10001 /workspace/extracted/dependencies/ ./
COPY --from=build --chown=10001:10001 /workspace/extracted/spring-boot-loader/ ./
COPY --from=build --chown=10001:10001 /workspace/extracted/snapshot-dependencies/ ./
COPY --from=build --chown=10001:10001 /workspace/extracted/application/ ./

USER 10001:10001

ENV SPRING_PROFILES_ACTIVE=postgres \
    LOG_FORMAT=json \
    JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError -Djava.io.tmpdir=/tmp"

EXPOSE 8080

# wget viene en busybox de la imagen base: no se instala curl en runtime.
HEALTHCHECK --interval=10s --timeout=3s --start-period=40s --retries=5 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/actuator/health/liveness || exit 1

# Forma exec: java es PID 1 y recibe SIGTERM directamente -> apagado ordenado (server.shutdown=graceful).
ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]
