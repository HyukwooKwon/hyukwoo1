@echo off
setlocal
set "ROOT=%~dp0"
set "SCRIPT=%ROOT%launch-relay-operator-panel.ps1"

if not exist "%SCRIPT%" (
  echo launch-relay-operator-panel.ps1 ??? ?? ?????: %SCRIPT%
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "EXITCODE=%ERRORLEVEL%"
if not "%EXITCODE%"=="0" (
  pause
)
exit /b %EXITCODE%
