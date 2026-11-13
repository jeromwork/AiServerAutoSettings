#requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'transport/Transport.Common.ps1')
. (Join-Path $repo 'transport/Legacy.Conflicts.ps1')
function Assert($ok,$text){if(-not $ok){throw $text};Write-Host ('PASS: '+$text)}
$work=Join-Path ([IO.Path]::GetTempPath()) ('legacy-conflicts-'+[guid]::NewGuid().ToString('N'))
$priorLocal=$env:LOCALAPPDATA;$env:LOCALAPPDATA=Join-Path $work 'local'
$root=Join-Path $env:LOCALAPPDATA 'RemoteAgents';$old=Join-Path $env:LOCALAPPDATA 'RemoteDisk'
$adapter=Join-Path $work 'adapter.ps1'
try{
    [void][IO.Directory]::CreateDirectory($work)
    @'
function Get-LegacyTasks {$global:legacyFixture.tasks}
function Get-LegacyProcesses {$global:legacyFixture.processes}
function Get-LegacyRun {$global:legacyFixture.run}
function Stop-LegacyTask($Task){
    if($global:legacyFixture.fail){throw 'test failure'}
    $Task.enabled=$false;$Task.running=$false;$global:legacyFixture.changes+=('task '+$Task.name)
}
function Stop-LegacyProcess($Process){
    $global:legacyFixture.changes+=('pid '+$Process.ProcessId)
    $global:legacyFixture.processes=@($global:legacyFixture.processes|Where-Object {$_.ProcessId -ne $Process.ProcessId})
}
function Remove-LegacyRun {$global:legacyFixture.run=$null;$global:legacyFixture.changes+='run RemoteDisk'}
'@ | Set-Content -LiteralPath $adapter -Encoding UTF8
    $global:legacyFixture=@{tasks=@();processes=@();changes=@();run=$null;fail=$false}
    foreach($name in @('RemoteDiskChannel','RemoteDiskFolders','RemoteAgentsControl')){
        $global:legacyFixture.tasks+=,[pscustomobject]@{name=$name;enabled=$true;running=$true;xml='<Task><Settings><Enabled>true</Enabled></Settings></Task>'}
    }
    $paths=@((Join-Path $old 'channel/sing-box.exe'),(Join-Path $old 'tray/syncthingtray.exe'),(Join-Path $root 'RemoteAgents.exe'),(Join-Path $root 'control/sing-box.exe'),(Join-Path $old 'tray/syncthingtray.exe'),(Join-Path $work 'other/syncthingtray.exe'),(Join-Path $old 'channel-other/sing-box.exe'))
    for($i=0;$i -lt $paths.Count;$i++){
        $global:legacyFixture.processes+=,[pscustomobject]@{ProcessId=101+$i;ParentProcessId=0;ExecutablePath=$paths[$i];CommandLine=('"'+$paths[$i]+'"');CreationDate=[DateTime]::UtcNow}
        [void][IO.Directory]::CreateDirectory((Split-Path $paths[$i]));[IO.File]::WriteAllText($paths[$i],'keep')
    }
    # pid 105 — новый headless, тот же exe, владелец — Disk.Status текущего bundle.
    $global:legacyFixture.processes[4].ParentProcessId=301
    $global:legacyFixture.processes+=,[pscustomobject]@{ProcessId=301;ParentProcessId=0;ExecutablePath='/system/powershell.exe';CommandLine=('powershell -File "'+(Join-Path $repo 'disk/Disk.Status.ps1')+'" -Home "'+$root+'"')}
    $global:legacyFixture.run=[pscustomobject]@{key='Software\Microsoft\Windows\CurrentVersion\Run';name='RemoteDisk';kind='String';value=('"'+(Join-Path $old 'tray/syncthingtray.exe')+'"')}
    $beforePlan=@(Get-ChildItem -LiteralPath $root -Recurse -Force|ForEach-Object FullName) -join "`n"
    $badPlan=Invoke-LegacyConflictCleanup -Root $root -Plan -Adapter $adapter
    Assert (-not $badPlan.ok -and $beforePlan -ceq (@(Get-ChildItem -LiteralPath $root -Recurse -Force|ForEach-Object FullName) -join "`n")) 'Ошибка чтения конфига в режиме плана ничего не записывает'
    Write-TransportJson (Join-Path $root 'config.json') @{components=@{disk=@{enabled=$false}}}
    $p=Invoke-LegacyConflictCleanup -Root $root -Plan -Adapter $adapter
    Assert ($p.ok -and ($p.tasks -join ',') -eq 'RemoteDiskChannel,RemoteDiskFolders' -and ($p.processes -join ',') -eq '101' -and $p.runs.Count -eq 0 -and $global:legacyFixture.changes.Count -eq 0) 'Без диска отключается только старый канал и две старые задачи; план ничего не меняет'
    Write-TransportJson (Join-Path $root 'config.json') @{components=@{disk=@{enabled=$true}}}
    $p=Invoke-LegacyConflictCleanup -Root $root -Plan -Adapter $adapter
    Assert (($p.processes -join ',') -eq '101,102' -and ($p.runs -join ',') -eq 'RemoteDisk' -and $p.folders.Count -eq 0) 'При совпадении состояния выбран старый трей; новая программа, control, свой движок и соседние пути не тронуты'
    $other=Join-Path $work 'different-disk'
    Write-TransportJson (Join-Path $root 'config.json') @{components=@{disk=@{enabled=$true}};disk=@{home=$other}}
    $p=Invoke-LegacyConflictCleanup -Root $root -Plan -Adapter $adapter
    Assert (($p.processes -join ',') -eq '101' -and $p.runs.Count -eq 0) 'Другой диск без совпадения портов и папок сохраняет старый трей'
    foreach($h in @($old,$other)){[void][IO.Directory]::CreateDirectory((Join-Path $h 'state'))}
    [IO.File]::WriteAllText((Join-Path $old 'state/config.xml'),'<configuration><gui><address>127.0.0.1:8384</address></gui><folder path="C:\Disk\Project"/></configuration>')
    [IO.File]::WriteAllText((Join-Path $other 'state/config.xml'),'<configuration><gui><address>127.0.0.1:8384</address></gui></configuration>')
    Assert (Test-LegacyDiskConflict $old $other) 'Совпадение GUI-порта — конфликт Syncthing'
    Assert ((Test-LegacyEndpoint 'tcp://0.0.0.0:22000' 'tcp://127.0.0.1:22000') -and -not (Test-LegacyEndpoint 'quic://127.0.0.1:22000' 'tcp://127.0.0.1:22000')) 'Порт с общим адресом тоже конфликтует, TCP и UDP различаются'
    [IO.File]::WriteAllText((Join-Path $other 'state/config.xml'),'<configuration><gui><address>127.0.0.1:9999</address></gui><folder path="C:\Disk\Project\Sub"/></configuration>')
    Assert (Test-LegacyDiskConflict $old $other) 'Пересечение папок — конфликт Syncthing'
    Write-TransportJson (Join-Path $root 'config.json') @{components=@{disk=@{enabled=$true}}}
    $result=Invoke-LegacyConflictCleanup -Root $root -Adapter $adapter
    Assert ($result.ok -and (Test-Path (Join-Path $result.backup 'manifest.json')) -and (Test-Path (Join-Path $result.backup 'Restore-OldInstall.ps1'))) 'Отключение сохраняет копию для отката'
    $m=Read-TransportJson (Join-Path $result.backup 'manifest.json')
    Assert ($m.automatic -and $m.tasks.Count -eq 2 -and $m.runs.Count -eq 1 -and $m.processes.Count -eq 2 -and $m.folders.Count -eq 0 -and $m.regkeys.Count -eq 0) 'Копия содержит XML, автозапуск и процессы, без переноса каталогов и ключей'
    Assert ($global:legacyFixture.tasks[2].enabled -and (Get-Content $paths[2]) -eq 'keep' -and (Get-Content $paths[3]) -eq 'keep') 'Мост RemoteAgentsControl и новая RemoteAgents.exe сохранены'
    $changes=$global:legacyFixture.changes.Count
    $again=Invoke-LegacyConflictCleanup -Root $root -Adapter $adapter
    Assert ($again.ok -and $again.backup -eq $result.backup -and $global:legacyFixture.changes.Count -eq $changes) 'Повтор ничего не отключает и сохраняет путь отката'
    $restoreCopy=Join-Path $work 'restore-copy';Copy-Item -LiteralPath $result.backup -Destination $restoreCopy -Recurse
    $restoreManifest=Read-TransportJson (Join-Path $restoreCopy 'manifest.json')
    $restoreManifest.tasks[1].running=$false;$restoreManifest.tasks[1].enabled=$false
    $restoreManifest.processes+=@([pscustomobject]@{exe='old.exe';commandLine='old.exe --orphan';restartWith=''},[pscustomobject]@{exe='old.exe';commandLine='old.exe --alive';restartWith=''})
    Write-TransportJson (Join-Path $restoreCopy 'manifest.json') $restoreManifest
    $restoreAdapter=Join-Path $work 'restore-adapter.ps1'
    @'
function Invoke-Native([string]$Exe,[string[]]$A){
    if($A[0] -eq '/Delete'){throw 'Задача не должна удаляться'}
    Add-Content -LiteralPath (Join-Path $Backup 'restore-calls.txt') -Value ($Exe+' '+($A -join ' '))
    [pscustomobject]@{code=0;out=''}
}
function Set-RestoreRun($Value){Add-Content -LiteralPath (Join-Path $Backup 'restore-calls.txt') -Value ('Run '+$Value.name)}
function Get-CimInstance {[pscustomobject]@{CommandLine='old.exe --alive'}}
function Invoke-CimMethod {
    param($ClassName,$MethodName,$Arguments)
    Add-Content -LiteralPath (Join-Path $Backup 'restore-calls.txt') -Value ('Start '+$Arguments.CommandLine)
    [pscustomobject]@{ReturnValue=0}
}
'@ | Set-Content -LiteralPath $restoreAdapter -Encoding UTF8
    $restoreOutput=& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File (Join-Path $repo 'tools/legacy-cleanup/Restore-OldInstall.ps1') -Backup $restoreCopy -Yes -Adapter $restoreAdapter 2>&1|Out-String
    if($LASTEXITCODE -ne 0){throw $restoreOutput}
    $calls=[IO.File]::ReadAllText((Join-Path $restoreCopy 'restore-calls.txt'))
    Assert ($calls.Contains('/Create /TN RemoteDiskChannel') -and $calls.Contains('/Create /TN RemoteDiskFolders') -and $calls.Contains('/Run /TN RemoteDiskChannel') -and -not $calls.Contains('/Run /TN RemoteDiskFolders')) 'Откат возвращает XML, запускает только прежде работавшую включённую задачу'
    Assert ($calls.Contains('Run RemoteDisk') -and $calls.Contains('Start old.exe --orphan') -and -not $calls.Contains('Start old.exe --alive') -and (Test-Path (Join-Path $restoreCopy 'restored.txt'))) 'Откат возвращает автозапуск и отдельный процесс, не дублирует живой'
    $global:legacyFixture.tasks[0].enabled=$true;$global:legacyFixture.fail=$true
    $failed=Invoke-LegacyConflictCleanup -Root $root -Adapter $adapter
    Assert (-not $failed.ok -and $failed.summary.Contains('RemoteDiskChannel') -and (Test-Path (Join-Path $failed.backup 'manifest.json'))) 'Ошибка Disable не роняет настройку, видна в статусе; копия уже сохранена'
    Assert (-not (Read-TransportJson (Join-Path $root 'status/legacy-cleanup.json')).ok) 'Ошибка сохранена в JSON-статусе'
}finally{$env:LOCALAPPDATA=$priorLocal;Remove-Variable legacyFixture -Scope Global -ErrorAction SilentlyContinue;Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue}
