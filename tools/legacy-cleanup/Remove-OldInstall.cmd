@echo off
rem Temporary tool: removes the old (pre-EXE) RemoteAgents/RemoteDisk installation.
rem Shows the plan first and asks before changing anything.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Remove-OldInstall.ps1" %*
set RC=%ERRORLEVEL%
echo.
echo Exit code: %RC%
pause
exit /b %RC%
