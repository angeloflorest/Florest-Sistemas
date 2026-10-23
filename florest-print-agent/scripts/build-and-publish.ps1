<#
.SYNOPSIS
  Um comando só: restaura, compila, roda os testes e publica a dist\app completa (autocontida, win-x64).
.EXAMPLE
  .\scripts\build-and-publish.ps1
  .\scripts\build-and-publish.ps1 -SkipTests
#>
[CmdletBinding()]
param(
    [switch]$SkipTests,
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

if ($SkipTests) { & (Join-Path $scriptDir 'build.ps1') -SkipTests } else { & (Join-Path $scriptDir 'build.ps1') }
if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "build.ps1 falhou (código $LASTEXITCODE)" }

if ($NoZip) { & (Join-Path $scriptDir 'publish.ps1') -NoZip } else { & (Join-Path $scriptDir 'publish.ps1') }
if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "publish.ps1 falhou (código $LASTEXITCODE)" }
