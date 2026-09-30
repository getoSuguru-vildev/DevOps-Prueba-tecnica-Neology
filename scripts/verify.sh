#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for command_name in java mvn node npm; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "ERROR: no se encontró '$command_name' en PATH." >&2
    exit 1
  fi
done

echo "[1/2] Ejecutando pruebas del backend..."
(
  cd "$project_dir/backend"
  mvn --batch-mode clean test
)

echo "[2/2] Instalando y compilando el frontend..."
(
  cd "$project_dir/frontend"
  npm ci
  npm run build
)

echo "VALIDACIÓN CORRECTA: backend y frontend compilan; las pruebas finalizaron correctamente."

