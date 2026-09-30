#!/usr/bin/env bash
# Restaura un respaldo generado por scripts/backup.sh sobre la base del stack de docker compose.
# Reemplaza los datos actuales. Antes de restaurar guarda un respaldo del estado actual por si acaso.
#
# Uso: scripts/restore.sh backups/parking-AAAAMMDDTHHMMSSZ.dump [--yes]
set -Eeuo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
db_service="database"
app_service="backend"
backup_file=""
assume_yes=false

for arg in "$@"; do
  case "$arg" in
    --yes) assume_yes=true ;;
    *) backup_file="$arg" ;;
  esac
done

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}

[[ -n "$backup_file" ]] || fail "uso: scripts/restore.sh <archivo.dump> [--yes]"
[[ -f "$backup_file" ]] || fail "no existe el archivo $backup_file"
[[ -s "$backup_file" ]] || fail "el archivo $backup_file está vacío"
backup_file="$(cd "$(dirname "$backup_file")" && pwd)/$(basename "$backup_file")"

cd "$project_dir"

docker compose ps --status running --services 2>/dev/null | grep -qx "$db_service" \
  || fail "el servicio '$db_service' no está corriendo (docker compose up -d $db_service)."

echo "[1/6] Verificando integridad..."
if [[ -f "$backup_file.sha256" ]]; then
  # Se compara solo el hash, así funciona aunque el archivo se haya copiado o renombrado.
  expected_hash="$(cut -d' ' -f1 "$backup_file.sha256")"
  actual_hash="$(sha256 "$backup_file" | cut -d' ' -f1)"
  [[ "$expected_hash" == "$actual_hash" ]] \
    || fail "el checksum no coincide: el archivo está dañado o fue modificado."
else
  echo "AVISO: no hay archivo .sha256, no se puede verificar la integridad." >&2
fi
docker compose exec -T "$db_service" pg_restore --list < "$backup_file" >/dev/null \
  || fail "pg_restore no puede leer el archivo."

if [[ "$assume_yes" != true ]]; then
  echo "Se van a REEMPLAZAR todos los datos de la base con $(basename "$backup_file")."
  read -r -p "Escribe 'restaurar' para continuar: " answer
  [[ "$answer" == "restaurar" ]] || fail "cancelado."
fi

echo "[2/6] Respaldo del estado actual antes de tocar nada..."
BACKUP_DIR="$project_dir/backups/antes-de-restaurar" "$project_dir/scripts/backup.sh" >/dev/null

# Si el backend estaba arriba se detiene para que nadie escriba durante la restauración,
# y se vuelve a levantar aunque la restauración falle.
backend_was_running=false
if docker compose ps --status running --services | grep -qx "$app_service"; then
  backend_was_running=true
fi
restart_backend() {
  if [[ "$backend_was_running" == true ]]; then
    echo "[5/6] Levantando backend..."
    docker compose --progress quiet up --detach --no-build --wait "$app_service" >/dev/null
  fi
}
trap restart_backend EXIT

echo "[3/6] Deteniendo backend..."
docker compose --progress quiet stop "$app_service" >/dev/null

# --single-transaction: si algo falla se revierte todo y la base queda como estaba.
echo "[4/6] Restaurando..."
docker compose exec -T "$db_service" sh -c \
  'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --no-privileges --single-transaction --exit-on-error' \
  < "$backup_file"

trap - EXIT
restart_backend

echo "[6/6] Verificación rápida..."
counts="$(docker compose exec -T "$db_service" sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -c "select (select count(*) from vehicles), (select count(*) from parking_stays)"')"
echo "Datos restaurados: ${counts%%|*} vehículos, ${counts##*|} estancias."

echo "RESTAURACIÓN CORRECTA desde $(basename "$backup_file")"
