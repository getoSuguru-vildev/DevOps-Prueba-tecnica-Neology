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
# Temurin JRE 17 sobre Ubuntu 24.04 LTS: mismo proveedor que la etapa de build, multi-arquitectura
# (amd64 y arm64) y Trivy reconoce el sistema operativo, así el gate de CVE también cubre los paquetes del SO.
# (eclipse-temurin:17-jre-alpine solo existe para amd64, y el SO de Liberica/Alpaquita no lo detecta Trivy.)
FROM eclipse-temurin:17-jre-noble@sha256:d1b6f76d8112c41f1068597741f0c0bda36d323365078e685381f72e5ec51ca0 AS runtime

ARG VERSION=dev
ARG REVISION=unknown
LABEL org.opencontainers.image.title="parking-api" \
      org.opencontainers.image.description="API Spring Boot del estacionamiento Neology" \
      org.opencontainers.image.source="https://github.com/vmirandaNeo/DevOps-Prueba-tecnica-Neology" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

# Usuario sin privilegios con UID/GID fijos (compatibles con runAsNonRoot).
# curl no se usa en runtime: se quita. wget se queda para el healthcheck.
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --home-dir /app --no-create-home --shell /usr/sbin/nologin app \
    && apt-get purge -y --auto-remove curl \
    && rm -rf /var/lib/apt/lists/*

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

# wget ya viene en la imagen base; no se instala nada extra para el healthcheck.
HEALTHCHECK --interval=10s --timeout=3s --start-period=40s --retries=5 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/actuator/health/liveness || exit 1

# Forma exec: java es PID 1 y recibe SIGTERM directamente -> apagado ordenado (server.shutdown=graceful).
ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]
