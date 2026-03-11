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

function Test-KubectlResource {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    & kubectl @Arguments *> $null
    return $LASTEXITCODE -eq 0
}

function Wait-ForDeploymentRollout {
    param(
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutSeconds = 180
    )

    kubectl rollout status "deployment/$Name" -n $Namespace --timeout="$($TimeoutSeconds)s"
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao aguardar rollout do deployment '$Name' no namespace '$Namespace'."
    }
}

function Wait-ForNamespaceDeployments {
    param(
        [Parameter(Mandatory = $true)][string]$Namespace,
        [int]$TimeoutSeconds = 180
    )

    $deployments = @(& kubectl get deployment -n $Namespace -o name 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao listar deployments no namespace '$Namespace'."
    }

    $deployments = @($deployments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($deployments.Count -eq 0) {
        throw "Nenhum deployment encontrado no namespace '$Namespace'."
    }

    foreach ($deployment in $deployments) {
        kubectl rollout status $deployment -n $Namespace --timeout="$($TimeoutSeconds)s"
        if ($LASTEXITCODE -ne 0) {
            throw "Falha ao aguardar rollout de '$deployment' no namespace '$Namespace'."
        }
    }
}

function Wait-ForMetricsApi {
    param(
        [int]$TimeoutSeconds = 60
    )

    $delaySeconds = 5
    $attempts = [Math]::Max([int][Math]::Ceiling($TimeoutSeconds / $delaySeconds), 1)

    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        kubectl top nodes *> $null
        if ($LASTEXITCODE -eq 0) {
            return $true
        }

        if ($attempt -lt $attempts) {
            Start-Sleep -Seconds $delaySeconds
        }
    }

    return $false
}

function Enable-MetricsServerInsecureTls {
    $deploymentJson = & kubectl get deployment metrics-server -n kube-system -o json
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao obter deployment 'metrics-server' no namespace 'kube-system'."
    }

    $deployment = $deploymentJson | ConvertFrom-Json
    $container = @($deployment.spec.template.spec.containers | Where-Object { $_.name -eq "metrics-server" }) | Select-Object -First 1
    if ($null -eq $container) {
        throw "Container 'metrics-server' nao encontrado no deployment 'metrics-server'."
    }

    $currentArgs = @()
    if ($null -ne $container.args) {
        $currentArgs = @($container.args)
    }

    if ($currentArgs -contains "--kubelet-insecure-tls") {
        return $false
    }

    $patchObject = @{
        spec = @{
            template = @{
                spec = @{
                    containers = @(
                        @{
                            name = "metrics-server"
                            image = [string]$container.image
                            args = @($currentArgs + "--kubelet-insecure-tls")
                        }
                    )
                }
            }
        }
    }

    $patchFile = [System.IO.Path]::GetTempFileName()
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    try {
        [System.IO.File]::WriteAllText($patchFile, ($patchObject | ConvertTo-Json -Depth 20), $utf8NoBom)
        kubectl patch deployment metrics-server -n kube-system --type strategic --patch-file $patchFile
        if ($LASTEXITCODE -ne 0) {
            throw "Falha ao aplicar patch com --kubelet-insecure-tls no Metrics Server."
        }
    }
    finally {
        Remove-Item $patchFile -ErrorAction SilentlyContinue
    }

    return $true
}

function Ensure-KedaInstalled {
    $hasNamespace = Test-KubectlResource -Arguments @("get", "namespace", "keda")
    $hasScaledObjectCrd = Test-KubectlResource -Arguments @("get", "crd", "scaledobjects.keda.sh")

    if ($hasNamespace -and $hasScaledObjectCrd) {
        Write-Host "KEDA encontrado no cluster." -ForegroundColor DarkGray
    }
    else {
        Write-Host "KEDA nao encontrado. Instalando manifesto oficial..." -ForegroundColor Yellow
        kubectl apply --server-side -f https://github.com/kedacore/keda/releases/download/v2.19.0/keda-2.19.0.yaml
        if ($LASTEXITCODE -ne 0) {
            throw "Falha ao instalar o KEDA."
        }
    }

    Wait-ForNamespaceDeployments -Namespace "keda" -TimeoutSeconds 180
}

function Ensure-MetricsServerInstalled {
    $hasDeployment = Test-KubectlResource -Arguments @("get", "deployment", "metrics-server", "-n", "kube-system")
    $hasApiService = Test-KubectlResource -Arguments @("get", "apiservice", "v1beta1.metrics.k8s.io")

    if ($hasDeployment -and $hasApiService) {
        Write-Host "Metrics Server encontrado no cluster." -ForegroundColor DarkGray
    }
    else {
        Write-Host "Metrics Server nao encontrado. Instalando manifesto oficial..." -ForegroundColor Yellow
        kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
        if ($LASTEXITCODE -ne 0) {
            throw "Falha ao instalar o Metrics Server."
        }
    }

    Wait-ForDeploymentRollout -Namespace "kube-system" -Name "metrics-server" -TimeoutSeconds 180

    if (-not (Wait-ForMetricsApi -TimeoutSeconds 60)) {
        Write-Host "Metrics API indisponivel. Aplicando patch local com --kubelet-insecure-tls..." -ForegroundColor Yellow
        $patched = Enable-MetricsServerInsecureTls

        if ($patched) {
            Wait-ForDeploymentRollout -Namespace "kube-system" -Name "metrics-server" -TimeoutSeconds 180
        }

        if (-not (Wait-ForMetricsApi -TimeoutSeconds 120)) {
            throw "Metrics API nao ficou disponivel apos instalar/configurar o Metrics Server."
        }
    }
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

    Run-Step -Name "Garantir KEDA e Metrics Server no cluster" -Action {
        Ensure-KedaInstalled
        Ensure-MetricsServerInstalled
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
