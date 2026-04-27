@echo off
setlocal
call "%~dp0launch-preset-headless-pair-drill.cmd" pair01
exit /b %ERRORLEVEL%
