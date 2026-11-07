@echo off
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0disk\Install-RemoteDisk.ps1" %*
