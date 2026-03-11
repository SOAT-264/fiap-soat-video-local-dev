#!/usr/bin/env bash
set -euo pipefail

run_step() {
    local name="$1"
    shift

    echo
    echo "==> ${name}"
    "$@"
    echo "OK: ${name}"
}

ensure_repository() {
    local root="$1"
    local name="$2"
    local url="$3"
    local validation_path="$4"
    local repo_dir="${root}/${name}"
    local repo_validation_path="${repo_dir}/${validation_path}"

    if [[ -e "${repo_dir}" ]]; then
        if [[ ! -d "${repo_dir}" ]]; then
            echo "Caminho esperado para o repositorio '${name}' nao e um diretorio: ${repo_dir}" >&2
            return 1
        fi

        if [[ ! -e "${repo_validation_path}" ]]; then
            echo "Diretorio existente para '${name}' sem estrutura esperada. Arquivo/pasta obrigatorio ausente: ${repo_validation_path}" >&2
            return 1
        fi

        echo "Repositorio encontrado: ${name}" >&2
        printf '%s\n' "${repo_dir}"
        return 0
    fi

    if ! command -v git >/dev/null 2>&1; then
        echo "Git nao encontrado no PATH. Instale/configure o Git para clonar o repositorio ausente '${name}'." >&2
        return 1
    fi

    echo "Repositorio ausente: ${name}. Clonando de ${url}" >&2
    git clone "${url}" "${repo_dir}"

    if [[ ! -e "${repo_validation_path}" ]]; then
        echo "Clone de '${name}' concluido, mas a estrutura esperada nao foi encontrada em: ${repo_validation_path}" >&2
        return 1
    fi

    printf '%s\n' "${repo_dir}"
}

ensure_awslocal() {
    if command -v awslocal >/dev/null 2>&1; then
        return 0
    fi

    echo "Comando 'awslocal' nao encontrado no PATH. Instale o AWS CLI Local antes de continuar. Exemplo: pip install awscli-local" >&2
    return 1
}

test_kubectl_resource() {
    kubectl "$@" >/dev/null 2>&1
}

wait_for_deployment_rollout() {
    local namespace="$1"
    local name="$2"
    local timeout_seconds="${3:-180}"

    kubectl rollout status "deployment/${name}" -n "${namespace}" --timeout="${timeout_seconds}s"
}

wait_for_namespace_deployments() {
    local namespace="$1"
    local timeout_seconds="${2:-180}"
    local deployments=()

    if ! mapfile -t deployments < <(kubectl get deployment -n "${namespace}" -o name 2>/dev/null); then
        echo "Falha ao listar deployments no namespace '${namespace}'." >&2
        return 1
    fi

    if [[ "${#deployments[@]}" -eq 0 ]]; then
        echo "Nenhum deployment encontrado no namespace '${namespace}'." >&2
        return 1
    fi

    local deployment
    for deployment in "${deployments[@]}"; do
        [[ -n "${deployment}" ]] || continue
        kubectl rollout status "${deployment}" -n "${namespace}" --timeout="${timeout_seconds}s"
    done
}

wait_for_metrics_api() {
    local timeout_seconds="${1:-60}"
    local delay_seconds=5
    local attempts=$(( timeout_seconds / delay_seconds ))

    if (( attempts < 1 )); then
        attempts=1
    fi

    local attempt
    for (( attempt=1; attempt<=attempts; attempt++ )); do
        if kubectl top nodes >/dev/null 2>&1; then
            return 0
        fi

        if (( attempt < attempts )); then
            sleep "${delay_seconds}"
        fi
    done

    return 1
}

enable_metrics_server_insecure_tls() {
    local current_args=""
    current_args="$(kubectl get deployment metrics-server -n kube-system -o jsonpath='{range .spec.template.spec.containers[?(@.name=="metrics-server")].args[*]}{.}{"\n"}{end}')"

    if grep -q -- '--kubelet-insecure-tls' <<<"${current_args}"; then
        return 1
    fi

    if ! kubectl patch deployment metrics-server -n kube-system --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' >/dev/null; then
        kubectl patch deployment metrics-server -n kube-system --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/0/args","value":["--kubelet-insecure-tls"]}]' >/dev/null
    fi

    return 0
}

ensure_keda_installed() {
    local has_namespace=false
    local has_scaledobject_crd=false

    if test_kubectl_resource get namespace keda; then
        has_namespace=true
    fi

    if test_kubectl_resource get crd scaledobjects.keda.sh; then
        has_scaledobject_crd=true
    fi

    if [[ "${has_namespace}" == "true" && "${has_scaledobject_crd}" == "true" ]]; then
        echo "KEDA encontrado no cluster."
    else
        echo "KEDA nao encontrado. Instalando manifesto oficial..."
        kubectl apply --server-side -f https://github.com/kedacore/keda/releases/download/v2.19.0/keda-2.19.0.yaml
    fi

    wait_for_namespace_deployments "keda" 180
}

ensure_metrics_server_installed() {
    local has_deployment=false
    local has_apiservice=false

    if test_kubectl_resource get deployment metrics-server -n kube-system; then
        has_deployment=true
    fi

    if test_kubectl_resource get apiservice v1beta1.metrics.k8s.io; then
        has_apiservice=true
    fi

    if [[ "${has_deployment}" == "true" && "${has_apiservice}" == "true" ]]; then
        echo "Metrics Server encontrado no cluster."
    else
        echo "Metrics Server nao encontrado. Instalando manifesto oficial..."
        kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    fi

    wait_for_deployment_rollout "kube-system" "metrics-server" 180

    if ! wait_for_metrics_api 60; then
        echo "Metrics API indisponivel. Aplicando patch local com --kubelet-insecure-tls..."
        if enable_metrics_server_insecure_tls; then
            wait_for_deployment_rollout "kube-system" "metrics-server" 180
        fi

        if ! wait_for_metrics_api 120; then
            echo "Metrics API nao ficou disponivel apos instalar/configurar o Metrics Server." >&2
            return 1
        fi
    fi
}

