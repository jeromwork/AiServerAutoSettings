@echo off
setlocal
title VPN protection OFF
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0VpnLock.ps1" -Action Disable
if errorlevel 1 (
  echo Restore failed. Read the error above.
  pause
  exit /b 1
)
echo Done. Saved firewall settings restored, or protection was already off.
timeout /t 3 >nul
