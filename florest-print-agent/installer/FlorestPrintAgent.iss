; =====================================================================================================
; Florest Print Agent - instalador (Inno Setup 6.3 ou mais novo, gratuito: https://jrsoftware.org/isdl.php)
;
; STATUS: finalizado para compilação, mas NÃO compilado nem testado neste ambiente (que não tem Windows nem Inno Setup).
; Para gerar o instalador:   .\scripts\build-setup.ps1      (compila, testa, publica a dist\app e gera o Setup.exe)
;                       ou:  .\scripts\publish.ps1  e depois  .\scripts\build-installer.ps1
; Resultado: dist\installer\FlorestPrintAgent-Setup-1.2.0.exe
;
; INSTALAR UMA VEZ. O que o instalador faz (executar como Administrador):
;   1. detecta instalação anterior (mesmo AppId = atualização no lugar) e recusa, sem confirmação, trocar por versão MAIS ANTIGA;
;   2. fecha o Tray e PARA o serviço (se ficar travado, encerra o processo);
;   3. copia o programa (autocontido, não exige .NET) para "Arquivos de Programas\Florest Sistemas\Print Agent";
;   4. NÃO toca em ProgramData: identidade da instalação, vínculo (empresa/estação), credencial protegida, diário de impressões,
;      configuração e logs continuam como estavam => NÃO precisa parear de novo a cada atualização;
;   5. cria o Serviço do Windows "FlorestPrintAgent" (LocalSystem, início AUTOMÁTICO, depende do Spooler) ou ATUALIZA o existente;
;   6. configura a recuperação automática (reinicia 5 s, 5 s e 30 s depois de cada falha; zera a contagem após 1 dia);
;   7. inicia o serviço e confere se ele ficou "em execução";
;   8. registra o Tray para iniciar no login de qualquer usuário (--minimized) e o abre ao final para o primeiro pareamento;
;   9. cria o desinstalador e aparece em "Aplicativos instalados" do Windows.
;
; DESINSTALAÇÃO: para e remove o serviço, remove o autostart do Tray e os binários. ProgramData (identidade, vínculo, credencial,
; diário e logs) só é apagada se o usuário confirmar na pergunta final, ou se o desinstalador receber /PURGEDATA.
;
; Por que início AUTOMÁTICO e não "automático (atrasado)": o agente NÃO depende de a internet já estar de pé (se o roteador ainda
; não respondeu ele continua vivo, registra "sem conexão" e tenta de novo com espera crescente), então iniciar logo no boot é melhor:
; o primeiro pedido depois de ligar o computador não espera o atraso de ~2 minutos do início atrasado.
;
; ASSINATURA DE CÓDIGO: não há certificado neste momento. Quando houver, descomente SignTool/SignedUninstaller
; abaixo e cadastre a ferramenta no Inno Setup (Tools > Configure Sign Tools) com o nome "florestsign".
;
; Instalação silenciosa (suporte):   FlorestPrintAgent-Setup-1.2.0.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
; Desinstalação total (explícita):   "C:\Program Files\Florest Sistemas\Print Agent\unins000.exe" /VERYSILENT /PURGEDATA
; =====================================================================================================

#define AppName "Florest Print Agent"
#define AppVersion "1.2.0"
#define AppPublisher "Florest Sistemas"
#define ServiceName "FlorestPrintAgent"
#define ServiceExe "FlorestPrintAgent.Service.exe"
#define TrayExe "FlorestPrintAgent.Tray.exe"

[Setup]
; NÃO mude o AppId: é ele que faz a versão nova atualizar a antiga no lugar (1.1.0 -> 1.2.0 -> 1.3.0 ...).
AppId={{5D0B7C0E-6F1A-4C5B-9B7E-7A2E3D9F4A11}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
VersionInfoVersion={#AppVersion}
VersionInfoCompany={#AppPublisher}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} - instalador
DefaultDirName={autopf}\Florest Sistemas\Print Agent
UsePreviousAppDir=yes
DefaultGroupName=Florest Sistemas
DisableProgramGroupPage=yes
OutputDir=..\dist\installer
OutputBaseFilename=FlorestPrintAgent-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
UninstallDisplayIcon={app}\{#TrayExe}
UninstallDisplayName={#AppName}
CloseApplications=no
RestartIfNeededByRun=no
SetupLogging=yes
; Descomente quando houver certificado de assinatura:
; SignTool=florestsign $f
; SignedUninstaller=yes

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Files]
Source: "..\dist\app\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Dirs]
; as permissões (SYSTEM e Administradores) são aplicadas pelo serviço na primeira execução.
; uninsneveruninstall: o desinstalador NUNCA remove esta pasta por conta própria (identidade, credencial e logs são
; preservados por padrão, inclusive em atualização); só é apagada se o usuário aceitar na pergunta final da desinstalação
; ou se o desinstalador receber /PURGEDATA.
Name: "{commonappdata}\Florest Sistemas\Print Agent"; Flags: uninsneveruninstall

[Icons]
Name: "{group}\Florest Print Agent"; Filename: "{app}\{#TrayExe}"

[Registry]
; Tray inicia com o Windows (em cada sessão de usuário), apenas com o ícone. O motor (serviço) NÃO depende dele.
Root: HKLM; Subkey: "SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "FlorestPrintAgentTray"; ValueData: """{app}\{#TrayExe}"" --minimized"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#TrayExe}"; Description: "Abrir o Florest Print Agent agora (para vincular esta empresa/estação)"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
const
  ServiceNameConst = '{#ServiceName}';
  UninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{5D0B7C0E-6F1A-4C5B-9B7E-7A2E3D9F4A11}_is1';

function RunSc(const Params: String): Integer;
var
  ResultCode: Integer;
begin
  if not Exec(ExpandConstant('{sys}\sc.exe'), Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    ResultCode := -1;
  Result := ResultCode;
end;

procedure KillProcess(const ImageName: String);
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM ' + ImageName, '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure KillTray();
begin
  KillProcess('{#TrayExe}');
end;

function ServiceExists(): Boolean;
begin
  // "sc query" termina com 1060 (ERROR_SERVICE_DOES_NOT_EXIST) quando o serviço não existe
  Result := (RunSc('query ' + ServiceNameConst) <> 1060);
end;

function ServiceHasState(const StateName: String): Boolean;
var
  ResultCode: Integer;
begin
  Result := False;
  if Exec(ExpandConstant('{cmd}'), '/C sc query ' + ServiceNameConst + ' | find "' + StateName + '" >nul 2>&1', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := (ResultCode = 0);
end;

function ServiceIsStopped(): Boolean;
begin
  // Parado = "sc query" mostra STOPPED, OU o serviço nem existe. Qualquer outro estado (RUNNING, START_PENDING,
  // STOP_PENDING...) conta como "ainda não parou".
  Result := (not ServiceExists()) or ServiceHasState('STOPPED');
end;

function ServiceIsRunning(): Boolean;
begin
  Result := ServiceHasState('RUNNING');
end;

procedure StopServiceAndWait();
var
  I: Integer;
begin
  if not ServiceExists() then Exit;
  RunSc('stop ' + ServiceNameConst);
  // espera até 30 s o serviço parar de verdade (em vez de um tempo fixo)
  for I := 1 to 30 do
  begin
    if ServiceIsStopped() then Break;
    Sleep(1000);
  end;
  if not ServiceIsStopped() then
  begin
    // travado: encerra o processo para liberar os arquivos
    KillProcess('{#ServiceExe}');
    Sleep(2000);
  end;
end;

procedure DeleteServiceAndWait();
var
  I: Integer;
begin
  if not ServiceExists() then Exit;
  RunSc('delete ' + ServiceNameConst);
  for I := 1 to 15 do
  begin
    if not ServiceExists() then Break;
    Sleep(1000);
  end;
end;

procedure InstallOrUpdateService();
var
  BinPath: String;
  Code, Attempt: Integer;
begin
  BinPath := '"' + ExpandConstant('{app}\{#ServiceExe}') + '"';
  Code := -1;

  if ServiceExists() then
  begin
    // ATUALIZAÇÃO: o serviço já existe (instalado por versão anterior, pelo install-service.ps1 ou manualmente): aponta para esta pasta
    // e reaplica início automático, dependência e conta. Nada em ProgramData é tocado.
    Code := RunSc('config ' + ServiceNameConst + ' binPath= ' + BinPath + ' start= auto depend= Spooler obj= LocalSystem DisplayName= "{#AppName}"');
  end
  else
  begin
    // 1072/1073 = ainda marcado para exclusão / já existe: tenta de novo por alguns segundos
    for Attempt := 1 to 10 do
    begin
      Code := RunSc('create ' + ServiceNameConst + ' binPath= ' + BinPath + ' start= auto depend= Spooler obj= LocalSystem DisplayName= "{#AppName}"');
      if Code = 0 then Break;
      Sleep(1500);
    end;
  end;

  if Code <> 0 then
  begin
    SuppressibleMsgBox('Não foi possível criar/atualizar o serviço Florest Print Agent (código ' + IntToStr(Code) + ').' + #13#10 +
                       'Reinicie o computador e execute o instalador novamente.', mbError, MB_OK, IDOK);
    Exit;
  end;

  RunSc('description ' + ServiceNameConst + ' "Mantém este computador conectado ao Florest ERP, informa as impressoras e imprime os pedidos do Bar/Cozinha."');
  // recuperação: reinicia sozinho em 1ª, 2ª e demais falhas (5 s, 5 s, 30 s); zera a contagem de falhas depois de 1 dia
  RunSc('failure ' + ServiceNameConst + ' reset= 86400 actions= restart/5000/restart/5000/restart/30000');
  // recuperação também quando o processo encerra com código de erro (não só quando "cai")
  RunSc('failureflag ' + ServiceNameConst + ' 1');
  RunSc('start ' + ServiceNameConst);

  // confere se subiu (até 20 s)
  for Attempt := 1 to 20 do
  begin
    if ServiceIsRunning() then Break;
    Sleep(1000);
  end;
  if not ServiceIsRunning() then
  begin
    SuppressibleMsgBox('O serviço Florest Print Agent foi instalado, mas ainda não está em execução.' + #13#10 +
                       'Ele tentará iniciar sozinho; se continuar parado, veja os logs em' + #13#10 +
                       ExpandConstant('{commonappdata}\Florest Sistemas\Print Agent\logs'), mbInformation, MB_OK, IDOK);
  end;
end;

function InitializeSetup(): Boolean;
var
  OldText: String;
  OldVersion, NewVersion: Int64;
begin
  Result := True;
  // instalação anterior (mesmo AppId): nunca troca por uma versão MAIS ANTIGA sem confirmar
  if RegQueryStringValue(HKLM, UninstallKey, 'DisplayVersion', OldText) then
  begin
    if StrToVersion(OldText, OldVersion) and StrToVersion('{#AppVersion}', NewVersion) then
    begin
      if ComparePackedVersion(OldVersion, NewVersion) > 0 then
      begin
        if SuppressibleMsgBox('Já existe uma versão MAIS NOVA do Florest Print Agent instalada (' + OldText + ').' + #13#10 +
                              'Deseja instalar a versão {#AppVersion} por cima mesmo assim?', mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO) = IDNO then
          Result := False;
      end;
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    // atualização: libera os arquivos em uso antes de copiar (o vínculo e os dados em ProgramData não são tocados)
    KillTray();
    StopServiceAndWait();
  end;
  if CurStep = ssPostInstall then
  begin
    InstallOrUpdateService();
  end;
end;

function HasParam(const Name: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
  begin
    if CompareText(ParamStr(I), Name) = 0 then
    begin
      Result := True;
      Break;
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    KillTray();
    StopServiceAndWait();
    DeleteServiceAndWait();
  end;
  if CurUninstallStep = usPostUninstall then
  begin
    DataDir := ExpandConstant('{commonappdata}\Florest Sistemas\Print Agent');
    if DirExists(DataDir) then
    begin
      if HasParam('/PURGEDATA') then
      begin
        // remoção total explícita (linha de comando)
        DelTree(DataDir, True, True, True);
      end
      else if not UninstallSilent then
      begin
        if MsgBox('Deseja apagar também os dados locais do Florest Print Agent (identificação deste computador, vínculo com a empresa, credencial e logs)?' + #13#10 + #13#10 +
                  'Se escolher Não, eles serão mantidos e, ao reinstalar, este computador continuará vinculado à mesma empresa/estação.',
                  mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
        begin
          DelTree(DataDir, True, True, True);
        end;
      end;
    end;
  end;
end;
