#!/usr/bin/env bash
# Simulacro de recuperación: prueba que un respaldo sirve de verdad y mide cuánto tarda.
#   1. Registra un vehículo con una estancia cerrada.
#   2. Saca un respaldo.
#   3. Simula la pérdida total de la base (borra el volumen de PostgreSQL).
#   4. Restaura el respaldo y confirma que el vehículo y su estancia regresaron.
#
# CUIDADO: borra los datos locales del stack. Por eso pide --yes.
# Uso: scripts/restore-drill.sh --yes
set -Eeuo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
api_url="${API_URL:-http://localhost:8080}"

if [[ "${1:-}" != "--yes" ]]; then
  echo "Este simulacro BORRA la base de datos local del stack. Correr con: scripts/restore-drill.sh --yes" >&2
  exit 1
fi

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

post_json() {
  curl --fail --silent --show-error -X POST "$api_url$1" -H 'Content-Type: application/json' --data "$2" >/dev/null
}

cd "$project_dir"
drill_start=$(date +%s)
plate="DRL-$(date +%H%M%S)$(printf '%02d' $((RANDOM % 100)))"

echo "[1/5] Levantando stack y creando datos de prueba ($plate)..."
docker compose --progress quiet up --detach --no-build --wait >/dev/null
post_json "/neo/vehiculos/residentes" "{\"placa\":\"$plate\"}"
post_json "/neo/estancias/entrada" "{\"placa\":\"$plate\"}"
post_json "/neo/estancias/salida" "{\"placa\":\"$plate\"}"

echo "[2/5] Respaldo..."
backup_output="$(BACKUP_DIR="$project_dir/backups/simulacro" "$project_dir/scripts/backup.sh")"
backup_file="$(grep -o '/.*\.dump' <<<"$backup_output" | tail -n 1)"
[[ -f "$backup_file" ]] || fail "no se generó el respaldo."
echo "      $backup_file"

echo "[3/5] Simulando desastre: se borra el volumen de PostgreSQL..."
docker compose --progress quiet down --volumes >/dev/null
docker compose --progress quiet up --detach --no-build --wait >/dev/null
status="$(curl --silent --output /dev/null --write-out '%{http_code}' "$api_url/neo/vehiculos/$plate")"
[[ "$status" == "404" ]] || fail "después de borrar la base el vehículo debería no existir (HTTP $status)."
echo "      Base vacía confirmada (HTTP 404 para $plate)."

echo "[4/5] Restaurando..."
restore_start=$(date +%s)
"$project_dir/scripts/restore.sh" "$backup_file" --yes | sed 's/^/      /'
restore_seconds=$(( $(date +%s) - restore_start ))

echo "[5/5] Verificando datos restaurados..."
detail="$(curl --fail --silent --show-error "$api_url/neo/vehiculos/$plate")"
grep -q "\"placa\":\"$plate\"" <<<"$detail" || fail "el vehículo no se restauró."
grep -q '"abierta":false' <<<"$detail" || fail "la estancia cerrada no se restauró."

total_seconds=$(( $(date +%s) - drill_start ))
echo "SIMULACRO CORRECTO: $plate restaurado con su estancia. Restauración: ${restore_seconds}s, simulacro completo: ${total_seconds}s."
