#!/usr/bin/env bash
set -euo pipefail

PURGE_DATA=false

show_help() {
    cat <<'EOF'
Uso: ./scripts/linux/down.sh [--purge-data]

Opcoes:
  --purge-data    Remove volumes e dados do Docker Compose
  -h, --help      Exibe esta ajuda
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --purge-data)
            PURGE_DATA=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Parametro invalido: $1" >&2
            show_help >&2
            exit 1
            ;;
    esac
done

run_step() {
    local name="$1"
    shift

    echo
    echo "==> ${name}"
    "$@"
    echo "OK: ${name}"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
local_dev_dir="$(cd "${script_dir}/../.." && pwd)"

remove_namespace() {
    kubectl delete namespace video-processor --ignore-not-found=true
}

compose_down_keep_volumes() {
    (
        cd "${local_dev_dir}"
        docker compose down --remove-orphans
    )
}

compose_down_purge_volumes() {
    (
        cd "${local_dev_dir}"
        docker compose down -v --remove-orphans
    )
}

run_step "Remover namespace de auth, jobs, notifications e video-service no Kubernetes" remove_namespace

if [[ "${PURGE_DATA}" == "true" ]]; then
    run_step "Derrubar Docker Compose removendo volumes e dados" compose_down_purge_volumes
else
    run_step "Derrubar Docker Compose mantendo volumes" compose_down_keep_volumes
fi

echo
echo "Ambiente derrubado com sucesso."
if [[ "${PURGE_DATA}" == "true" ]]; then
    echo "- Volumes removidos"
else
    echo "- Volumes preservados (use --purge-data para limpeza total)"
fi
