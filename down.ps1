$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$entrypoint = Join-Path $PSScriptRoot "scripts\windows\down.ps1"

if (-not (Test-Path $entrypoint)) {
    throw "Script principal nao encontrado: $entrypoint"
}

& $entrypoint @args
