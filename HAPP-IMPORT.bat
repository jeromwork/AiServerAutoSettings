@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0setup-happ.ps1" %*
if errorlevel 1 echo HAPP setup failed. Read the error above.
pause
