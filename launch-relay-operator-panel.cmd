@echo off
setlocal
set "ROOT=%~dp0"
set "SCRIPT=%ROOT%launch-relay-operator-panel.ps1"

if not exist "%SCRIPT%" (
  echo launch-relay-operator-panel.ps1 not found: %SCRIPT%
  pause
  exit /b 1
)

where pwsh.exe >nul 2>nul
if not "%ERRORLEVEL%"=="0" (
  echo pwsh.exe PowerShell 7+ is required.
  pause
  exit /b 1
)

pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "EXITCODE=%ERRORLEVEL%"
if not "%EXITCODE%"=="0" (
  pause
)
exit /b %EXITCODE%
