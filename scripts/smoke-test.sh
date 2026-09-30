#!/usr/bin/env bash
set -euo pipefail

api_url="${API_URL:-http://localhost:8080}"
frontend_url="${FRONTEND_URL:-http://localhost:4200}"
unique_suffix="$(date +%H%M%S)"
plate="DEV-${unique_suffix}"

post_json() {
  local path="$1"
  local body="$2"
  curl --fail --silent --show-error \
    -X POST "$api_url$path" \
    -H 'Content-Type: application/json' \
    --data "$body"
}

echo "[1/6] Verificando salud del backend..."
health_response="$(curl --fail --silent --show-error "$api_url/actuator/health")"
echo "$health_response" | grep -q '"status":"UP"'

echo "[2/6] Registrando residente $plate..."
post_json "/neo/vehiculos/residentes" "{\"placa\":\"$plate\"}" >/dev/null

echo "[3/6] Registrando entrada..."
post_json "/neo/estancias/entrada" "{\"placa\":\"$plate\"}" >/dev/null

echo "[4/6] Registrando salida..."
post_json "/neo/estancias/salida" "{\"placa\":\"$plate\"}" >/dev/null

echo "[5/6] Verificando reporte de residentes..."
report_response="$(curl --fail --silent --show-error "$api_url/neo/residentes/pagos")"
echo "$report_response" | grep -q "\"placa\":\"$plate\""

echo "[6/6] Verificando frontend cuando está disponible..."
if curl --fail --silent --show-error "$frontend_url" | grep -q '<app-root'; then
  echo "Frontend disponible."
else
  echo "AVISO: el frontend no respondió; la validación de API sí fue correcta." >&2
fi

echo "SMOKE TEST CORRECTO para la placa $plate."

