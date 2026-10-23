#Requires -Version 5.1
<#
.SYNOPSIS
  Instala OU ATUALIZA o Florest Print Agent como Serviço do Windows (conta LocalSystem, início Automático).
  Copia a pasta publicada (dist\app) COMPLETA para a pasta de instalação, cria o serviço (ou atualiza o existente,
  apontando-o para a pasta de instalação), reinicia e confere se subiu. Opcionalmente registra o Tray para iniciar com o Windows.

  A identificação da instalação, a credencial e os logs ficam em ProgramData e NÃO são tocados: o computador continua
  vinculado à empresa/estação depois da atualização.

  Execute no PowerShell COMO ADMINISTRADOR:
    powershell -ExecutionPolicy Bypass -File ".\scripts\install-service.ps1" -WithTrayAutostart

.PARAMETER SourceDir
  Pasta com os arquivos publicados. Padrão: procura (nesta ordem) dist\app do projeto, a pasta do script, .\dist\app e .\app.
.PARAMETER InstallDir
  Onde instalar. Padrão: C:\Program Files\Florest Sistemas\Print Agent
.PARAMETER WithTrayAutostart
  Abre o Tray automaticamente quando qualquer usuário entrar no Windows.
.PARAMETER NoStart
  Instala/atualiza mas não inicia o serviço.
.EXAMPLE
  .\scripts\install-service.ps1
  .\scripts\install-service.ps1 -WithTrayAutostart
  .\scripts\install-service.ps1 -SourceDir "D:\entrega\app"
#>
[CmdletBinding()]
param(
    [string]$SourceDir,
    [string]$InstallDir,
    [switch]$WithTrayAutostart,
    [switch]$NoStart
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

$serviceName = 'FlorestPrintAgent'
if (-not $InstallDir) { $InstallDir = Join-Path $env:ProgramFiles 'Florest Sistemas\Print Agent' }
$serviceExe = Join-Path $InstallDir 'FlorestPrintAgent.Service.exe'
$trayExe = Join-Path $InstallDir 'FlorestPrintAgent.Tray.exe'

# arquivos que TÊM de existir na pasta publicada (aplicativo autocontido: o cliente não precisa instalar o .NET)
$requiredFiles = @(
    'FlorestPrintAgent.Service.exe', 'FlorestPrintAgent.Service.dll', 'FlorestPrintAgent.Service.deps.json', 'FlorestPrintAgent.Service.runtimeconfig.json',
    'FlorestPrintAgent.Tray.exe', 'FlorestPrintAgent.Tray.dll', 'FlorestPrintAgent.Tray.deps.json', 'FlorestPrintAgent.Tray.runtimeconfig.json',
    'FlorestPrintAgent.Core.dll',
    'hostfxr.dll', 'hostpolicy.dll', 'coreclr.dll', 'System.Private.CoreLib.dll',
    'Microsoft.Extensions.Hosting.dll', 'Microsoft.Extensions.Hosting.WindowsServices.dll', 'System.Text.Encoding.CodePages.dll'
)

function Get-MissingFiles {
    param([string]$Folder)
    $missing = @()
    foreach ($f in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $Folder $f))) { $missing += $f }
    }
    return $missing
}

# ---------------------------------------------------------------------------------------------------------------------
# 0) precisa ser Administrador
# ---------------------------------------------------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Host "Este script precisa ser executado COMO ADMINISTRADOR." -ForegroundColor Red
    Write-Host "Clique com o botão direito em 'Windows PowerShell' > 'Executar como administrador' e rode o comando de novo." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------------------------------------------------
# 1) localizar a pasta publicada
# ---------------------------------------------------------------------------------------------------------------------
$candidates = @()
if ($SourceDir) { $candidates += $SourceDir }
else {
    $candidates += (Join-Path $projectRoot 'dist\app')
    $candidates += $scriptDir
    $candidates += (Join-Path $scriptDir 'app')
    $candidates += (Join-Path (Get-Location).Path 'dist\app')
    $candidates += (Join-Path (Get-Location).Path 'app')
}

