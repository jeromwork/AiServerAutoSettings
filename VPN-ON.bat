@echo off
setlocal
title VPN protection ON
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0VpnLock.ps1" -Action Enable
if errorlevel 1 (
  echo Protection was NOT confirmed. Read the error above.
  pause
  exit /b 1
)
echo Done.
pause
