@echo off
setlocal

if "%~1"=="" (
  echo usage: launch-preset-headless-pair-drill.cmd pairXX
  pause
  exit /b 64
)

set "ROOT=%~dp0"
set "PAIR_ID=%~1"
set "SCRIPT=%ROOT%run-preset-headless-pair-drill.ps1"

if not exist "%SCRIPT%" (
  echo run-preset-headless-pair-drill.ps1 not found: %SCRIPT%
  pause
  exit /b 1
)

where pwsh.exe >nul 2>nul
if "%ERRORLEVEL%"=="0" (
  pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -PairId "%PAIR_ID%"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -PairId "%PAIR_ID%"
)

set "EXITCODE=%ERRORLEVEL%"
if not "%EXITCODE%"=="0" (
  pause
)
exit /b %EXITCODE%
