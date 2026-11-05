@echo off
chcp 65001 >nul
echo Удаляем пункт из контекстного меню Windows...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Sync-ContextMenu.ps1" -Action Disable
pause
