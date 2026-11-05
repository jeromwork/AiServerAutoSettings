@echo off
chcp 65001 >nul
echo Включаем пункт в контекстном меню Windows...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Sync-ContextMenu.ps1" -Action Enable
pause
