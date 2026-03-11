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

function Ensure-Repository {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$ValidationPath
    )

    $repoDir = Join-Path $Root $Name
    $repoValidationPath = Join-Path $repoDir $ValidationPath

    if (Test-Path $repoDir) {
        if (-not (Test-Path $repoDir -PathType Container)) {
            throw "Caminho esperado para o repositorio '$Name' nao e um diretorio: $repoDir"
        }

        if (-not (Test-Path $repoValidationPath)) {
            throw "Diretorio existente para '$Name' sem estrutura esperada. Arquivo/pasta obrigatorio ausente: $repoValidationPath"
        }

        Write-Host "Repositorio encontrado: $Name" -ForegroundColor DarkGray
        return $repoDir
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git nao encontrado no PATH. Instale/configure o Git para clonar o repositorio ausente '$Name'."
    }

    Write-Host "Repositorio ausente: $Name. Clonando de $Url" -ForegroundColor Yellow
    git clone $Url $repoDir

    if (-not (Test-Path $repoValidationPath)) {
        throw "Clone de '$Name' concluido, mas a estrutura esperada nao foi encontrada em: $repoValidationPath"
    }

    return $repoDir
}

function Ensure-AwsLocal {
    if (Get-Command awslocal -ErrorAction SilentlyContinue) {
        return
    }

    $installCommand = "pip install awscli-local"
    throw "Comando 'awslocal' nao encontrado no PATH. Instale o AWS CLI Local antes de continuar. Exemplo: $installCommand"
}

$localDevDir = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$root = Split-Path -Parent $localDevDir
$repositoryBaseUrl = "https://github.com/SOAT-264"
$requiredRepositories = @(
    @{ Name = "fiap-soat-video-auth"; Url = "$repositoryBaseUrl/fiap-soat-video-auth.git"; ValidationPath = "Dockerfile" },
    @{ Name = "fiap-soat-video-jobs"; Url = "$repositoryBaseUrl/fiap-soat-video-jobs.git"; ValidationPath = "Dockerfile" },
    @{ Name = "fiap-soat-video-notifications"; Url = "$repositoryBaseUrl/fiap-soat-video-notifications.git"; ValidationPath = "Dockerfile" },
    @{ Name = "fiap-soat-video-service"; Url = "$repositoryBaseUrl/fiap-soat-video-service.git"; ValidationPath = "Dockerfile" },
    @{ Name = "fiap-soat-video-shared"; Url = "$repositoryBaseUrl/fiap-soat-video-shared.git"; ValidationPath = "pyproject.toml" },
    @{ Name = "fiap-soat-video-obs"; Url = "$repositoryBaseUrl/fiap-soat-video-obs.git"; ValidationPath = "docker-compose.yml" }
)
$initScript = Join-Path $PSScriptRoot "localstack-init.ps1"
$resolvedRepositories = @{}

Run-Step -Name "Validar instalacao do AWS CLI Local" -Action {
    Ensure-AwsLocal
}

Run-Step -Name "Validar repositorios locais necessarios" -Action {
    foreach ($repository in $requiredRepositories) {
        $resolvedRepositories[$repository.Name] = Ensure-Repository `
            -Root $root `
            -Name $repository.Name `
            -Url $repository.Url `
            -ValidationPath $repository.ValidationPath
    }
}

$authDir = [string]$resolvedRepositories["fiap-soat-video-auth"]
$jobsDir = [string]$resolvedRepositories["fiap-soat-video-jobs"]
$notificationsDir = [string]$resolvedRepositories["fiap-soat-video-notifications"]
$videoDir = [string]$resolvedRepositories["fiap-soat-video-service"]

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
