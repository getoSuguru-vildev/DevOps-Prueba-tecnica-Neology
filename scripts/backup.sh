#!/usr/bin/env bash
# Respaldo lógico de PostgreSQL del stack de docker compose (pg_dump en formato custom).
# La contraseña no pasa por este script: pg_dump corre dentro del contenedor con sus propias variables.
#
# Uso: scripts/backup.sh
# Variables opcionales:
#   BACKUP_DIR             carpeta destino (por defecto ./backups, ignorada por git)
#   BACKUP_RETENTION_DAYS  días que se conservan los respaldos (por defecto 7)
set -Eeuo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backup_dir="${BACKUP_DIR:-$project_dir/backups}"
retention_days="${BACKUP_RETENTION_DAYS:-7}"
db_service="database"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_file="$backup_dir/parking-$timestamp.dump"
partial_file="$backup_file.partial"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# Si algo falla a medio camino no queda un respaldo incompleto con nombre de bueno.
trap 'rm -f "$partial_file"' EXIT
trap 'echo "ERROR: el respaldo falló en la línea $LINENO" >&2' ERR

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

cd "$project_dir"

docker compose ps --status running --services 2>/dev/null | grep -qx "$db_service" \
  || fail "el servicio '$db_service' no está corriendo (docker compose up -d)."

umask 077
mkdir -p "$backup_dir"

echo "[1/4] Generando respaldo..."
docker compose exec -T "$db_service" sh -c \
  'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --no-owner --no-privileges' \
  > "$partial_file"

echo "[2/4] Validando que no esté vacío y que se pueda leer..."
[[ -s "$partial_file" ]] || fail "el archivo de respaldo quedó vacío."
table_of_contents="$(docker compose exec -T "$db_service" pg_restore --list < "$partial_file")" \
  || fail "pg_restore no puede leer el respaldo."
grep -q "TABLE DATA public vehicles" <<<"$table_of_contents" \
  || fail "el respaldo no contiene los datos de la tabla vehicles."

mv "$partial_file" "$backup_file"
(cd "$backup_dir" && sha256 "$(basename "$backup_file")" > "$(basename "$backup_file").sha256")

echo "[3/4] Borrando respaldos de más de $retention_days días..."
find "$backup_dir" -maxdepth 1 -name 'parking-*.dump*' -mtime +"$retention_days" -print -delete

echo "[4/4] Listo."
echo "RESPALDO CORRECTO: $backup_file ($(du -h "$backup_file" | cut -f1))"
