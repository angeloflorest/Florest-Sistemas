<#
.SYNOPSIS
  Um comando só para chegar ao instalador: restaura, compila, roda os testes, publica a dist\app completa (autocontida, win-x64)
  e gera dist\installer\FlorestPrintAgent-Setup-<versão>.exe com o Inno Setup.
.EXAMPLE
  .\scripts\build-setup.ps1
  .\scripts\build-setup.ps1 -SkipTests
#>
[CmdletBinding()]
param(
    [switch]$SkipTests,
    [string]$IsccPath
)

$ErrorActionPreference = 'Stop'

$scriptDir = $null
if ($PSScriptRoot) { $scriptDir = $PSScriptRoot }
elseif ($PSCommandPath) { $scriptDir = Split-Path -Parent $PSCommandPath }
elseif ($MyInvocation.MyCommand.Path) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
else { $scriptDir = (Get-Location).Path }

if ($SkipTests) { & (Join-Path $scriptDir 'build-and-publish.ps1') -SkipTests } else { & (Join-Path $scriptDir 'build-and-publish.ps1') }
if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "build-and-publish.ps1 falhou (código $LASTEXITCODE)" }

if ($IsccPath) { & (Join-Path $scriptDir 'build-installer.ps1') -IsccPath $IsccPath } else { & (Join-Path $scriptDir 'build-installer.ps1') }
if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "build-installer.ps1 falhou (código $LASTEXITCODE)" }