$resolvedSource = $null
foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath (Join-Path $c 'FlorestPrintAgent.Service.exe'))) { $resolvedSource = (Resolve-Path -LiteralPath $c).Path; break }
}
if (-not $resolvedSource) {
    Write-Host "Não encontrei os arquivos publicados. Procurei em:" -ForegroundColor Red
    foreach ($c in $candidates) { Write-Host "  - $c" -ForegroundColor Red }
    Write-Host "Gere a pasta com:  .\scripts\build-and-publish.ps1   (ou informe -SourceDir 'caminho\da\pasta\app')" -ForegroundColor Yellow
    exit 1
}
$missing = Get-MissingFiles -Folder $resolvedSource
if ($missing.Count -gt 0) {
    Write-Host "A pasta '$resolvedSource' está INCOMPLETA. Faltam:" -ForegroundColor Red
    foreach ($m in $missing) { Write-Host "  - $m" -ForegroundColor Red }
    Write-Host "Copie a pasta dist\app inteira (todos os arquivos, não só os .exe)." -ForegroundColor Yellow
    exit 1
}

$resolvedInstall = [System.IO.Path]::GetFullPath($InstallDir)
if ($resolvedSource.TrimEnd('\') -ieq $resolvedInstall.TrimEnd('\')) {
    Write-Host "A pasta de origem e a de instalação são a mesma ('$resolvedSource'). Informe outro -InstallDir." -ForegroundColor Red
    exit 1
}

$newVersion = (Get-Item -LiteralPath (Join-Path $resolvedSource 'FlorestPrintAgent.Service.exe')).VersionInfo.FileVersion
$oldVersion = $null
if (Test-Path -LiteralPath $serviceExe) { $oldVersion = (Get-Item -LiteralPath $serviceExe).VersionInfo.FileVersion }

Write-Host ""
Write-Host "Florest Print Agent - instalação/atualização" -ForegroundColor Cyan
Write-Host "  Origem:      $resolvedSource"
Write-Host "  Instalação:  $resolvedInstall"
Write-Host ("  Versão:      {0} -> {1}" -f $(if ($oldVersion) { $oldVersion } else { '(nova instalação)' }), $newVersion)

# ---------------------------------------------------------------------------------------------------------------------
# 2) parar o serviço e o Tray (liberar os arquivos)
# ---------------------------------------------------------------------------------------------------------------------
$existing = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($existing -and $existing.Status -ne 'Stopped') {
    Write-Host "Parando o serviço atual..." -ForegroundColor Yellow
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    try { $existing.WaitForStatus('Stopped', '00:00:30') } catch { }
}
Get-Process -Name 'FlorestPrintAgent.Service' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Name 'FlorestPrintAgent.Tray' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 800

# ---------------------------------------------------------------------------------------------------------------------
# 3) copiar a pasta INTEIRA (com 3 tentativas: antivírus/Explorer podem segurar um arquivo por um instante)
# ---------------------------------------------------------------------------------------------------------------------
Write-Host "Copiando arquivos..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path $resolvedInstall -Force | Out-Null
$copied = $false
for ($attempt = 1; $attempt -le 3 -and -not $copied; $attempt++) {
    try {
        Copy-Item -Path (Join-Path $resolvedSource '*') -Destination $resolvedInstall -Recurse -Force
        $copied = $true
    }
    catch {
        if ($attempt -ge 3) { throw "Não foi possível copiar os arquivos para '$resolvedInstall': $($_.Exception.Message)" }
        Write-Host "  arquivo em uso; tentando de novo ($attempt/3)..." -ForegroundColor Yellow
        Start-Sleep -Seconds 2
    }
}
$missingAfter = Get-MissingFiles -Folder $resolvedInstall
if ($missingAfter.Count -gt 0) { throw "A cópia ficou incompleta. Faltam: $($missingAfter -join ', ')" }

# ---------------------------------------------------------------------------------------------------------------------
# 4) criar o serviço, ou atualizar o existente (mesmo nome, mesma conta) apontando para a pasta de instalação
# ---------------------------------------------------------------------------------------------------------------------
$binaryPath = '"' + $serviceExe + '"'
if (-not $existing) {
    Write-Host "Criando o serviço '$serviceName'..." -ForegroundColor Cyan
    New-Service -Name $serviceName `
        -BinaryPathName $binaryPath `
        -DisplayName 'Florest Print Agent' `
        -Description 'Mantém este computador conectado ao Florest ERP, informa as impressoras e imprime os pedidos do Bar/Cozinha.' `
        -StartupType Automatic `
        -DependsOn 'Spooler' | Out-Null
}
else {
    Write-Host "Atualizando o serviço existente '$serviceName'..." -ForegroundColor Cyan
    $svcCim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'"
    $change = Invoke-CimMethod -InputObject $svcCim -MethodName Change -Arguments @{ PathName = $binaryPath; DisplayName = 'Florest Print Agent' }
    if ($change.ReturnValue -ne 0) { throw "Não foi possível atualizar o caminho do serviço (código $($change.ReturnValue))." }
    & sc.exe description $serviceName 'Mantém este computador conectado ao Florest ERP, informa as impressoras e imprime os pedidos do Bar/Cozinha.' | Out-Null
    # depende do spooler de impressão (o agente só precisa dele)
    & sc.exe config $serviceName depend= Spooler | Out-Null
}

# Início Automático (também desfaz o "atrasado" de instalações antigas: o agente precisa estar de pé logo após ligar o PC)
& sc.exe config $serviceName start= auto | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Não foi possível configurar o início automático (sc.exe config, código $LASTEXITCODE)." }

# Reinicia sozinho se falhar (5 s, 5 s e depois 30 s); zera a contagem após 1 dia
& sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/5000/restart/30000 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Não foi possível configurar a recuperação automática (sc.exe failure, código $LASTEXITCODE)." }
& sc.exe failureflag $serviceName 1 | Out-Null

# ---------------------------------------------------------------------------------------------------------------------
# 5) Tray no início do Windows (opcional)
# ---------------------------------------------------------------------------------------------------------------------
if ($WithTrayAutostart) {
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' `
        -Name 'FlorestPrintAgentTray' `
        -Value ('"{0}" --minimized' -f $trayExe) `
        -PropertyType String -Force | Out-Null
    Write-Host "Tray configurado para iniciar com o Windows." -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------------------------------------------------
# 6) iniciar e conferir
# ---------------------------------------------------------------------------------------------------------------------
if ($NoStart) {
    Write-Host "Serviço instalado e NÃO iniciado (-NoStart)." -ForegroundColor Yellow
}
else {
    Start-Service -Name $serviceName
    $svc = Get-Service -Name $serviceName
    try { $svc.WaitForStatus('Running', '00:00:30') } catch { }
    Start-Sleep -Seconds 2
}

Get-Service -Name $serviceName | Format-Table Name, Status, StartType -AutoSize
$final = Get-Service -Name $serviceName
if (-not $NoStart -and $final.Status -ne 'Running') {
    Write-Host "O serviço NÃO está em execução. Veja os logs abaixo e o Visualizador de Eventos." -ForegroundColor Red
    exit 2
}

$common = [Environment]::GetFolderPath('CommonApplicationData')
Write-Host ""
Write-Host "Pronto. Versão instalada: $((Get-Item -LiteralPath $serviceExe).VersionInfo.FileVersion)" -ForegroundColor Green
Write-Host "Dados (mantidos): $common\Florest Sistemas\Print Agent\data   (somente Administradores/SYSTEM)"
Write-Host "Logs:             $common\Florest Sistemas\Print Agent\logs"
Write-Host "Abra o Tray (como usuário comum):  & '$trayExe'"
