@echo off
setlocal
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0setup-vps-ssh.ps1" -Launcher %*
exit /b %ERRORLEVEL%
