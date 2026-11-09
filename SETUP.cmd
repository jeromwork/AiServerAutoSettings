@echo off
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Setup-All.ps1" %*
if errorlevel 1 echo Setup stopped. Read the error above.
pause
