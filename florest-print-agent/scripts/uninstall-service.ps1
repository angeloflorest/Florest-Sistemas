#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Para e remove o serviço do Florest Print Agent (instalado com install-service.ps1).
  Por padrão MANTÉM os dados (identificação da instalação) e os arquivos do programa.
.EXAMPLE
  .\scripts\uninstall-service.ps1
  .\scripts\uninstall-service.ps1 -RemoveFiles
  .\scripts\uninstall-service.ps1 -RemoveFiles -RemoveData
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'Florest Sistemas\Print Agent'),
    [switch]$RemoveFiles,
    [switch]$RemoveData
)

$ErrorActionPreference = 'Stop'
$serviceName = 'FlorestPrintAgent'

Get-Process -Name 'FlorestPrintAgent.Tray' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -ne 'Stopped') {
        Write-Host "Parando o serviço..." -ForegroundColor Cyan
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        try { $svc.WaitForStatus('Stopped', '00:00:30') } catch { }
    }
    & sc.exe delete $serviceName | Out-Null
    Write-Host "Serviço removido." -ForegroundColor Green
}
else {
    Write-Host "O serviço '$serviceName' não está instalado." -ForegroundColor Yellow
}

Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'FlorestPrintAgentTray' -ErrorAction SilentlyContinue

if ($RemoveFiles -and (Test-Path $InstallDir)) {
    Start-Sleep -Seconds 1
    Remove-Item -Path $InstallDir -Recurse -Force
    Write-Host "Arquivos do programa removidos: $InstallDir" -ForegroundColor Green
}

if ($RemoveData) {
    $dataRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Florest Sistemas\Print Agent'
    if (Test-Path $dataRoot) {
        Write-Host ""
        Write-Host "ATENÇÃO: isto apaga a identificação da instalação, a credencial e os logs em:" -ForegroundColor Yellow
        Write-Host "  $dataRoot"
        $answer = Read-Host "Digite APAGAR para confirmar"
        if ($answer -ceq 'APAGAR') {
            Remove-Item -Path $dataRoot -Recurse -Force
            Write-Host "Dados removidos." -ForegroundColor Green
        }
        else {
            Write-Host "Dados mantidos." -ForegroundColor Cyan
        }
    }
}
else {
    Write-Host "Os dados em ProgramData foram mantidos (use -RemoveData para apagá-los)."
}
