@echo off
setlocal
set "ROOT=%~dp0"
set "SCRIPT=%ROOT%run-pair03-headless-drill.ps1"

if not exist "%SCRIPT%" (
  echo run-pair03-headless-drill.ps1 ??? ?? ?????: %SCRIPT%
  pause
  exit /b 1
)

where pwsh.exe >nul 2>nul
if "%ERRORLEVEL%"=="0" (
  pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
)

set "EXITCODE=%ERRORLEVEL%"
if not "%EXITCODE%"=="0" (
  pause
)
exit /b %EXITCODE%
