#!/usr/bin/env bash
# Valida la infraestructura sin cuenta de AWS: fmt, init sin backend, validate y plan.
# Con -var offline_plan=true el provider usa llaves falsas sin validarlas (ver providers.tf).
# Usa terraform local si existe; si no, la imagen oficial en Docker.
# Uso: infra/scripts/plan-offline.sh [dev|prod ...]   (por defecto los dos ambientes)
set -euo pipefail

infra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_image="hashicorp/terraform:1.16.4@sha256:985cdc6c1d9b0a65b83377f666efd2f740b47f02ac55be1ced3d18f7d3b0e829"

if [[ $# -gt 0 ]]; then
  environments=("$@")
else
  environments=(dev prod)
fi

tf() {
  local workdir="$1"
  shift
  if command -v terraform >/dev/null 2>&1; then
    (cd "$workdir" && terraform "$@")
  else
    docker run --rm \
      -v "$infra_dir:/infra" \
      -v parking-terraform-plugins:/plugins \
      -w "/infra${workdir#"$infra_dir"}" \
      -e TF_PLUGIN_CACHE_DIR=/plugins -e TF_IN_AUTOMATION=1 \
      "$terraform_image" "$@"
  fi
}

echo "== terraform fmt -check -recursive"
tf "$infra_dir" fmt -check -recursive

for env in "${environments[@]}"; do
  dir="$infra_dir/environments/$env"
  echo "== [$env] init -backend=false"
  tf "$dir" init -backend=false -input=false -no-color >/dev/null
  echo "== [$env] validate"
  tf "$dir" validate -no-color
  echo "== [$env] plan (offline)"
  plan_output="$(tf "$dir" plan -input=false -lock=false -no-color -var offline_plan=true)"
  echo "$plan_output" | grep -E '^(Plan:|No changes)'
done

echo "INFRAESTRUCTURA VALIDA: fmt, validate y plan correctos para: ${environments[*]}"
