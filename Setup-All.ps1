#requires -Version 5.1
# Одна точка входа: SSH-профиль и мост управления (MCP).
# Повторный запуск безопасен: каждый шаг сохраняет существующие настройки.
[CmdletBinding()]
param([string]$Profile,[string]$DiskUser='remoteagents',[switch]$LauncherSetup)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'build/Process.Common.ps1')
function Write-Step([string]$Text) {Write-Host '';Write-Host ('=== '+$Text+' ===') -ForegroundColor Cyan}
function Find-RootProfiles {@(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'RemoteAgents\ssh-profiles\*\project-connections\*\ssh-transport.json') -File -ErrorAction SilentlyContinue)}
function Invoke-Child([string]$Script,[string[]]$Arguments) {
    $all=@('-NoLogo','-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot $Script))+$Arguments
    $p=Start-Process powershell.exe -ArgumentList (($all|ForEach-Object {Quote-Disk ([string]$_)}) -join ' ') -NoNewWindow -Wait -PassThru
    $p.ExitCode
}
$results=[ordered]@{}

Write-Step '1. Вход на сервер по SSH'
if(-not $Profile){
    $files=Find-RootProfiles
    if($files.Count -eq 0){
        Write-Host 'SSH-профиля нет. Сейчас откроется настройка входа: укажите сервер и пароль.'
        Write-Host 'Когда вход проверен и появится меню «Работа с сервером», введите 0 и затем 0.'
        [void](Invoke-Child 'setup-vps-ssh.ps1' @())
        $files=Find-RootProfiles
        if($files.Count -eq 0){throw 'SSH-профиль не создан, продолжить нельзя.'}
    }
    if($files.Count -eq 1){$Profile=$files[0].FullName} else {
        for($i=0;$i -lt $files.Count;$i++){$j=Get-Content -LiteralPath $files[$i].FullName -Raw|ConvertFrom-Json;Write-Host ('{0}. {1}@{2}  ({3})' -f ($i+1),$j.login,$j.serverAddress,$files[$i].FullName)}
        $n=0;if(-not [int]::TryParse((Read-Host 'Номер профиля'),[ref]$n) -or $n -lt 1 -or $n -gt $files.Count){throw 'Неверный номер профиля'}
        $Profile=$files[$n-1].FullName
    }
}
$Profile=[IO.Path]::GetFullPath($Profile)
$root=Get-Content -LiteralPath $Profile -Raw|ConvertFrom-Json
Write-Host ('Профиль: {0}@{1}' -f $root.login,$root.serverAddress)
$results['SSH']='готово'

Write-Step '2. Управление компьютером (MCP-мост)'
$code=Invoke-Child 'Start-WindowsControl.ps1' @('-Install','-Profile',$Profile,'-AgentUser',$(if($root.login -eq 'root'){$DiskUser}else{$root.login}))
if($LauncherSetup -and $code -ne 0){throw 'Установка моста не выполнена'}
$results['Мост управления']=$(if($code -eq 0){'готово'}else{'ОШИБКА (код '+$code+'), см. %LOCALAPPDATA%\RemoteAgents\control\logs\control.log'})

Write-Step 'Итог'
foreach($k in $results.Keys){Write-Host ('{0,-18} {1}' -f $k,$results[$k])}
Write-Host ''
Write-Host 'Связь и мост запускаются автоматически. Файлы синхронизирует официальное приложение облака.'
