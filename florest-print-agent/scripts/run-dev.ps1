<#
.SYNOPSIS
  Executa o Service ou o Tray em modo de DESENVOLVIMENTO (sem instalar nada no Windows).
  Os dados ficam em .\devdata (variável FLORESTPRINTAGENT_DATA_DIR), não em ProgramData.
  Abra DUAS janelas do PowerShell: uma com -Component Service e outra com -Component Tray.
.EXAMPLE
  .\scripts\run-dev.ps1 -Component Service
  .\scripts\run-dev.ps1 -Component Tray
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Service', 'Tray')]
    [string]$Component
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = Split-Path -Parent $scriptDir
Set-Location $root

if ($Component -eq 'Service') {
    $env:FLORESTPRINTAGENT_DATA_DIR = Join-Path $root 'devdata'
    Write-Host "Dados de desenvolvimento em: $env:FLORESTPRINTAGENT_DATA_DIR" -ForegroundColor Cyan
    Write-Host "Pressione Ctrl+C para parar o serviço." -ForegroundColor Cyan
    dotnet run --project src\FlorestPrintAgent.Service\FlorestPrintAgent.Service.csproj -c Debug
}
else {
    dotnet run --project src\FlorestPrintAgent.Tray\FlorestPrintAgent.Tray.csproj -c Debug
}
