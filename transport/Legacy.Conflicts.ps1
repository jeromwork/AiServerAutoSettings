#requires -Version 5.1
# Точечная передача старых служб новой программе. Общая очистка сюда не входит.
function Get-LegacyTasks {
    $installed=@(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop)
    foreach($name in @('RemoteDiskChannel','RemoteDiskFolders')){
        $task=$installed|Where-Object {$_.TaskName -eq $name}|Select-Object -First 1
        if($task){[pscustomobject]@{name=$name;enabled=[bool]$task.Settings.Enabled;running=([string]$task.State -eq 'Running');xml=(Export-ScheduledTask -TaskPath '\' -TaskName $name -ErrorAction Stop)}}
    }
}
function Stop-LegacyTask($Task) {
    Disable-ScheduledTask -TaskPath '\' -TaskName $Task.name -ErrorAction Stop|Out-Null
    if($Task.running){Stop-ScheduledTask -TaskPath '\' -TaskName $Task.name -ErrorAction Stop}
}
function Get-LegacyProcesses {@(Get-CimInstance Win32_Process -ErrorAction Stop)}
function Stop-LegacyProcess($Process) {
    $live=Get-CimInstance Win32_Process -Filter ('ProcessId='+$Process.ProcessId) -ErrorAction Stop
    if(-not $live){return}
    if($live.ExecutablePath -ine $Process.ExecutablePath -or $live.CreationDate -ne $Process.CreationDate){throw 'Процесс сменился; остановка отменена'}
    Stop-Process -Id $live.ProcessId -Force -ErrorAction Stop
    $wait=$null;try{$wait=[Diagnostics.Process]::GetProcessById($live.ProcessId)}catch [ArgumentException]{}
    if($wait){try{if(-not $wait.WaitForExit(10000)){throw 'Старый процесс не завершился'}}finally{$wait.Dispose()}}
}
function Get-LegacyRun {
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
    if($key){try{$value=$key.GetValue('RemoteDisk',$null,'DoNotExpandEnvironmentNames');if($null -ne $value){[pscustomobject]@{key='Software\Microsoft\Windows\CurrentVersion\Run';name='RemoteDisk';value=$value;kind=[string]$key.GetValueKind('RemoteDisk')}}}finally{$key.Dispose()}}
}
function Remove-LegacyRun {
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run',$true)
    if($key){try{$key.DeleteValue('RemoteDisk',$false)}finally{$key.Dispose()}}
}
function Convert-LegacyPath([string]$Path) {([IO.Path]::GetFullPath($Path)).Replace('/','\').TrimEnd('\').ToLowerInvariant()}
function Test-LegacyPath([string]$Path,[string]$Root) {
    if(-not $Path){return $false};$p=Convert-LegacyPath $Path;$r=Convert-LegacyPath $Root
    $p -eq $r -or $p.StartsWith($r+'\')
}
function Test-LegacyManagedEngine($Process,$Processes) {
    # Тот же exe используется новым надзором. Проверяем цепочку родителей по точному пути скрипта текущего bundle.
    $id=[int]$Process.ParentProcessId;$bundle=Split-Path $PSScriptRoot -Parent
    for($i=0;$i -lt 4 -and $id -gt 0;$i++){
        $parent=@($Processes|Where-Object {[int]$_.ProcessId -eq $id}|Select-Object -First 1);if(-not $parent.Count){break}
        foreach($script in @('disk/Disk.Status.ps1','disk/Install-RemoteDisk.ps1')){
            $path=(Join-Path $bundle $script).Replace('/','\')
            if(([string]$parent[0].CommandLine).Replace('/','\') -match ('(?i)(?:^|[\s"])'+[regex]::Escape($path)+'(?:"|\s|$)')){return $true}
        }
        $id=[int]$parent[0].ParentProcessId
    };$false
}
function Test-LegacyEndpoint([string]$Left,[string]$Right) {
    $a=$null;$b=$null
    if($Left -notmatch '://'){$Left='tcp://'+$Left};if($Right -notmatch '://'){$Right='tcp://'+$Right}
    if(-not [Uri]::TryCreate($Left,[UriKind]::Absolute,[ref]$a) -or -not [Uri]::TryCreate($Right,[UriKind]::Absolute,[ref]$b)){return $false}
    if($a.Port -le 0 -or $a.Port -ne $b.Port -or ($a.Scheme -replace '[46]$','') -ne ($b.Scheme -replace '[46]$','')){return $false}
    $wild=@('0.0.0.0','[::]','::');$ah=$a.Host;$bh=$b.Host
    if($ah -eq 'localhost'){$ah='127.0.0.1'};if($bh -eq 'localhost'){$bh='127.0.0.1'}
    $ah -eq $bh -or $ah -in $wild -or $bh -in $wild
}
function Test-LegacyDiskConflict([string]$OldHome,[string]$NewHome) {
    if((Convert-LegacyPath $OldHome) -eq (Convert-LegacyPath $NewHome)){return $true}
    $oldFile=Join-Path $OldHome 'state/config.xml';$newFile=Join-Path $NewHome 'state/config.xml'
    if(-not (Test-Path $oldFile) -or -not (Test-Path $newFile)){return $false}
    $old=[xml](Get-Content -LiteralPath $oldFile -Raw);$new=[xml](Get-Content -LiteralPath $newFile -Raw)
    $addresses=@($old.SelectNodes('/configuration/gui/address|/configuration/options/listenAddress')|ForEach-Object {$_.InnerText})
    foreach($node in @($new.SelectNodes('/configuration/gui/address|/configuration/options/listenAddress'))){
        foreach($address in $addresses){if(Test-LegacyEndpoint $node.InnerText $address){return $true}}
    }
    foreach($a in @($old.SelectNodes('/configuration/folder'))){foreach($b in @($new.SelectNodes('/configuration/folder'))){
        if((Test-LegacyPath ([string]$a.path) ([string]$b.path)) -or (Test-LegacyPath ([string]$b.path) ([string]$a.path))){return $true}
    }};$false
}
function Write-LegacyConflictLog([string]$Root,[string]$Text) {
    $dir=Join-Path $Root 'logs';[void][IO.Directory]::CreateDirectory($dir);$file=Join-Path $dir 'legacy-cleanup.log'
    if((Test-Path $file) -and (Get-Item $file).Length -ge 1MB){Move-Item $file ($file+'.1') -Force}
    [IO.File]::AppendAllText($file,([DateTime]::UtcNow.ToString('o')+' '+$Text+"`n"),(New-Object Text.UTF8Encoding($false)))
}
function Invoke-LegacyConflictCleanup {
    [CmdletBinding()]
    param([string]$Root,[switch]$DiskEnabled,[switch]$Plan,[string]$Adapter)
    if($env:OS -ne 'Windows_NT' -and -not $Adapter){return [pscustomobject]@{ok=$true;skipped=$true;summary='Проверка старой установки выполняется на Windows'}}
    # Адаптер имеет только локальную область этого вызова; product его не передаёт.
    if($Adapter){. ([IO.Path]::GetFullPath($Adapter))}
    $mutex=$null;$locked=$false;$backup=$null;$errors=@();$actions=@();$tasks=@();$runs=@();$processes=@()
    try{
        $name='Global\RemoteAgentsLegacy-'+(Get-TransportFingerprint 'legacy' $env:LOCALAPPDATA.ToLowerInvariant())
        $mutex=New-Object Threading.Mutex($false,$name)
        try{$locked=$mutex.WaitOne(15000)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){throw 'Проверка старой установки уже выполняется; повторите запуск'}
        $config=Read-TransportJson (Join-Path $Root 'config.json')
        $old=Join-Path $env:LOCALAPPDATA 'RemoteDisk';$diskHome=$old;if($config.disk.home){$diskHome=[string]$config.disk.home}
        $manageDisk=$DiskEnabled -or $config.components.disk.enabled -eq $true
        try{$tasks=@(Get-LegacyTasks|Where-Object {$_.name -in @('RemoteDiskChannel','RemoteDiskFolders') -and ($_.enabled -or $_.running)})}catch{$errors+='Не удалось проверить старые задачи планировщика'}
        try{$all=@(Get-LegacyProcesses)}catch{$all=@();$errors+='Не удалось проверить процессы старой установки'}
        $diskConflict=$false
        if($manageDisk){try{$diskConflict=Test-LegacyDiskConflict $old $diskHome}catch{$errors+='Не удалось сравнить настройки старого Syncthing'}}
        foreach($p in $all){
            if($p.ProcessId -eq $PID -or -not $p.ExecutablePath){continue}
            $channel=Test-LegacyPath $p.ExecutablePath (Join-Path $old 'channel')
            $tray=$diskConflict -and ((Convert-LegacyPath $p.ExecutablePath) -in @((Convert-LegacyPath (Join-Path $old 'tray/syncthingtray.exe')),(Convert-LegacyPath (Join-Path $old 'tray/syncthing.exe'))))
            if($channel -or ($tray -and -not (Test-LegacyManagedEngine $p $all))){$processes+=,$p}
        }
        # Сначала GUI: он может снова запустить дочерний Syncthing.
        $processes=@($processes|Sort-Object @{Expression={if($_.CommandLine -match '(?i)\bsyncthing\s+serve\b'){1}else{0}}})
        if($diskConflict){try{$run=Get-LegacyRun;if($run){
            $expanded=[Environment]::ExpandEnvironmentVariables([string]$run.value).Replace('/','\')
            $trayPath=(Join-Path $old 'tray/syncthingtray.exe').Replace('/','\')
            if($expanded -match ('(?i)^\s*"?'+[regex]::Escape($trayPath)+'"?(?:\s|$)')){$runs+=,$run}
        }}catch{$errors+='Не удалось проверить автозапуск старого диска'}}
        if($Plan){return [pscustomobject]@{ok=($errors.Count -eq 0);tasks=@($tasks|ForEach-Object {$_.name});processes=@($processes|ForEach-Object {$_.ProcessId});runs=@($runs|ForEach-Object {$_.name});errors=$errors;folders=@()}}
        if($tasks.Count+$runs.Count+$processes.Count){
            $backup=Join-Path $env:LOCALAPPDATA ('RemoteAgents-old-backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
            [void][IO.Directory]::CreateDirectory($backup);Protect-TransportPath $backup
            $restore=Join-Path $PSScriptRoot 'Restore-OldInstall.ps1'
            if(-not (Test-Path $restore)){$restore=Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/legacy-cleanup/Restore-OldInstall.ps1'}
            Copy-Item -LiteralPath $restore -Destination (Join-Path $backup 'Restore-OldInstall.ps1') -ErrorAction Stop
            $m=[ordered]@{automatic=$true;created=(Get-Date).ToString('o');computer=$env:COMPUTERNAME;tasks=@();runs=$runs;regkeys=@();folders=@();processes=@()}
            foreach($t in $tasks){$file='task-'+$t.name+'.xml';[void][xml]$t.xml;[IO.File]::WriteAllText((Join-Path $backup $file),$t.xml,[Text.Encoding]::Unicode);$m.tasks+=@{name=$t.name;file=$file;running=$t.running;enabled=$t.enabled}}
            foreach($p in $processes){if(-not $p.CommandLine){throw 'Не удалось сохранить команду старого процесса для отката'};$m.processes+=@{exe=$p.ExecutablePath;commandLine=$p.CommandLine;restartWith=$(if((Test-LegacyPath $p.ExecutablePath (Join-Path $old 'channel')) -and @($tasks|Where-Object {$_.name -eq 'RemoteDiskChannel' -and $_.running -and $_.enabled}).Count){'RemoteDiskChannel'}elseif($runs.Count -and (Test-LegacyPath $p.ExecutablePath (Join-Path $old 'tray'))){'RemoteDisk'}else{''})}}
            # Полная копия ДО первого изменения, в том числе при последующем отказе Disable/Stop.
            Write-TransportJson (Join-Path $backup 'manifest.json') $m -Private -Durable
            foreach($t in $tasks){try{Stop-LegacyTask $t;$actions+=('Остановлена и отключена старая задача '+$t.name)}catch{$errors+=('Не удалось остановить и отключить старую задачу '+$t.name)}}
            foreach($r in $runs){try{Remove-LegacyRun;$actions+='Отключён автозапуск старого трея RemoteDisk'}catch{$errors+='Не удалось отключить автозапуск старого трея RemoteDisk'}}
            foreach($p in $processes){try{Stop-LegacyProcess $p;$actions+=('Остановлена старая программа '+$p.ExecutablePath+' (PID '+$p.ProcessId+')')}catch{$errors+=('Не удалось остановить старую программу '+$p.ExecutablePath+' (PID '+$p.ProcessId+')')}}
            $actions+=('Копия для отката: '+$backup)
        }
    }catch{$errors+='Не удалось завершить проверку старой установки; проверьте права и повторите запуск'}
    finally{if($locked){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}}
    if($Plan){return [pscustomobject]@{ok=$false;tasks=@();processes=@();runs=@();errors=$errors;folders=@()}}
    $summary=if($errors.Count){$errors -join '; '}elseif($actions.Count){'Конфликтующие части старой установки отключены'}else{'Конфликтующая старая установка не найдена'}
    $result=[pscustomobject]@{ok=($errors.Count -eq 0);summary=$summary;backup=$backup;actions=$actions;errors=$errors;updatedAt=[DateTime]::UtcNow.ToString('o')}
    try{
        foreach($text in @($actions)+@($errors)){Write-LegacyConflictLog $Root $text}
        $status=Join-Path $Root 'status/legacy-cleanup.json'
        # Повтор без изменений сохраняет сведения о предыдущем отключении и его копии.
        if(-not $actions.Count -and -not $errors.Count -and (Test-Path $status)){$previous=Read-TransportJson $status;if($previous.ok){return $previous}}
        Write-TransportJson $status $result
    }catch{$result.ok=$false;$result.summary+='; не удалось записать журнал или статус проверки старой установки'}
    $result
}
