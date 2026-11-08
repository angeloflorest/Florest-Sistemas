!include "LogicLib.nsh"
!include "WordFunc.nsh"
!insertmacro VersionCompare
!macro customInstall
  SetRegView 64
  ReadRegStr $R0 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\{5D0B7C0E-6F1A-4C5B-9B7E-7A2E3D9F4A11}_is1" "DisplayVersion"
  ${If} $R0 != ""
    ${VersionCompare} $R0 "1.3.0" $R1
    ${If} $R1 == 0
      Goto agent_done
    ${EndIf}
    ${If} $R1 == 1
      Goto agent_done
    ${EndIf}
  ${EndIf}
  MessageBox MB_YESNO|MB_ICONQUESTION "Instalar ou atualizar o Florest Print Agent 1.3.0? Ele continua independente e preserva o vínculo, as impressoras e os trabalhos pendentes. O Windows poderá pedir permissão de administrador." /SD IDNO IDNO agent_done
  ExecShell "runas" "$INSTDIR\resources\print-agent.exe"
agent_done:
!macroend
