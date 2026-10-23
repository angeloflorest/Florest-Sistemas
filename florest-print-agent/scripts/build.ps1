<#
.SYNOPSIS
  Restaura, compila e (opcionalmente) testa a solution inteira.
.EXAMPLE
  .\scripts\build.ps1
  .\scripts\build.ps1 -SkipTests
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = Split-Path -Parent $scriptDir
Set-Location $root

function Invoke-Step {
    param([string]$Title, [scriptblock]$Action)
    Write-Host ""
    Write-Host "== $Title" -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "Falhou: $Title (código $LASTEXITCODE)" }
}

Write-Host "SDK do .NET em uso:" -ForegroundColor Cyan
dotnet --version
if ($LASTEXITCODE -ne 0) { throw "O .NET SDK 8 não foi encontrado. Instale em https://dotnet.microsoft.com/download/dotnet/8.0" }

Invoke-Step 'Restaurar pacotes' { dotnet restore FlorestPrintAgent.sln }
Invoke-Step "Compilar ($Configuration)" { dotnet build FlorestPrintAgent.sln -c $Configuration --no-restore }

if (-not $SkipTests) {
    Invoke-Step 'Executar testes' { dotnet test tests\FlorestPrintAgent.Tests\FlorestPrintAgent.Tests.csproj -c $Configuration --no-build }
}

Write-Host ""
Write-Host "Concluído com sucesso." -ForegroundColor Green
