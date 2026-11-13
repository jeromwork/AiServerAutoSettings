#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
function Assert($ok,$text){if(-not $ok){throw $text};Write-Host ('PASS: '+$text)}
$env:LOCALAPPDATA=Join-Path ([IO.Path]::GetTempPath()) 'ports-profile'
$exe=Join-Path $env:LOCALAPPDATA 'RemoteDisk/channel/sing-box.exe'
$snapshot=[pscustomobject]@{listeners=@([pscustomobject]@{address='127.0.0.1';port=2222;pid=42});processes=@([pscustomobject]@{ProcessId=42;ExecutablePath=$exe})}
$line="FATAL start inbound/direct[ssh]: listen tcp 127.0.0.1:2222: bind: Only one usage of each socket address`r`n"
$c=Get-TransportBindConflict $line $snapshot
Assert ($c.port -eq 2222 -and $c.pid -eq 42 -and $c.legacy -and $c.message.Contains($exe) -and $c.message.Contains('старая установка RemoteDisk')) 'Причина называет порт, путь, PID и старую установку'
$snapshot.processes[0].ExecutablePath=Join-Path $env:LOCALAPPDATA 'Other/app.exe'
$c=Get-TransportBindConflict 'listen tcp 127.0.0.1:2222: bind: address already in use' $snapshot
Assert (-not $c.legacy -and $c.message.Contains('Other')) 'Чужая программа не названа старой установкой'
$snapshot|Add-Member legacyActions @(@{exe=$snapshot.processes[0].ExecutablePath;arguments='run -c old.json'})
$snapshot.processes[0]|Add-Member CommandLine ('"'+$snapshot.processes[0].ExecutablePath+'" run -c old.json')
$c=Get-TransportBindConflict $line $snapshot
Assert ($c.legacy) 'Старая задача RemoteDiskChannel распознана по действию и команде процесса'
$snapshot.legacyActions=@()
Assert ($null -eq (Get-TransportBindConflict 'dial tcp: connection refused' $snapshot)) 'Сетевая ошибка не принята за bind'
Assert ($null -eq (Get-TransportBindConflict 'listen tcp 127.0.0.1:2222: bind: permission denied' $snapshot)) 'Запрет доступа не принят за занятый порт'
$script:fixtureSnapshot=$snapshot
function Get-TransportPortSnapshot {$script:fixtureSnapshot}
$child=[pscustomobject]@{Process=[pscustomobject]@{HasExited=$true;ExitCode=1};ErrorDrain=[Threading.Tasks.Task]::CompletedTask;ErrorBuffer=[pscustomobject]@{}}
$child.ErrorBuffer|Add-Member ScriptMethod Snapshot {$script:bindLine}
$script:bindLine="WARN a preceding message`r`n"+$line
$d=New-TransportDiagnostic $child 'sing-box' 'process-exited'
Assert ($d.reason -eq 'port-in-use' -and (Format-TransportDiagnostic $d).Contains('PID 42')) 'Диагностика stderr сохраняет понятную причину'
Assert ($c.message.Contains('Remove-OldInstall.cmd') -and $c.message.Contains('откройте RemoteAgents снова')) 'Для старой установки дано действие ручной очистки'
$retry=Get-TransportBindRetry $null $d
Assert ($retry.failures -eq 1) 'Первая ошибка bind начинает новую серию'
$retry=Get-TransportBindRetry $retry $d
Assert ($retry.failures -eq 2) 'Повтор одной ошибки bind увеличивает паузу'
$other=Copy-TransportObject $d;$other.portConflict.port=2223
$retry=Get-TransportBindRetry $retry $other
Assert ($retry.failures -eq 1) 'Другой порт сбрасывает серию bind'
$other.stderr+=' another bind error'
$retry=Get-TransportBindRetry $retry $other
Assert ($retry.failures -eq 1) 'Другая ошибка того же порта сбрасывает серию'
$retry=Get-TransportBindRetry $retry (New-TransportDiagnostic $null 'sing-box' 'engine-start-failed')
Assert ($null -eq $retry) 'Ошибка без bind сбрасывает серию'
Assert ($null -eq (Get-TransportBindRetry $d $null)) 'Успешный исход сбрасывает серию'
Assert ((Get-TransportRestartDelay 3 1) -eq 5 -and (Get-TransportRestartDelay 3 2) -eq 10 -and (Get-TransportRestartDelay 3 8) -eq 30 -and (Get-TransportRestartDelay 3 0) -eq 3 -and (Get-TransportRestartDelay 90 1) -eq 30 -and (Get-TransportRestartDelay 90 0) -eq 30) 'Пауза bind растёт с 5 до 30 секунд и всегда ограничена 30 с'
