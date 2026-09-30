#!/usr/bin/env bash
# Mismas validaciones que verify.sh (pruebas Java + build Angular de producción) pero dentro de contenedores,
# para quien no tiene Java 17, Maven ni Node instalados. Solo necesita Docker.
# El código se manda por stdin (tar) en lugar de montar carpetas: no deja archivos de root en el repo
# y funciona igual en Docker Desktop, Colima o Linux.
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Mismas imágenes que usan los Dockerfiles, para que local y CI compilen igual.
maven_image="maven:3.9.16-eclipse-temurin-17@sha256:f1ab639371711ac150c8e344bff7d39d8161c17a531b5dd653d3fa03af554807"
node_image="node:22.23.3-alpine3.24@sha256:0a7108bf6c7bf5de370ffb1a3ed6be93d405b43ff159f681a8d18c0e2bc2e402"

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker no está disponible." >&2
  exit 1
fi

echo "[1/2] Pruebas del backend (mvn clean test)..."
tar -C "$project_dir/backend" -cf - pom.xml src \
  | docker run --rm -i -v parking-maven-cache:/root/.m2 "$maven_image" \
      sh -c 'mkdir -p /w && cd /w && tar -xf - && mvn --batch-mode --no-transfer-progress clean test'

echo "[2/2] Instalación reproducible y build de producción del frontend..."
tar -C "$project_dir/frontend" -cf - package.json package-lock.json angular.json tsconfig.json tsconfig.app.json src \
  | docker run --rm -i -v parking-npm-cache:/root/.npm "$node_image" \
      sh -c 'mkdir -p /w && cd /w && tar -xf - && npm ci --no-audit --no-fund && npm run build'

echo "VALIDACIÓN CORRECTA (Docker): backend y frontend compilan; las pruebas finalizaron correctamente."
