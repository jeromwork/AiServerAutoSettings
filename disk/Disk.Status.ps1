#requires -Version 5.1
[CmdletBinding()]
param([Alias('Home')][string]$LauncherHome=(Join-Path $env:LOCALAPPDATA 'RemoteAgents'),[int]$ParentPid=0,
      [ValidateSet('Status','Open','Pause30','Pause120','Pause','Resume')][string]$Action='Status',[string]$ExpectedUntil,[switch]$Once,[switch]$LibraryOnly)
. (Join-Path $PSScriptRoot 'Disk.Common.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'transport/Transport.Common.ps1')
function Initialize-DiskMonitor([string]$Root) {
    $script:MonitorHome=$Root;$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'
    $config=Join-Path $Root 'config.json'
    if(Test-Path -LiteralPath $config){$c=Read-TransportJson $config;if($c.disk.home){$script:DiskHome=[string]$c.disk.home}}
}
function Start-DiskTray {
    $tray=Join-Path $script:DiskHome 'tray/syncthingtray.exe'
    if(-not (Test-Path -LiteralPath $tray)){return}
    $found=@(Get-Process -Name syncthingtray -ErrorAction SilentlyContinue|Where-Object {try{$_.Path -and [IO.Path]::GetFullPath($_.Path) -ieq [IO.Path]::GetFullPath($tray)}catch{$false}})
    if(-not $found.Count){$created=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=((Quote-Disk $tray)+' --wait')};if($created.ReturnValue -ne 0){throw 'Трей не запущен'}}
}
function Write-DiskMonitorLog([string]$Event) {
    try{$dir=Join-Path $script:MonitorHome 'logs';[void][IO.Directory]::CreateDirectory($dir);$file=Join-Path $dir 'disk.log';if((Test-Path $file) -and (Get-Item $file).Length -ge 1MB){Move-Item $file ($file+'.1') -Force};[IO.File]::AppendAllText($file,([DateTime]::UtcNow.ToString('o')+' '+$Event+"`n"),(New-Object Text.UTF8Encoding($false)))}catch{}
}
function Set-DiskResumeTask($Until) {
    if($env:OS -ne 'Windows_NT'){return}
    $name='RemoteAgents-DiskResume-'+(Get-TransportFingerprint 'resume' $script:MonitorHome.ToLowerInvariant()).Substring(0,24)
    if(-not $Until){if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){Unregister-ScheduledTask -TaskName $name -Confirm:$false};return}
    # Keep a private added copy: a later bundle cleanup cannot remove the timed resume command.
    $sourceRoot=Split-Path $PSScriptRoot -Parent
    $hashes=@('disk/Disk.Status.ps1','disk/Disk.Common.ps1','transport/Transport.Common.ps1')|ForEach-Object {(Get-FileHash -LiteralPath (Join-Path $sourceRoot $_) -Algorithm SHA256).Hash}
    $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($hashes -join ''))))).Replace('-','').Substring(0,24)}finally{$sha.Dispose()}
    $app=Join-Path $script:MonitorHome ('disk-commands/'+$hash)
    foreach($part in @('disk','transport')){[void][IO.Directory]::CreateDirectory((Join-Path $app $part))}
    foreach($path in @('disk/Disk.Status.ps1','disk/Disk.Common.ps1','transport/Transport.Common.ps1')){
        $source=Join-Path $sourceRoot $path;$target=Join-Path $app $path
        if(-not (Test-Path $target) -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash){Copy-Item -LiteralPath $source -Destination $target -Force}
    }
    $arguments=@('-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',(Join-Path $app 'disk/Disk.Status.ps1'),'-Home',$script:MonitorHome,'-Action','Resume','-ExpectedUntil',[string]$Until)
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action=New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -Argument (($arguments|ForEach-Object {Quote-Disk $_}) -join ' ')
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $name -Action $action -Trigger (New-ScheduledTaskTrigger -Once -At (Convert-TransportUtc $Until).ToLocalTime()) -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Settings $settings -Force|Out-Null
}
function Set-DiskPauseInner([string]$Mode) {
    $file=Join-Path $script:MonitorHome 'state/disk-pause.json';$saved=@()
    if(Test-Path -LiteralPath $file){$saved=@((Read-TransportJson $file).folders)}
    if($Mode -eq 'Resume'){
        # Resume only folders paused by this command. Preserve earlier user pauses.
        $current=@(Invoke-DiskApi 'config/folders'|ForEach-Object {$_.id});$failed=$false
        foreach($id in $saved){
            if($id -notin $current){continue} # A removed folder must not block every remaining resume.
            try{[void](Invoke-DiskApi ('config/folders/'+[Uri]::EscapeDataString($id)) PATCH @{paused=$false})}catch{$failed=$true;Write-DiskMonitorLog 'resume.failed'}
        }
        if($failed){throw 'Не все папки возобновлены; повторите команду'}
        if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force};Set-DiskResumeTask $null;Write-DiskMonitorLog 'resume';return
    }
    $until=$null;if($Mode -eq 'Pause30'){$until=[DateTime]::UtcNow.AddMinutes(30).ToString('o')}elseif($Mode -eq 'Pause120'){$until=[DateTime]::UtcNow.AddHours(2).ToString('o')}
    Set-DiskResumeTask $until
    Write-TransportJson $file @{folders=@($saved);until=$until};Write-DiskMonitorLog 'pause'
    foreach($folder in @(Invoke-DiskApi 'config/folders')){
        if($folder.paused){continue}
        if($folder.id -notin $saved){$saved+=([string]$folder.id)}
        # Persist before REST so an interrupted request remains reversible.
        Write-TransportJson $file @{folders=@($saved);until=$until}
        [void](Invoke-DiskApi ('config/folders/'+[Uri]::EscapeDataString($folder.id)) PATCH @{paused=$true})
    }
    Write-TransportJson $file @{folders=@($saved);until=$until}
}
function Set-DiskPause([string]$Mode,[string]$Expected='') {
    $mutex=New-Object Threading.Mutex($false,('RemoteAgentsDiskPause-'+(Get-TransportFingerprint 'pause' $script:MonitorHome.ToLowerInvariant())))
    $locked=$false
    try{try{$locked=$mutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$locked=$true};if(-not $locked){throw 'Диск занят'};if($Expected){$file=Join-Path $script:MonitorHome 'state/disk-pause.json';if(-not (Test-Path $file) -or (Read-TransportJson $file).until -cne $Expected){return}};Set-DiskPauseInner $Mode}finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Get-DiskMonitorStatus {
    $result=@{ok=$false;summary='Syncthing не запущен';folders=@();connected=$false;updatedAt=[DateTime]::UtcNow.ToString('o')}
    try {
        $null=Invoke-DiskApi 'system/status'
        $result.summary='Нет связи с сервером'
        $serverFile=Join-Path $script:DiskHome 'server.txt'
        if(-not (Test-Path -LiteralPath $serverFile)){return $result}
        $server=[IO.File]::ReadAllText($serverFile).Trim()
        $connections=Invoke-DiskApi 'system/connections';$peer=$connections.connections.PSObject.Properties[$server]
        $result.connected=[bool]($peer -and $peer.Value.connected)
        $rows=@();$ready=0;$bytes=0L;$paused=0;$errors=0
        foreach($folder in @(Invoke-DiskApi 'config/folders')){
            if(-not @($folder.devices|Where-Object {$_.deviceID -ceq $server}).Count){continue}
            $db=Invoke-DiskApi ('db/status?folder='+[Uri]::EscapeDataString($folder.id))
            $state=[string]$db.state;$completion=0.0
            if($folder.paused){$state='paused';$paused++}
            if($db.error -or [int]$db.pullErrors -gt 0 -or $state -eq 'error'){$state='error';$errors++}
            $total=[double]$db.globalBytes;$need=[double]$db.needBytes;$bytes+=[long]$need
            $completion=100.0;if($total -gt 0){$completion=[Math]::Max(0,[Math]::Min(100,100*(1-$need/$total)))}
            if($state -eq 'idle' -and [int]$db.needTotalItems -eq 0 -and $need -eq 0){$ready++}
            $rows+=@{id=$folder.id;label=$folder.label;state=$state;completion=[Math]::Round($completion,1)}
        }
        $result.folders=@($rows)
        if(-not $result.connected){return $result}
        $result.ok=($errors -eq 0 -and $paused -eq 0)
        if($paused){$result.summary='Синхронизация на паузе: '+$paused+' папок'}
        elseif($errors){$result.summary='Ошибка синхронизации: '+$errors+' папок'}
        elseif($ready -eq $rows.Count){$result.summary='Синхронизировано: '+$rows.Count+' папок'}
        else{$size=('{0:N1} ГБ' -f ($bytes/1GB));$result.summary='Синхронизация: '+$ready+' из '+$rows.Count+', '+$size}
    }catch{} # REST errors never expose the API key or response body.
    $result
}
if($LibraryOnly){return}
Initialize-DiskMonitor $LauncherHome
if($Action -eq 'Open'){Start-Process explorer.exe -ArgumentList (Quote-Disk (Get-DiskBase));return}
if($Action -ne 'Status'){
    Set-DiskPause $Action -Expected $ExpectedUntil;return
}
Write-DiskMonitorLog 'start';$lastDiskState=''
$parent=$null;if($ParentPid -gt 0){$parent=[Diagnostics.Process]::GetProcessById($ParentPid);[void]$parent.Handle}
do {
    try{Start-DiskTray}catch{}
    $pauseFile=Join-Path $LauncherHome 'state/disk-pause.json'
    try{if(Test-Path -LiteralPath $pauseFile){$pause=Read-TransportJson $pauseFile;if($pause.until -and (Convert-TransportUtc $pause.until) -le [DateTime]::UtcNow){Set-DiskPause Resume}}}catch{}
    $status=Get-DiskMonitorStatus;Write-TransportJson (Join-Path $LauncherHome 'status/disk.json') $status
    $state=[string]$status.summary;if($state -cne $lastDiskState){Write-DiskMonitorLog ('status '+$state);$lastDiskState=$state}
    if($Once){break}
    for($i=0;$i -lt 10;$i++){if(($parent -and $parent.HasExited) -or (Test-Path -LiteralPath (Join-Path $LauncherHome 'stop'))){return};Start-Sleep -Seconds 1}
}while($true)
# The independently created tray deliberately survives monitor/launcher exit.
