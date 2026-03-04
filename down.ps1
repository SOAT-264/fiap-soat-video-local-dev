param(
    [switch]$PurgeData
)

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

$localDevDir = $PSScriptRoot

Push-Location $localDevDir
try {
    Run-Step -Name "Remover namespace do jobs no Kubernetes" -Action {
        kubectl delete namespace video-processor --ignore-not-found=true
    }

    if ($PurgeData) {
        Run-Step -Name "Derrubar Docker Compose removendo volumes e dados" -Action {
            docker compose down -v --remove-orphans
        }
    }
    else {
        Run-Step -Name "Derrubar Docker Compose mantendo volumes" -Action {
            docker compose down --remove-orphans
        }
    }

    Write-Host "`nAmbiente derrubado com sucesso." -ForegroundColor Green
    if ($PurgeData) {
        Write-Host "- Volumes removidos"
    }
    else {
        Write-Host "- Volumes preservados (use -PurgeData para limpeza total)"
    }
}
finally {
    Pop-Location
}
