#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verify_tmp_dir="$(mktemp -d)"
backend_pid=""
frontend_pid=""

cleanup() {
  if [[ -n "$frontend_pid" ]] && kill -0 "$frontend_pid" 2>/dev/null; then
    kill "$frontend_pid" 2>/dev/null || true
  fi
  if [[ -n "$backend_pid" ]] && kill -0 "$backend_pid" 2>/dev/null; then
    kill "$backend_pid" 2>/dev/null || true
  fi
  rm -rf -- "$verify_tmp_dir"
}
trap cleanup EXIT INT TERM

for command_name in java mvn node npm curl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "ERROR: no se encontró '$command_name' en PATH." >&2
    exit 1
  fi
done

echo "[1/5] Preparando frontend..."
(
  cd "$project_dir/frontend"
  npm ci
)

echo "[2/5] Iniciando backend con H2..."
(
  cd "$project_dir/backend"
  mvn --batch-mode spring-boot:run
) >"$verify_tmp_dir/backend.log" 2>&1 &
backend_pid="$!"

for attempt in {1..90}; do
  if curl --fail --silent http://localhost:8080/actuator/health | grep -q '"status":"UP"'; then
    break
  fi
  if ! kill -0 "$backend_pid" 2>/dev/null; then
    echo "ERROR: el backend terminó antes de estar disponible." >&2
    sed -n '1,240p' "$verify_tmp_dir/backend.log" >&2
    exit 1
  fi
  if [[ "$attempt" -eq 90 ]]; then
    echo "ERROR: el backend no estuvo disponible dentro del tiempo esperado." >&2
    sed -n '1,240p' "$verify_tmp_dir/backend.log" >&2
    exit 1
  fi
  sleep 1
done

echo "[3/5] Iniciando frontend..."
(
  cd "$project_dir/frontend"
  npm start -- --host 127.0.0.1
) >"$verify_tmp_dir/frontend.log" 2>&1 &
frontend_pid="$!"

for attempt in {1..90}; do
  if curl --fail --silent http://localhost:4200 | grep -q '<app-root'; then
    break
  fi
  if ! kill -0 "$frontend_pid" 2>/dev/null; then
    echo "ERROR: el frontend terminó antes de estar disponible." >&2
    sed -n '1,240p' "$verify_tmp_dir/frontend.log" >&2
    exit 1
  fi
  if [[ "$attempt" -eq 90 ]]; then
    echo "ERROR: el frontend no estuvo disponible dentro del tiempo esperado." >&2
    sed -n '1,240p' "$verify_tmp_dir/frontend.log" >&2
    exit 1
  fi
  sleep 1
done

echo "[4/5] Ejecutando prueba funcional..."
"$project_dir/scripts/smoke-test.sh"

echo "[5/5] Resultado..."
echo "STACK LOCAL CORRECTO: Spring Boot, H2 y Angular funcionaron de manera integrada."

