#requires -Version 5.1
[CmdletBinding()]
param([Alias('StartTray')][switch]$StartEngine,[switch]$OpenWindow,[Alias('Home')][string]$LauncherHome)
# Shared ownership helpers: same embedded engine and state as the former tray.
# Installation and component startup share one per-state lock. The component
# releases it after REST is ready so a later installer can borrow the engine.
function Enter-DiskEngineLock([string]$DiskRoot,[int]$TimeoutMilliseconds=900000) {
    $key=[IO.Path]::GetFullPath($DiskRoot).Replace('/','\').TrimEnd('\').ToLowerInvariant()
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key)))).Replace('-','')}finally{$sha.Dispose()}
    $mutex=New-Object Threading.Mutex($false,('Global\RemoteDiskEngine-'+$hash))
    $held=$false
    try{
        try{$held=$mutex.WaitOne($TimeoutMilliseconds)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){throw 'Диск занят установкой или запуском; повторите после завершения'}
        return [pscustomobject]@{Mutex=$mutex;Held=$true}
    }catch{$mutex.Dispose();throw}
}
function Exit-DiskEngineLock($Lease) {
    if($Lease -and $Lease.Held){try{$Lease.Mutex.ReleaseMutex()}finally{$Lease.Held=$false;$Lease.Mutex.Dispose()}}
}
function Get-DiskEngineProcesses([string]$DiskRoot) {
    $exe=[IO.Path]::GetFullPath((Join-Path $DiskRoot 'tray/syncthingtray.exe'))
    $state=[IO.Path]::GetFullPath((Join-Path $DiskRoot 'state')).Replace('/','\')
    $statePattern='(?:^|\s)"?--home(?:"?\s+|=)"?'+[regex]::Escape($state)+'"?(?=\s|$)'
    @(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object {
        if(-not $_.ExecutablePath -or [IO.Path]::GetFullPath($_.ExecutablePath) -ine $exe){return $false}
        $line=([string]$_.CommandLine).Replace('/','\')
        # Our windowed UI cannot launch an engine and must not block temporary
        # installer startup when REST is down. Old tray GUI still gets removed.
        if($line -match '(?:^|\s)"?--windowed"?(?=\s|$)'){return $false}
        # Embedded command mode belongs to us only for this state.
        ($line -notmatch '(?:^|\s)"?syncthing"?(?:\s|$)' -or $line -match $statePattern)
    })
}
function Stop-DiskEngineProcesses([string]$DiskRoot) {
    # Stop tray first (it can respawn the engine); then its embedded Syncthing child.
    $processes=@(Get-DiskEngineProcesses $DiskRoot|Sort-Object @{Expression={if($_.CommandLine -match '(?:^|\s)"?syncthing"?\s+"?serve"?(?:\s|$)'){1}else{0}}})
    foreach($p in $processes){
        $live=Get-CimInstance Win32_Process -Filter ('ProcessId='+$p.ProcessId) -ErrorAction Stop
        if($live -and $live.ExecutablePath -ieq $p.ExecutablePath -and $live.CreationDate -eq $p.CreationDate){
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            $wait=$null;try{$wait=[Diagnostics.Process]::GetProcessById($p.ProcessId)}catch [ArgumentException]{}
            if($wait){try{if(-not $wait.WaitForExit(10000)){throw 'Syncthing не завершён'}}finally{$wait.Dispose()}}
        }
    }
    if(@(Get-DiskEngineProcesses $DiskRoot).Count){throw 'Syncthing ещё работает'}
}
function Wait-DiskEngineReady([int]$TimeoutSeconds=30) {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do{
        try{$status=Invoke-DiskApi 'system/status';if($status.myID){return $status}}catch{}
        $remaining=$TimeoutSeconds*1000-$watch.ElapsedMilliseconds
        if($remaining -gt 0){Start-Sleep -Milliseconds ([int][Math]::Min(250,$remaining))}
    }while($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw ('Syncthing уже запущен, но REST не ответил за '+$TimeoutSeconds+' с; повторите запуск позже')
}
function Start-DiskHeadless {
    $exe=Join-Path $script:DiskHome 'tray/syncthingtray.exe'
    if(-not (Test-Path $exe)){throw 'Syncthing не установлен'}
    if($script:DiskEngine -and -not $script:DiskEngine.HasExited){return}
    # Tray may have started its engine before REST is ready. Wait without launching a duplicate.
    if(@(Get-DiskEngineProcesses $script:DiskHome).Count){[void](Wait-DiskEngineReady);return}
    $si=New-Object Diagnostics.ProcessStartInfo
    $si.FileName=$exe;$si.Arguments=(@('syncthing','serve','--home',(Join-Path $script:DiskHome 'state'),'--no-browser','--no-restart')|ForEach-Object {Quote-Disk $_}) -join ' '
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true
    # Syncthing 2.1.7's --no-restart still starts a monitor/worker pair.
    # STMONITORED runs the worker directly: this process handle owns the whole
    # temporary engine, so cleanup never targets a borrowed endpoint or PID.
    # https://github.com/Martchus/syncthing/blob/0877c5797dd49771aa337000eb790b7ce2084e17/cmd/syncthing/main.go#L304
    $si.EnvironmentVariables['STMONITORED']='yes'
    $script:DiskEngine=[Diagnostics.Process]::Start($si)
    [void]$script:DiskEngine.Handle
}

function Stop-DiskHeadless {
    $owned=$script:DiskEngine
    if(-not $owned){return}
    try{
        # The pinned Process handle, never a fresh PID lookup, identifies our worker.
        if(-not $owned.HasExited){$owned.Kill()}
        if(-not $owned.WaitForExit(10000)){throw 'Временный движок Syncthing не завершён'}
    }finally{$owned.Dispose();$script:DiskEngine=$null}
}

# Managed UI never owns the engine. Also neutralize the old adjacent ini on upgrade.
function Set-DiskTrayExternalEngine {
    $ini=Join-Path $script:DiskHome 'tray/syncthingtray.ini'
    if(-not (Test-Path -LiteralPath $ini)){return}
    $text=[IO.File]::ReadAllText($ini).Replace("`r",'')
    # No startup group means default autostart=false; preserve unrelated settings.
    if($text -notmatch '(?m)^\[startup\]$'){return}
    $section='';$startup=$false;$lines=New-Object 'Collections.Generic.List[string]'
    $keys=@('syncthingAutostart','useLibSyncthing','considerLauncherForReconnect','showLauncherButton')
    foreach($line in ($text -split "`n")){
        if($line -match '^\[(.+)\]$'){
            $section=$Matches[1]
            if($section -eq 'startup' -and -not $startup){
                $startup=$true;$lines.Add($line)
                foreach($key in $keys){$lines.Add($key+'=false')}
                continue
            }
        }
        if($section -eq 'startup' -and $line -match '^(syncthingAutostart|useLibSyncthing|considerLauncherForReconnect|showLauncherButton)='){continue}
        $lines.Add($line)
    }
    $updated=$lines -join "`n"
    if($updated -cne $text){Write-DiskUtf8 $ini $updated}
}
function Start-DiskComponent($StartupLease) {
    Start-DiskHeadless
    if(-not $script:DiskEngine){throw 'Не удалось получить собственный движок Syncthing'}
    Read-DiskState
    [void](Wait-DiskEngineReady)
    # Folders accepted by an older build keep the 10-second delay until migrated; an upgrade never runs the installer.
    try{Set-DiskWatcherDelay}catch{Write-DiskLog 'Задержка обнаружения изменений' $_}
    Exit-DiskEngineLock $StartupLease
    # Inherits the launcher's kill-on-close Job. Its exit ends this component,
    # so the existing supervisor restarts it even after a normal Syncthing exit.
    $script:DiskEngine.WaitForExit()
    return $script:DiskEngine.ExitCode
}
function Open-DiskSyncWindow {
    Read-DiskState
    # Separate settings keep any user auto-start/embedded-engine preferences out
    # of this window. --windowed creates TrayWidget instead of TrayIcon (v2.1.9).
    $directory=Join-Path $script:DiskHome 'tray/window'
    [void][IO.Directory]::CreateDirectory($directory)
    $ini=Join-Path $directory 'syncthingtray.ini'
    $exe=Join-Path $script:DiskHome 'tray/syncthingtray.exe'
    $settings=(New-DiskIni $exe (Join-Path $script:DiskHome 'state') $script:Gui $script:ApiKey).Replace('syncthingAutostart=true','syncthingAutostart=false').Replace('considerLauncherForReconnect=true','considerLauncherForReconnect=false')
    Write-DiskUtf8 $ini $settings
    $si=New-Object Diagnostics.ProcessStartInfo
    $si.FileName=$exe;$si.WorkingDirectory=$directory
    $si.Arguments=(@('--windowed','--single-instance','--trigger')|ForEach-Object {Quote-Disk $_}) -join ' '
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($si)
    try{$process.WaitForExit();return $process.ExitCode}finally{$process.Dispose()}
}
if($StartEngine -or $OpenWindow){
    . (Join-Path $PSScriptRoot 'Disk.Common.ps1')
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'transport/Transport.Common.ps1')
    if(-not $LauncherHome){$LauncherHome=Join-Path $env:LOCALAPPDATA 'RemoteAgents'}
    $script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'
    $lease=$null
    try{
        $config=Join-Path $LauncherHome 'config.json'
        if(Test-Path -LiteralPath $config){$c=[IO.File]::ReadAllText($config)|ConvertFrom-Json;if($c.disk.home){$script:DiskHome=[Environment]::ExpandEnvironmentVariables([string]$c.disk.home)}}
        if($OpenWindow){exit (Open-DiskSyncWindow)}
        $lease=Enter-DiskEngineLock $script:DiskHome
        # Stop the old GUI before its monitor/worker, then start one owned worker.
        Stop-DiskEngineProcesses $script:DiskHome
        Set-DiskTrayExternalEngine
        [void](Sync-DiskServerAddress $LauncherHome)
        exit (Start-DiskComponent $lease)
    }catch{Write-DiskLog 'Запуск Syncthing' $_;[Console]::Error.WriteLine('Не удалось запустить Syncthing: '+$_.Exception.Message);exit 1}finally{Stop-DiskHeadless;Exit-DiskEngineLock $lease}
}
