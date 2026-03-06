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
$authDir = Join-Path $root "fiap-soat-video-auth"
$jobsDir = Join-Path $root "fiap-soat-video-jobs"
$notificationsDir = Join-Path $root "fiap-soat-video-notifications"
$videoDir = Join-Path $root "fiap-soat-video-service"
$initScript = Join-Path $localDevDir "init-scripts\localstack-init.ps1"

if (-not (Test-Path $authDir)) {
    throw "Diretorio do auth nao encontrado: $authDir"
}

if (-not (Test-Path $jobsDir)) {
    throw "Diretorio do jobs nao encontrado: $jobsDir"
}

if (-not (Test-Path $notificationsDir)) {
    throw "Diretorio do notifications nao encontrado: $notificationsDir"
}

if (-not (Test-Path $videoDir)) {
    throw "Diretorio do video-service nao encontrado: $videoDir"
}

if (-not (Test-Path $initScript)) {
    throw "Script de init do LocalStack nao encontrado: $initScript"
}

Push-Location $localDevDir
try {
    Run-Step -Name "Subir infraestrutura base no Docker Compose" -Action {
        docker compose up -d --remove-orphans
    }

    Run-Step -Name "Inicializar recursos LocalStack" -Action {
        & $initScript
    }

    Run-Step -Name "Build imagem local do auth" -Action {
        Push-Location $root
        try {
            docker build -t fiap-soat-video-auth:local -f fiap-soat-video-auth/Dockerfile .
        }
        finally {
            Pop-Location
        }
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

    Run-Step -Name "Build imagem local do video-service" -Action {
        Push-Location $root
        try {
            docker build -t fiap-soat-video-service:local -f fiap-soat-video-service/Dockerfile .
        }
        finally {
            Pop-Location
        }
    }

    Run-Step -Name "Aplicar manifests k8s do auth" -Action {
        Push-Location $authDir
        try {
            kubectl apply -k k8s/overlays/local-dev
            kubectl rollout status deployment/auth-service -n video-processor --timeout=180s
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

    Run-Step -Name "Aplicar manifests k8s do video-service" -Action {
        Push-Location $videoDir
        try {
            kubectl apply -k k8s/overlays/local-dev
            kubectl rollout status deployment/video-api-service -n video-processor --timeout=180s
        }
        finally {
            Pop-Location
        }
    }

    Run-Step -Name "Recarregar Traefik e Prometheus" -Action {
        docker compose restart traefik prometheus
    }

    Write-Host "`nAmbiente pronto." -ForegroundColor Green
    Write-Host "- auth (k8s) health: http://auth.localhost/health"
    Write-Host "- jobs health: http://jobs.localhost/health"
    Write-Host "- notifications health: http://notify.localhost/health"
    Write-Host "- video (k8s) health: http://video.localhost/health"
    Write-Host "- grafana: http://grafana.localhost"
}
finally {
    Pop-Location
}
