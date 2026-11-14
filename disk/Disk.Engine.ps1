#requires -Version 5.1
[CmdletBinding()]
param([switch]$StartTray,[Alias('Home')][string]$LauncherHome)
# Shared ownership helpers: same embedded engine and state as the former tray.
# Installation and component startup share one per-state lock. Tray itself stays
# unlocked after launch so a later installer can borrow its REST endpoint.
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
        # GUI owns its adjacent ini. Embedded command mode belongs to us only for this state.
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

function Start-DiskTray($StartupLease) {
    $si=New-Object Diagnostics.ProcessStartInfo
    $si.FileName=Join-Path $script:DiskHome 'tray/syncthingtray.exe';$si.WorkingDirectory=Split-Path $si.FileName -Parent
    $si.UseShellExecute=$false
    $process=[Diagnostics.Process]::Start($si)
    Exit-DiskEngineLock $StartupLease
    try{$process.WaitForExit();return $process.ExitCode}finally{$process.Dispose()}
}
if($StartTray){
    . (Join-Path $PSScriptRoot 'Disk.Common.ps1')
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'transport/Transport.Common.ps1')
    $script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'
    if(-not $LauncherHome){$LauncherHome=Join-Path $env:LOCALAPPDATA 'RemoteAgents'}
    $lease=$null
    try{
        $lease=Enter-DiskEngineLock $script:DiskHome
        # An older installer could leave an unowned monitor/worker or GUI behind.
        # Stop this exact executable/state before Tray autostarts inside our Job.
        Stop-DiskEngineProcesses $script:DiskHome
        [void](Sync-DiskServerAddress $LauncherHome)
        # Keep this supervisor child alive for Tray's entire lifetime (the launcher's job owns both).
        exit (Start-DiskTray $lease)
    }catch{Write-DiskLog 'Запуск Syncthing Tray' $_;[Console]::Error.WriteLine('Не удалось запустить Syncthing Tray: '+$_.Exception.Message);exit 1}finally{Exit-DiskEngineLock $lease}
}