build_local_image() {
    local root="$1"
    local image_name="$2"

    (
        cd "${root}"
        docker build -t "${image_name}:local" -f "${image_name}/Dockerfile" .
    )
}

apply_manifests() {
    local repository_dir="$1"
    shift
    local rollout_names=("$@")

    (
        cd "${repository_dir}"
        kubectl apply -k k8s/overlays/local-dev

        local deployment_name
        for deployment_name in "${rollout_names[@]}"; do
            kubectl rollout status "deployment/${deployment_name}" -n video-processor --timeout=180s
        done
    )
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
local_dev_dir="$(cd "${script_dir}/../.." && pwd)"
root="$(cd "${local_dev_dir}/.." && pwd)"
repository_base_url="https://github.com/SOAT-264"
init_script="${script_dir}/localstack-init.sh"

required_repositories=(
    "fiap-soat-video-auth"
    "fiap-soat-video-jobs"
    "fiap-soat-video-notifications"
    "fiap-soat-video-service"
    "fiap-soat-video-shared"
    "fiap-soat-video-obs"
)

declare -A repository_urls=(
    ["fiap-soat-video-auth"]="${repository_base_url}/fiap-soat-video-auth.git"
    ["fiap-soat-video-jobs"]="${repository_base_url}/fiap-soat-video-jobs.git"
    ["fiap-soat-video-notifications"]="${repository_base_url}/fiap-soat-video-notifications.git"
    ["fiap-soat-video-service"]="${repository_base_url}/fiap-soat-video-service.git"
    ["fiap-soat-video-shared"]="${repository_base_url}/fiap-soat-video-shared.git"
    ["fiap-soat-video-obs"]="${repository_base_url}/fiap-soat-video-obs.git"
)

declare -A repository_validation_paths=(
    ["fiap-soat-video-auth"]="Dockerfile"
    ["fiap-soat-video-jobs"]="Dockerfile"
    ["fiap-soat-video-notifications"]="Dockerfile"
    ["fiap-soat-video-service"]="Dockerfile"
    ["fiap-soat-video-shared"]="pyproject.toml"
    ["fiap-soat-video-obs"]="docker-compose.yml"
)

declare -A resolved_repositories=()

validate_repositories() {
    local repository
    for repository in "${required_repositories[@]}"; do
        resolved_repositories["${repository}"]="$(ensure_repository "${root}" "${repository}" "${repository_urls[${repository}]}" "${repository_validation_paths[${repository}]}")"
    done
}

compose_up() {
    (
        cd "${local_dev_dir}"
        docker compose up -d --remove-orphans
    )
}

init_localstack() {
    bash "${init_script}"
}

build_auth() {
    build_local_image "${root}" "fiap-soat-video-auth"
}

build_jobs() {
    build_local_image "${root}" "fiap-soat-video-jobs"
}

build_notifications() {
    build_local_image "${root}" "fiap-soat-video-notifications"
}

build_video_service() {
    build_local_image "${root}" "fiap-soat-video-service"
}

apply_auth() {
    apply_manifests "${resolved_repositories[fiap-soat-video-auth]}" "auth-service"
}

apply_jobs() {
    apply_manifests "${resolved_repositories[fiap-soat-video-jobs]}" "job-api-service" "job-worker"
}

apply_notifications() {
    apply_manifests "${resolved_repositories[fiap-soat-video-notifications]}" "notification-api-service" "notification-worker"
}

apply_video_service() {
    apply_manifests "${resolved_repositories[fiap-soat-video-service]}" "video-api-service"
}

reload_traefik_and_prometheus() {
    (
        cd "${local_dev_dir}"
        docker compose restart traefik prometheus
    )
}

ensure_cluster_components() {
    ensure_keda_installed
    ensure_metrics_server_installed
}

if [[ ! -f "${init_script}" ]]; then
    echo "Script de init do LocalStack nao encontrado: ${init_script}" >&2
    exit 1
fi

run_step "Validar instalacao do AWS CLI Local" ensure_awslocal
run_step "Validar repositorios locais necessarios" validate_repositories
run_step "Subir infraestrutura base no Docker Compose" compose_up
run_step "Inicializar recursos LocalStack" init_localstack
run_step "Build imagem local do auth" build_auth
run_step "Build imagem local do jobs" build_jobs
run_step "Build imagem local do notifications" build_notifications
run_step "Build imagem local do video-service" build_video_service
run_step "Garantir KEDA e Metrics Server no cluster" ensure_cluster_components
run_step "Aplicar manifests k8s do auth" apply_auth
run_step "Aplicar manifests k8s do jobs" apply_jobs
run_step "Aplicar manifests k8s do notifications" apply_notifications
run_step "Aplicar manifests k8s do video-service" apply_video_service
run_step "Recarregar Traefik e Prometheus" reload_traefik_and_prometheus

echo
echo "Ambiente pronto."
echo "- auth (k8s) health: http://auth.localhost/health"
echo "- jobs health: http://jobs.localhost/health"
echo "- notifications health: http://notify.localhost/health"
echo "- video (k8s) health: http://video.localhost/health"
echo "- grafana: http://grafana.localhost"
