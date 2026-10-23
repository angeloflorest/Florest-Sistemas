<#
.SYNOPSIS
  Publica Service e Tray AUTOCONTIDOS (o cliente não precisa instalar o .NET), Windows x64.
  Resultado: dist\app\ COMPLETA (exes, DLLs, runtimeconfig, deps) + dist\FlorestPrintAgent-<versão>-app.zip.
  A publicação é feita numa pasta temporária e só substitui dist\app depois de conferida: se algo falhar,
  a dist\app anterior continua intacta (e, depois da troca, fica guardada em dist\app.anterior).
.EXAMPLE
  .\scripts\publish.ps1
  .\scripts\publish.ps1 -NoZip
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string]$Runtime = 'win-x64',
    [switch]$NoZip
)

$ErrorActionPreference = 'Stop'

# --- pasta do script e raiz do projeto (NÃO depende de $PSScriptRoot em valores padrão de parâmetros: no Windows PowerShell 5.1
#     ele chega vazio nesse ponto quando o script é chamado com -File, e foi isso que causava o erro do Split-Path) ---
$scriptDir = $null
if ($PSScriptRoot) { $scriptDir = $PSScriptRoot }
elseif ($PSCommandPath) { $scriptDir = Split-Path -Parent $PSCommandPath }
elseif ($MyInvocation.MyCommand.Path) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
else { $scriptDir = (Get-Location).Path }
$projectRoot = Split-Path -Parent $scriptDir

Set-Location $projectRoot

$dist = Join-Path $projectRoot 'dist'
$out = Join-Path $dist 'app'
$staging = Join-Path $dist '_staging_app'

$requiredFiles = @(
    'FlorestPrintAgent.Service.exe', 'FlorestPrintAgent.Service.dll', 'FlorestPrintAgent.Service.deps.json', 'FlorestPrintAgent.Service.runtimeconfig.json',
    'FlorestPrintAgent.Tray.exe', 'FlorestPrintAgent.Tray.dll', 'FlorestPrintAgent.Tray.deps.json', 'FlorestPrintAgent.Tray.runtimeconfig.json',
    'FlorestPrintAgent.Core.dll',
    'hostfxr.dll', 'hostpolicy.dll', 'coreclr.dll', 'System.Private.CoreLib.dll',
    'Microsoft.Extensions.Hosting.dll', 'Microsoft.Extensions.Hosting.WindowsServices.dll', 'System.Text.Encoding.CodePages.dll'
)

dotnet --version | Out-Null
if ($LASTEXITCODE -ne 0) { throw "O .NET SDK 8 não foi encontrado. Instale em https://dotnet.microsoft.com/download/dotnet/8.0" }

if (Test-Path $staging) { Remove-Item -Path $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging -Force | Out-Null

function Publish-Project {
    param([string]$Project)
    Write-Host ""
    Write-Host "== Publicando $Project ($Runtime, autocontido)" -ForegroundColor Cyan
    dotnet publish $Project -c $Configuration -r $Runtime --self-contained true -o $staging
    if ($LASTEXITCODE -ne 0) { throw "Falhou a publicação de $Project" }
}

Publish-Project 'src\FlorestPrintAgent.Service\FlorestPrintAgent.Service.csproj'
Publish-Project 'src\FlorestPrintAgent.Tray\FlorestPrintAgent.Tray.csproj'

# confere a pasta COMPLETA antes de trocar a dist\app
$missing = @()
foreach ($f in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $staging $f))) { $missing += $f }
}
if ($missing.Count -gt 0) { throw "Publicação incompleta. Faltam: $($missing -join ', ')" }

$fileCount = (Get-ChildItem -Path $staging -File -Recurse | Measure-Object).Count
if ($fileCount -lt 100) { throw "Publicação suspeita: só $fileCount arquivos (esperado: o aplicativo autocontido tem centenas)." }

$version = (Get-Item -LiteralPath (Join-Path $staging 'FlorestPrintAgent.Service.exe')).VersionInfo.FileVersion
$trayVersion = (Get-Item -LiteralPath (Join-Path $staging 'FlorestPrintAgent.Tray.exe')).VersionInfo.FileVersion
if ($version -ne $trayVersion) { throw "Versões diferentes entre Service ($version) e Tray ($trayVersion)." }

# troca (rápida): a dist\app anterior fica guardada em dist\app.anterior, para voltar atrás se precisar
$previous = Join-Path $dist 'app.anterior'
if (Test-Path $previous) { Remove-Item -Path $previous -Recurse -Force }
if (Test-Path $out) { Move-Item -Path $out -Destination $previous }
Move-Item -Path $staging -Destination $out

if (-not $NoZip) {
    $zip = Join-Path $dist ("FlorestPrintAgent-{0}-app.zip" -f $version)
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Write-Host "Compactando em $zip ..." -ForegroundColor Cyan
    Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip -CompressionLevel Optimal
}

$sizeMb = [math]::Round(((Get-ChildItem -Path $out -File -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB), 1)
Write-Host ""
Write-Host "Publicado em: $out" -ForegroundColor Green
Write-Host "Versão: $version   |   $fileCount arquivos   |   $sizeMb MB" -ForegroundColor Green
Write-Host "Próximo passo (neste ou em outro computador): .\scripts\install-service.ps1 -WithTrayAutostart  (PowerShell como Administrador)"
