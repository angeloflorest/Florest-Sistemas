<#
.SYNOPSIS
  Gera o instalador (Setup.exe) com o Inno Setup 6.3 ou mais novo (gratuito). Antes, rode .\scripts\publish.ps1
  (ou use .\scripts\build-setup.ps1, que faz tudo de uma vez).
  Resultado: dist\installer\FlorestPrintAgent-Setup-<versão>.exe
.EXAMPLE
  .\scripts\build-installer.ps1
  .\scripts\build-installer.ps1 -IsccPath "D:\Tools\Inno Setup 6\ISCC.exe"
#>
[CmdletBinding()]
param(
    [string]$IsccPath
)

$ErrorActionPreference = 'Stop'

# --- pasta do script e raiz do projeto (NÃO depende de $PSScriptRoot em valores padrão de parâmetros: no Windows PowerShell 5.1
#     ele chega vazio nesse ponto quando o script é chamado com -File) ---
$scriptDir = $null
if ($PSScriptRoot) { $scriptDir = $PSScriptRoot }
elseif ($PSCommandPath) { $scriptDir = Split-Path -Parent $PSCommandPath }
elseif ($MyInvocation.MyCommand.Path) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
else { $scriptDir = (Get-Location).Path }
$root = Split-Path -Parent $scriptDir
Set-Location $root

$app = Join-Path $root 'dist\app'
$requiredFiles = @(
    'FlorestPrintAgent.Service.exe', 'FlorestPrintAgent.Service.dll', 'FlorestPrintAgent.Service.deps.json', 'FlorestPrintAgent.Service.runtimeconfig.json',
    'FlorestPrintAgent.Tray.exe', 'FlorestPrintAgent.Tray.dll', 'FlorestPrintAgent.Tray.deps.json', 'FlorestPrintAgent.Tray.runtimeconfig.json',
    'FlorestPrintAgent.Core.dll',
    'hostfxr.dll', 'hostpolicy.dll', 'coreclr.dll', 'System.Private.CoreLib.dll',
    'Microsoft.Extensions.Hosting.dll', 'Microsoft.Extensions.Hosting.WindowsServices.dll', 'System.Text.Encoding.CodePages.dll'
)
$missing = @()
foreach ($f in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $app $f))) { $missing += $f }
}
if ($missing.Count -gt 0) {
    throw "dist\app não existe ou está incompleta (faltam: $($missing -join ', ')). Rode antes: .\scripts\publish.ps1"
}

# a versão do programa publicado tem de ser a do instalador (senão o Setup se anuncia com um número e instala outro)
$iss = Join-Path $root 'installer\FlorestPrintAgent.iss'
$issText = Get-Content -LiteralPath $iss -Raw -Encoding UTF8
$m = [regex]::Match($issText, '#define AppVersion "([^"]+)"')
if (-not $m.Success) { throw "Não achei #define AppVersion em $iss" }
$issVersion = $m.Groups[1].Value
$exeVersion = (Get-Item -LiteralPath (Join-Path $app 'FlorestPrintAgent.Service.exe')).VersionInfo.FileVersion
if (-not $exeVersion.StartsWith($issVersion)) {
    throw "Versão do programa publicado ($exeVersion) diferente da do instalador ($issVersion). Rode .\scripts\publish.ps1 de novo."
}

if (-not $IsccPath) {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { $IsccPath = $c; break }
    }
}
if (-not $IsccPath -or -not (Test-Path $IsccPath)) {
    throw "Inno Setup não encontrado. Instale o Inno Setup 6.3 ou mais novo (gratuito: https://jrsoftware.org/isdl.php) e rode de novo, ou informe -IsccPath."
}

Write-Host "Compilando o instalador com: $IsccPath" -ForegroundColor Cyan
& $IsccPath $iss
if ($LASTEXITCODE -ne 0) { throw "O Inno Setup retornou erro $LASTEXITCODE" }

$setup = Join-Path $root ("dist\installer\FlorestPrintAgent-Setup-{0}.exe" -f $issVersion)
if (-not (Test-Path -LiteralPath $setup)) { throw "O Inno Setup terminou sem erro, mas não achei $setup" }
$hash = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash
$sizeMb = [math]::Round(((Get-Item -LiteralPath $setup).Length / 1MB), 1)

Write-Host ""
Write-Host "Instalador gerado: $setup" -ForegroundColor Green
Write-Host "Tamanho: $sizeMb MB   |   SHA-256: $hash"
Write-Host "Execute-o como Administrador no computador do cliente. Depois da instalação ele pode ser apagado."
