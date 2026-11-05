@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"
echo Florest PDV Movel - Gerador Release
where node >nul 2>nul
if errorlevel 1 (
  echo ERRO: Node.js nao encontrado. Instale Node 20.19 ou superior.
  pause
  exit /b 1
)
node "%~dp0scripts\build-release.cjs"
set "RESULTADO=%ERRORLEVEL%"
echo.
if not "%RESULTADO%"=="0" echo Geracao interrompida. Confira o erro acima. Nao use APKs intermediarios.
pause
exit /b %RESULTADO%
