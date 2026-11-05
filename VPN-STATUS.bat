@echo off
setlocal
title VPN protection status
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0VpnLock.ps1" -Action Status
pause
