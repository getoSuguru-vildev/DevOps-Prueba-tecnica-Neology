# syntax=docker/dockerfile:1.7
# Imágenes base fijadas por versión y digest. Dependabot las mantiene al día.

############################
# Etapa 1: compilación Angular
############################
FROM node:22.23.3-alpine3.24@sha256:0a7108bf6c7bf5de370ffb1a3ed6be93d405b43ff159f681a8d18c0e2bc2e402 AS build

WORKDIR /app

# Capa de dependencias: solo se invalida si cambia package.json o el lock.
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY angular.json tsconfig.json tsconfig.app.json ./
COPY src ./src
RUN npm run build

############################
# Etapa 2: nginx sin privilegios
############################
FROM nginxinc/nginx-unprivileged:1.30-alpine@sha256:ed04ec1ff34502c339ee5c3ae3f855442398edc1d05591e2b98981dcbbd20b1e AS runtime

ARG VERSION=dev
ARG REVISION=unknown
LABEL org.opencontainers.image.title="parking-frontend" \
      org.opencontainers.image.description="SPA Angular del estacionamiento Neology servida con nginx" \
      org.opencontainers.image.source="https://github.com/vmirandaNeo/DevOps-Prueba-tecnica-Neology" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

# curl no se usa en runtime; se quita para reducir superficie. La config por defecto se reemplaza por la plantilla.
USER root
RUN apk del --no-cache curl \
    && rm -f /etc/nginx/conf.d/default.conf
USER 101

ENV BACKEND_UPSTREAM=backend:8080 \
    NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1 \
    NGINX_ENTRYPOINT_QUIET_LOGS=1

COPY --chown=101:101 nginx.conf /etc/nginx/templates/default.conf.template
COPY --from=build --chown=101:101 /app/dist/parking-frontend/browser /usr/share/nginx/html

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1

# nginx maneja SIGQUIT para apagado ordenado (STOPSIGNAL heredado de la imagen base).
