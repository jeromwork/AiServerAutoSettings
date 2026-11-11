@echo off
rem Temporary tool: brings the old installation back from the latest backup.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Restore-OldInstall.ps1" %*
set RC=%ERRORLEVEL%
echo.
echo Exit code: %RC%
pause
exit /b %RC%
