@echo off
setlocal
rem Connects saved folders and the Windows control bridge. Keep this window open.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0setup-vps-ssh.ps1" -Launcher -ConnectSaved %*
exit /b %ERRORLEVEL%
