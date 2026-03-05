$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Run-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    Write-Host "`n==> $Name" -ForegroundColor Cyan
    & $Action
    Write-Host "OK: $Name" -ForegroundColor Green
}

$root = Split-Path -Parent $PSScriptRoot
$localDevDir = $PSScriptRoot
$jobsDir = Join-Path $root "fiap-soat-video-jobs"
$notificationsDir = Join-Path $root "fiap-soat-video-notifications"
$initScript = Join-Path $localDevDir "init-scripts\localstack-init.ps1"

if (-not (Test-Path $jobsDir)) {
    throw "Diretorio do jobs nao encontrado: $jobsDir"
}

if (-not (Test-Path $notificationsDir)) {
    throw "Diretorio do notifications nao encontrado: $notificationsDir"
}

if (-not (Test-Path $initScript)) {
    throw "Script de init do LocalStack nao encontrado: $initScript"
}

Push-Location $localDevDir
try {
    Run-Step -Name "Subir Docker Compose" -Action {
        docker compose up -d
    }

    Run-Step -Name "Desativar notifications no Docker Compose (usaremos Kubernetes)" -Action {
        docker compose stop notification-service notification-worker
    }

    Run-Step -Name "Inicializar recursos LocalStack" -Action {
        & $initScript
    }

    Run-Step -Name "Build imagem local do jobs" -Action {
        Push-Location $root
        try {
            docker build -t fiap-soat-video-jobs:local -f fiap-soat-video-jobs/Dockerfile .
        }
        finally {
            Pop-Location
        }
    }

    Run-Step -Name "Build imagem local do notifications" -Action {
        Push-Location $root
        try {
            docker build -t fiap-soat-video-notifications:local -f fiap-soat-video-notifications/Dockerfile .
        }
        finally {
            Pop-Location
        }
    }

    Run-Step -Name "Aplicar manifests k8s do jobs" -Action {
        Push-Location $jobsDir
        try {
            kubectl apply -k k8s/overlays/local-dev
            kubectl rollout status deployment/job-api-service -n video-processor --timeout=180s
            kubectl rollout status deployment/job-worker -n video-processor --timeout=180s
        }
        finally {
            Pop-Location
        }
    }

    Run-Step -Name "Aplicar manifests k8s do notifications" -Action {
        Push-Location $notificationsDir
        try {
            kubectl apply -k k8s/overlays/local-dev
            kubectl rollout status deployment/notification-api-service -n video-processor --timeout=180s
            kubectl rollout status deployment/notification-worker -n video-processor --timeout=180s
        }
        finally {
            Pop-Location
        }
    }

    Run-Step -Name "Recarregar Traefik e Prometheus" -Action {
        docker compose restart traefik prometheus
    }

    Write-Host "`nAmbiente pronto." -ForegroundColor Green
    Write-Host "- jobs health: http://jobs.localhost/health"
    Write-Host "- notifications health: http://notify.localhost/health"
    Write-Host "- grafana: http://grafana.localhost"
}
finally {
    Pop-Location
}
