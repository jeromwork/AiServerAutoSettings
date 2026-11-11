#requires -Version 5.1
# Small Windows adapters are deliberately replaceable in offline tests.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'transport/Transport.Common.ps1')
function Get-MigrationStatePath([string]$Root){Join-Path $Root 'state/migration.json'}
function Write-MigrationLog([string]$Root,[string]$Event,[string]$Detail=''){
    $dir=Join-Path $Root 'logs';[void][IO.Directory]::CreateDirectory($dir);$file=Join-Path $dir 'migration.log'
    if((Test-Path $file) -and (Get-Item $file).Length -gt 1MB){Move-Item $file ($file+'.1') -Force}
    [IO.File]::AppendAllText($file,([DateTime]::UtcNow.ToString('o')+' '+$Event+$(if($Detail){' '+$Detail}else{''})+"`n"),(New-Object Text.UTF8Encoding($false)))
}
function Invoke-MigrationLock([string]$Root,[scriptblock]$Body,[int]$TimeoutMs=1000){
    $mutex=New-Object Threading.Mutex($false,('Global\RemoteAgentsMigration-'+(Get-TransportFingerprint 'migration' (Get-TransportHome $Root).ToLowerInvariant())))
    $locked=$false
    try{try{$locked=$mutex.WaitOne($TimeoutMs)}catch [Threading.AbandonedMutexException]{$locked=$true};if(-not $locked){throw 'Переход уже выполняется'};& $Body}finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Update-MigrationConfig([string]$Root,[scriptblock]$Edit){
    $mutex=New-Object Threading.Mutex($false,('Global\RemoteAgentsConfig-'+(Get-TransportFingerprint 'config' (Get-TransportHome $Root).ToLowerInvariant())))
    $locked=$false
    try{
        try{$locked=$mutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$locked=$true};if(-not $locked){throw 'Конфиг занят'}
        $path=Join-Path $Root 'config.json';$c=[pscustomobject]@{};if(Test-Path -LiteralPath $path){$c=Read-TransportJson $path}
        & $Edit $c;Write-TransportJson $path $c -Durable
    }finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Set-MigrationDefault($Object,[string]$Key,$Value){if(-not $Object.PSObject.Properties[$Key]){$Object|Add-Member $Key $Value}}
function Import-MigrationConfig([string]$Root,[string]$DiskHome){
    Update-MigrationConfig $Root {
        param($c)
        Set-MigrationDefault $c schema 1;Set-MigrationDefault $c version 1
        if($c.schema -ne 1){throw 'Неизвестная схема'}
        Set-MigrationDefault $c transport ([pscustomobject]@{});$t=$c.transport
        Set-MigrationDefault $t profilePath ([IO.File]::ReadAllText((Join-Path $DiskHome 'profile.txt')).Trim())
        Set-MigrationDefault $t channelPath (Join-Path $DiskHome 'channel/config.json')
        Set-MigrationDefault $t singBoxPath (Join-Path $DiskHome 'channel/sing-box.exe')
        $channel=Read-TransportJson $t.channelPath
        $sync=@($channel.inbounds|Where-Object {$_.tag -eq 'sync' -or $_.override_port -eq 22000})
        if($sync.Count -ne 1){throw 'Не определён вход синхронизации'}
        Set-MigrationDefault $t syncPort ([int]$sync[0].listen_port);Set-MigrationDefault $t sshPort 2222
        foreach($key in @('entries','relays','hops','cdn')){Set-MigrationDefault $t $key @()}
        $issues=@(Import-TransportLegacyRoutes $t $channel $t.channelPath (Read-TransportJson $t.profilePath))
        foreach($issue in $issues){Write-MigrationLog $Root 'import.unsupported' ($issue.id+' '+$issue.reason)}
        if($issues.Count){throw 'Старый канал содержит неподдерживаемый путь; переход отменён, прежний канал сохранён. См. migration.log'}
        Set-MigrationDefault $t routeSsh $true;Set-MigrationDefault $t takeOverChannel $true
        Set-MigrationDefault $c disk ([pscustomobject]@{});Set-MigrationDefault $c.disk home $DiskHome
        Set-MigrationDefault $c components ([pscustomobject]@{})
        foreach($name in @('transport','disk','control')){Set-MigrationDefault $c.components $name ([pscustomobject]@{});$on=$true;if($name -eq 'control' -and $c.bridge -and $c.bridge.enabled -eq $false){$on=$false};$c.components.$name|Add-Member -Force enabled $on}
    }
    Read-TransportJson (Join-Path $Root 'config.json')
}
function Get-MigrationMarker([string]$Root){'RemoteAgents transport '+(Get-TransportFingerprint 'ssh' (Get-TransportHome $Root).ToLowerInvariant())}
function Remove-MigrationBlockText([string]$Text,[string]$Root){
    $marker=[regex]::Escape((Get-MigrationMarker $Root))
    $pattern='(?m)^# BEGIN '+$marker+'\r?\n[\s\S]*?^# END '+$marker+'(?:\r?\n|$)'
    [regex]::Replace($Text,$pattern,'')
}
function Set-MigrationSshBlock([string]$Path,[string]$Root,[string]$Server,[int]$Port,[switch]$Remove,[switch]$OriginallyAbsent){
    if($Server -cnotmatch '^[a-zA-Z0-9_.:\-]+$' -or $Port -lt 1 -or $Port -gt 65535){throw 'Недопустимый адрес или порт SSH'}
    $exists=[IO.File]::Exists($Path);if($Remove -and -not $exists){return}
    $raw=[byte[]]@();if($exists){$raw=[IO.File]::ReadAllBytes($Path)};$bom=$raw.Length -ge 3 -and $raw[0] -eq 239 -and $raw[1] -eq 187 -and $raw[2] -eq 191
    $text=[Text.Encoding]::UTF8.GetString($raw).TrimStart([char]0xFEFF);$clean=Remove-MigrationBlockText $text $Root
    if(-not $Remove){
        $nl="`n";if($clean.Contains("`r`n")){$nl="`r`n"};$marker=Get-MigrationMarker $Root
        # First value wins in OpenSSH. Reset scope before the preexisting config.
        $block=@(('# BEGIN '+$marker),('Host "'+$Server+'"'),'    ProxyCommand none','    ProxyJump none','    HostName 127.0.0.1',('    Port '+$Port),('    HostKeyAlias '+$Server),'Host *',('# END '+$marker),'') -join $nl
        $clean=$block+$clean
    }
    if($clean -ceq $text){return}
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path)))
    $temp=$Path+'.remoteagents.'+[Guid]::NewGuid().ToString('N')+'.tmp';try{
        [IO.File]::WriteAllText($temp,$clean,(New-Object Text.UTF8Encoding($bom)))
        if($exists){
            if([Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) -cne [Convert]::ToBase64String($raw)){throw 'SSH config изменён одновременно; переход отменён'}
            [IO.File]::Replace($temp,$Path,($temp+'.old'))
            if($Remove -and $OriginallyAbsent -and $clean.Length -eq 0){[IO.File]::Delete($Path)}
        }else{[IO.File]::Move($temp,$Path)}
    }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force};if(Test-Path -LiteralPath ($temp+'.old')){Remove-Item -LiteralPath ($temp+'.old') -Force}}
}
function Get-MigrationRun([string]$Name){
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
    try{if($key){$key.GetValue($Name,$null)}}finally{if($key){$key.Dispose()}}
}
function Set-MigrationRun([string]$Name,$Value){
    $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
    try{if($null -eq $Value){$key.DeleteValue($Name,$false)}else{$key.SetValue($Name,[string]$Value)}}finally{$key.Dispose()}
}
function Get-MigrationTask([string]$Name){
    $task=Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if($task){[pscustomobject]@{exists=$true;enabled=[bool]$task.Settings.Enabled;running=($task.State -eq 'Running')}}else{[pscustomobject]@{exists=$false;enabled=$false;running=$false}}
}
function Suspend-MigrationChannel([string]$Name){
    Disable-ScheduledTask -TaskName $Name|Out-Null;Stop-ScheduledTask -TaskName $Name
}
function Restore-MigrationChannel([string]$Name,$Snapshot){
    if(-not $Snapshot.exists){return}
    # A task can be disabled while an already running instance is still alive.
    # Scheduler refuses Start on a disabled task: enable for start, then restore its flag.
    if($Snapshot.enabled -or $Snapshot.running){Enable-ScheduledTask -TaskName $Name|Out-Null}
    if($Snapshot.running){Start-ScheduledTask -TaskName $Name}
    if(-not $Snapshot.enabled){Disable-ScheduledTask -TaskName $Name|Out-Null}
}
function Start-MigrationDetached([string]$Exe,[string[]]$Arguments){
    $created=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=((Quote-Transport $Exe)+' '+(($Arguments|ForEach-Object {Quote-Transport $_}) -join ' '))}
    if($created.ReturnValue -ne 0){throw 'Не удалось запустить процесс'}
}
function Start-MigrationRun([string]$Command){
    if(-not $Command){return}
    $created=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$Command}
    if($created.ReturnValue -ne 0){throw 'Не удалось восстановить автозапуск'}
}
function Register-MigrationRollback([string]$Root,[string]$Bundle,$State){
    # Recovery code must outlive bundle cleanup and a damaged current components.json.
    $recovery=Join-Path $Root ('state/migration-recovery/'+$State.session)
    foreach($part in @('build/Rollback.ps1','build/Migrate.Common.ps1','transport/Transport.Common.ps1','disk/Disk.Engine.ps1','disk/Disk.NavPane.ps1')){
        $target=Join-Path $recovery $part;[void][IO.Directory]::CreateDirectory((Split-Path $target -Parent));Copy-Item -LiteralPath (Join-Path $Bundle $part) -Destination $target -Force
    }
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    $arguments=@('-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',(Join-Path $recovery 'build/Rollback.ps1'),'-Home',$Root,'-Session',$State.session,'-Watchdog')
    $action=New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -Argument (($arguments|ForEach-Object {Quote-Transport $_}) -join ' ')
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $State.names.rollbackTask -Action $action -Trigger @((New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(10)),(New-ScheduledTaskTrigger -AtLogOn -User $user)) -Settings $settings -Principal $principal -Force|Out-Null
    $registered=Get-MigrationTask $State.names.rollbackTask
    if(-not $registered.exists -or -not $registered.enabled){throw 'Откат не зарегистрирован'}
    # Start the independent monotonic watchdog now. A future wall-clock trigger alone can
    # be postponed indefinitely by a clock correction. Logon/future triggers are recovery paths.
    Start-ScheduledTask -TaskName $State.names.rollbackTask -ErrorAction Stop
    $wait=[Diagnostics.Stopwatch]::StartNew()
    do{
        if((Get-MigrationTask $State.names.rollbackTask).running){return}
        Start-Sleep -Milliseconds 100
    }while($wait.Elapsed.TotalSeconds -lt 10)
    throw 'Независимый watchdog не запущен'

}
function Wait-MigrationDeadline([string]$Root,[string]$Session,[double]$TimeoutSeconds=600){
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do{
        $state=Read-TransportJson (Get-MigrationStatePath $Root)
        if($state.session -cne $Session -or $state.phase -in @('accepted','rolled-back')){return $false}
        $age=([DateTime]::UtcNow-(Convert-TransportUtc $state.startedAt)).TotalSeconds
        if($age -ge 600 -or $watch.Elapsed.TotalSeconds -ge $TimeoutSeconds){return $true}
        Start-Sleep -Milliseconds 250
    }while($true)
}
function Get-MigrationRecoveryTaskName([string]$Root,$State){
    $State.names.launcherRun+'-Recovery-'+(Get-TransportFingerprint 'recovery' (Get-TransportHome $Root).ToLowerInvariant()).Substring(0,24)
}
function Register-MigrationRecovery([string]$Root,$State){
    $name=Get-MigrationRecoveryTaskName $Root $State;$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    # The EXE itself becomes the foreground task action when recovery is needed. No child
    # can be lost when a short-lived scheduler action exits. Its Global mutex prevents duplicates.
    $source=Join-Path $Root 'RemoteAgents.exe';$hostExe=Join-Path $Root ('state/migration-recovery/'+$State.session+'/RemoteAgents.Recovery.exe')
    [void][IO.Directory]::CreateDirectory((Split-Path $hostExe -Parent))
    if(-not (Test-Path -LiteralPath $hostExe) -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $hostExe -Algorithm SHA256).Hash){Copy-Item -LiteralPath $source -Destination $hostExe -Force}
    $action=New-ScheduledTaskAction -Execute $hostExe -Argument ('--recovery-host --home '+(Quote-Transport $Root))
    $trigger=@((New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)),(New-ScheduledTaskTrigger -AtLogOn -User $user))
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force|Out-Null
    $registered=Get-MigrationTask $name
    if(-not $registered.exists -or -not $registered.enabled){throw 'Не зарегистрировано восстановление лаунчера'}
}
function Unregister-MigrationRecovery([string]$Root,$State){
    $name=Get-MigrationRecoveryTaskName $Root $State
    if((Get-MigrationTask $name).exists){Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop}
}
function Unregister-MigrationRollback([string]$Name){Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction Stop}
function Stop-MigrationLauncher([string]$Root){
    $exe=Join-Path $Root 'RemoteAgents.exe'
    $running=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -and $_.ExecutablePath -ieq $exe -and $_.CommandLine -notmatch '(?:--exit|--uninstall|--install)'})
    if(-not $running.Count){return}
    if(Test-Path -LiteralPath $exe){$p=Start-Process -FilePath $exe -ArgumentList ('--exit --home '+(Quote-Transport $Root)) -PassThru -WindowStyle Hidden;if(-not $p.WaitForExit(30000)){throw 'Лаунчер не остановлен'}}
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    do{
        $live=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -and $_.ExecutablePath -ieq $exe -and $_.ProcessId -ne $PID -and $_.CommandLine -notmatch '(?:--exit|--uninstall|--install)'})
        if(-not $live.Count){return}
        if([DateTime]::UtcNow -ge $deadline){
            foreach($item in $live){& "$env:SystemRoot/System32/taskkill.exe" /PID $item.ProcessId /T /F *> $null}
            Start-Sleep -Milliseconds 500
            if(@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -and $_.ExecutablePath -ieq $exe -and $_.CommandLine -notmatch '(?:--exit|--uninstall|--install)'}).Count){throw 'Лаунчер не остановлен'}
            return
        }
        Start-Sleep -Milliseconds 250
    }while($true)
}
function Stop-MigrationControl([string]$Root){
    $file=Join-Path $Root 'managed-control/control.pid'
    if(Test-Path -LiteralPath $file){
        $id=0;if([int]::TryParse([IO.File]::ReadAllText($file).Trim(),[ref]$id)){
            $p=Get-CimInstance Win32_Process -Filter "ProcessId=$id"
            if($p -and $p.CommandLine -match 'Start-WindowsControl\.ps1' -and ([string]$p.CommandLine).IndexOf($Root,[StringComparison]::OrdinalIgnoreCase) -ge 0){& "$env:SystemRoot/System32/taskkill.exe" /T /F /PID $id *> $null}
        }
    }
}
function Stop-MigrationDisk([string]$DiskRoot){
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'disk/Disk.Engine.ps1')
    Stop-DiskEngineProcesses $DiskRoot
}
function Remove-MigrationNavPane {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'disk/Disk.NavPane.ps1')
    Remove-DiskNavPane
}
function Start-MigrationControl([string]$Root,[string]$Bundle,$State){
    # Existing -Uninstall stops only the old control PID and removes its Run value.
    & (Join-Path $Bundle 'Start-WindowsControl.ps1') -Uninstall -KeepState
    & (Join-Path $Bundle 'Start-WindowsControl.ps1') -Install -LauncherHome $Root
}
function Test-MigrationFresh([string]$Root,[string]$Name){
    $file=Join-Path $Root ('status/'+$Name+'.json')
    if(-not (Test-Path $file)){return $false}
    $c=Read-TransportJson $file;if($Name -eq 'transport' -and $c.configError){return $false};$age=([DateTime]::UtcNow-(Convert-TransportUtc $c.updatedAt)).TotalSeconds
    [bool]($c.ok -and $age -ge -5 -and $age -le 30)
}
function Test-MigrationSsh([string]$Root,[int]$Port){
    $c=Read-TransportJson (Join-Path $Root 'config.json');$profile=Read-TransportJson $c.transport.profilePath
    $child=$null
    try{
        $child=Start-TransportProcess $profile.sshExecutable ((Get-TransportSshArguments $profile $Port)+@('127.0.0.1','true'))
        if(-not $child.Process.WaitForExit(15000)){return $false};$child.Process.ExitCode -eq 0
    }finally{Stop-TransportProcess $child}
}
function Get-MigrationBridgeProbe {
    # Read-only authenticated round trip: server socket -> reverse SSH -> this Windows executor.
    # No token is read, persisted or included in argv; the existing broker supplies it in memory.
    @'
import base64, json, os, pwd, runpy, sys
from pathlib import Path
home = Path(pwd.getpwuid(os.getuid()).pw_dir)
sys.path.insert(0, str(home / '.local/share/codex-remote'))
bridge = runpy.run_path(str(home / '.local/share/codex-remote/codex-windows-bridge.py'))
expected = json.loads(base64.b64decode(sys.argv[1]))
record = next(r for r in bridge['catalog_api'].records(home / '.local/share/remote-agents-nodes', home) if r['projectId'] == 'control' and r['hostId'] == expected['hostId'])
assert record['windowsReplica'].casefold().rstrip('\\') == expected['workspace'].casefold().rstrip('\\')
assert record.get('controlOnly') is True
if 'allowShell' in expected: assert bool(record.get('allowShell')) == expected['allowShell']
status = bridge['exchange'](record['socketPath'], 'status', {}, record, timeout=5)
assert bridge['catalog_api'].matches(record, status)
if 'allowShell' in expected: assert bool(status.get('shell_enabled')) == expected['allowShell']
print('migration-bridge-ok')
'@
}
function Test-MigrationBridge([string]$Root){
    try{
        $control=Read-TransportJson (Join-Path $env:LOCALAPPDATA 'RemoteAgents/control/config.json')
        $profile=Read-TransportJson $control.profile
        $hostId=Split-Path (Split-Path ([IO.Path]::GetFullPath($control.profile)) -Parent) -Leaf
        if($hostId -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$' -or $control.agentUser -cnotmatch '^[a-z_][a-z0-9_-]*$'){return $false}
        $expected=@{hostId=$hostId;workspace=(Join-Path $env:LOCALAPPDATA 'RemoteAgents/control/workspace')}
        $data=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $expected -Compress)))
        $code=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-MigrationBridgeProbe)))
        $command='python3 -c ''import base64;exec(base64.b64decode("'+$code+'"))'' '''+$data+''''
        if($control.agentUser -cne $profile.login){$command='sudo -n -H -u '+$control.agentUser+' -- '+$command}
        $config=Read-TransportJson (Join-Path $Root 'config.json')
        $reply=Invoke-TransportText $profile.sshExecutable ((Get-TransportSshArguments $profile ([int]$config.transport.sshPort))+@('127.0.0.1',$command))
        $reply.Trim() -ceq 'migration-bridge-ok'
    }catch{return $false}
}
function Test-MigrationHealth([string]$Root){
    $config=Read-TransportJson (Join-Path $Root 'config.json')
    if(-not (Test-MigrationFresh $Root transport) -or -not (Test-MigrationFresh $Root disk)){return $false}
    $bridgeEnabled= -not ($config.bridge -and $config.bridge.enabled -eq $false)
    if($bridgeEnabled -and -not (Test-MigrationFresh $Root control)){return $false}
    $disk=Read-TransportJson (Join-Path $Root 'status/disk.json');if(-not $disk.connected){return $false}
    if(-not (Test-MigrationSsh $Root ([int]$config.transport.sshPort))){return $false}
    if($bridgeEnabled){Test-MigrationBridge $Root}else{$true}
}
function Wait-MigrationTransport([string]$Root,[int]$Timeout=180){
    $deadline=[DateTime]::UtcNow.AddSeconds($Timeout)
    do{if(Test-MigrationFresh $Root transport){return};Start-Sleep -Seconds 1}while([DateTime]::UtcNow -lt $deadline)
    throw 'Нет проверенного transport'
}
function Invoke-MigrationPreflight([string]$Root,[string]$Bundle,$Config){
    $probe=Join-Path $Root 'state/migration-probe';[void][IO.Directory]::CreateDirectory($probe)
    $copy=Copy-TransportObject $Config
    # The migration must not skip the only working legacy path on a metered/unknown network.
    $copy.transport|Add-Member -Force metered 'false'
    $copy.transport|Add-Member -Force rankProbeBytes 65536
    $copy.transport|Add-Member -Force rankConcurrency 4
    if($env:REMOTEAGENTS_WIZARD_PROGRESS){$copy.transport|Add-Member -Force probeTimeoutSec 5;$copy.transport|Add-Member -Force stallSeconds 5}
    # Reserve a disjoint block for inbounds, ranking probes and local SSH socks. Fail if occupied.
    $listeners=@();$ports=@()
    try{
        # Probe/socks use consecutive ranges; use explicit, checked ranges away from production defaults.
        foreach($base in @(34000,36000)){for($i=0;$i -lt 128;$i++){$socket=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,($base+$i));$socket.Start();$listeners+=,$socket}}
        for($i=0;$i -lt 3;$i++){$socket=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$socket.Start();$listeners+=,$socket;$ports+=([int]$socket.LocalEndpoint.Port)}
        $copy.transport|Add-Member -Force sshPort $ports[0];$copy.transport|Add-Member -Force syncPort $ports[1];$copy.transport|Add-Member -Force apiPort $ports[2]
        $copy.transport|Add-Member -Force probePortBase 34000;$copy.transport|Add-Member -Force socksPortBase 36000
        Write-TransportJson (Join-Path $probe 'config.json') $copy
        foreach($name in @('transport-pin.json','transport-memory.json')){
            $source=Join-Path $Root ('state/'+$name);$target=Join-Path $probe ('state/'+$name)
            if(Test-Path $source){$value=Read-TransportJson $source;Write-TransportJson $target $value -Private}elseif(Test-Path $target){Remove-Item -LiteralPath $target -Force}
        }
        # Only entry caches are copied; profiles and channel stay read-only references.
        $cache=Join-Path $Root 'secrets/entries';if(Test-Path $cache){$dest=Join-Path $probe 'secrets/entries';[void][IO.Directory]::CreateDirectory($dest);Protect-TransportPath $dest;Copy-Item -Path (Join-Path $cache '*.json') -Destination $dest -Force}
    }finally{foreach($socket in $listeners){$socket.Stop()}}
    $stop=Join-Path $probe 'stop';if(Test-Path $stop){Remove-Item $stop -Force}
    $status=Join-Path $probe 'status/transport.json';if(Test-Path $status){Remove-Item -LiteralPath $status -Force}
    $child=$null
    try{
        $child=Start-TransportProcess (Get-TransportPowerShell) @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $Bundle 'transport/Transport.Daemon.ps1'),'-Home',$probe,'-ParentPid',[string]$PID)
        if($env:REMOTEAGENTS_WIZARD_PROGRESS){Wait-MigrationTransport $probe 45}else{Wait-MigrationTransport $probe}
        if(-not (Test-MigrationSsh $probe $ports[0])){throw 'SSH на временном входе не прошёл'}
        Write-MigrationLog $Root 'preflight.ok'
    }catch{
        $message=Write-MigrationPreflightFailure $Root $probe
        throw $message
    }finally{
        [IO.File]::WriteAllText($stop,'stop');if($child){[void]$child.Process.WaitForExit(10000)};Stop-TransportProcess $child
    }
}
function Merge-MigrationProbeMemory([string]$Root){
    $probe=Join-Path $Root 'state/migration-probe';$status=Join-Path $probe 'status/transport.json'
    if(-not (Test-Path $status)){return};$network=[string](Read-TransportJson $status).network
    if(-not $network){return}
    $measured=Read-TransportMemory $probe
    if(-not $measured.networks.ContainsKey($network)){return}
    $memory=Read-TransportMemory $Root;$memory.networks[$network]=$measured.networks[$network]
    Write-TransportJson (Join-Path $Root 'state/transport-memory.json') $memory -Private
    # Main daemon treats saved ok as remembered and re-probes it, never as healthy.
}
function Get-MigrationProfiles($Config){
    $paths=@([string]$Config.transport.profilePath)
    $oldControl=Join-Path $env:LOCALAPPDATA 'RemoteAgents/control/config.json'
    if(Test-Path $oldControl){$control=Read-TransportJson $oldControl;if($control.profile){$paths+=([string]$control.profile)}}
    @($paths|Select-Object -Unique|ForEach-Object {
        $p=Read-TransportJson $_
        if(-not $p.configPath -or $p.serverAddress -ne (Read-TransportJson $Config.transport.profilePath).serverAddress){throw 'Профили моста и диска должны вести к одному серверу'}
        [pscustomobject]@{path=[string]$p.configPath;server=[string]$p.serverAddress;existed=[IO.File]::Exists($p.configPath)}
    }|Sort-Object -Property path -Unique)
}
function Invoke-MigrationTransition([string]$Root,[string]$Bundle,[string]$DiskHome,$Names,[bool]$DryRun=$false){
    $statePath=Get-MigrationStatePath $Root
    if(Test-Path $statePath){
        $old=Read-TransportJson $statePath
        if($old.phase -eq 'pending'){
            $watchdog=Get-MigrationTask $old.names.rollbackTask
            $age=([DateTime]::UtcNow-(Convert-TransportUtc $old.startedAt)).TotalSeconds
            if(-not $watchdog.exists -or -not $watchdog.enabled -or $age -lt -5 -or $age -ge 600){Invoke-MigrationRollback $Root $old.session;throw 'Переход не подтверждён вовремя или отсутствует watchdog; выполнен откат'}
        }
        if($old.phase -in @('accepted','pending')){Write-MigrationLog $Root 'install.already';Start-MigrationDetached (Join-Path $Root 'RemoteAgents.exe') @('--tray','--home',$Root);return}
        if($old.phase -in @('preparing','activating','rolling-back')){Invoke-MigrationRollback $Root $old.session}
    }
    $failure=Join-Path $Root 'state/migration-error.json';if(Test-Path $failure){Remove-Item -LiteralPath $failure -Force}
    Write-MigrationLog $Root 'import.start'
    $config=Import-MigrationConfig $Root $DiskHome
    $profiles=@();if($config.transport.routeSsh){$profiles=@(Get-MigrationProfiles $config)}
    $snapshot=Get-MigrationTask $Names.channelTask
    # Refuse shared fixed-port startup if channel ownership has not been requested.
    if(-not $config.transport.takeOverChannel -and ($snapshot.enabled -or $snapshot.running)){throw 'Канал работает: требуется takeOverChannel=true'}
    $state=[pscustomobject]@{schema=1;session=[Guid]::NewGuid().ToString('N');phase='preparing';names=$Names;diskHome=$DiskHome;diskRun=(Get-MigrationRun $Names.diskRun);controlRun=(Get-MigrationRun $Names.controlRun);launcherRun=(Get-MigrationRun $Names.launcherRun);channel=$snapshot;profiles=@($profiles);sshPort=[int]$config.transport.sshPort;startedAt=[DateTime]::UtcNow.ToString('o');greenSince=$null;lastHealthyAt=$null;dryRun=$DryRun;controlChanged=$false;channelChanged=$false;diskChanged=$false;launcherChanged=$false;launcherTouched=$false}
    Write-TransportJson $statePath $state -Durable
    Write-MigrationLog $Root 'watchdog.register'
    Register-MigrationRollback $Root $Bundle $state # Must succeed before touching running services.
    try{
        Write-MigrationLog $Root 'preflight.start'
        Invoke-MigrationPreflight $Root $Bundle $config
        $state.diskChanged=$true;Write-TransportJson $statePath $state -Durable
        Set-MigrationRun $Names.diskRun $null
        Stop-MigrationDisk $DiskHome
        $state.launcherTouched=$true;Write-TransportJson $statePath $state -Durable
        Stop-MigrationLauncher $Root
        Merge-MigrationProbeMemory $Root
        Write-MigrationLog $Root 'cutover.start'
        $state.phase='activating';Write-TransportJson $statePath $state -Durable
        if($config.transport.takeOverChannel -and $snapshot.exists){$state.channelChanged=$true;Write-TransportJson $statePath $state -Durable;Suspend-MigrationChannel $Names.channelTask}
        # The two-minute bundle health window starts at the first working launcher launch,
        # after preflight. The independent ten-minute migration deadline is never extended.
        foreach($record in @('pending.json','exe-upgrade.json')){
            $path=Join-Path $Root ('bundle/'+$record)
            if(Test-Path $path){$upgrade=Read-TransportJson $path;if($upgrade.version -eq (Split-Path $Bundle -Leaf)){$upgrade.startedUtc=[DateTime]::UtcNow.ToString('o');Write-TransportJson $path $upgrade}}
        }
        $status=Join-Path $Root 'status/transport.json';if(Test-Path $status){Remove-Item -LiteralPath $status -Force}
        Start-MigrationDetached (Join-Path $Root 'RemoteAgents.exe') @('--tray','--home',$Root)
        Write-MigrationLog $Root 'cutover.wait-transport'
        Wait-MigrationTransport $Root
        if(-not (Test-MigrationSsh $Root $state.sshPort)){throw 'SSH на рабочем входе не прошёл'}
        Write-MigrationLog $Root 'cutover.ssh-ok'
        if($config.transport.routeSsh){foreach($p in $profiles){Set-MigrationSshBlock $p.path $Root $p.server $state.sshPort}}
        if($config.transport.routeSsh -and $state.controlRun){$state.controlChanged=$true;Write-TransportJson $statePath $state -Durable;Start-MigrationControl $Root $Bundle $state}
        $state.diskChanged=$true;$state.launcherChanged=$true;Write-TransportJson $statePath $state -Durable
        Set-MigrationRun $Names.diskRun $null
        Set-MigrationRun $Names.launcherRun ((Quote-Transport (Join-Path $Root 'RemoteAgents.exe'))+' --tray --home '+(Quote-Transport $Root))
        $state.phase='pending';Write-TransportJson $statePath $state -Durable;Write-MigrationLog $Root 'install.pending'
    }catch{Write-MigrationLog $Root 'install.failed';Invoke-MigrationRollback $Root $state.session;throw}
}
function Invoke-MigrationRollback([string]$Root,[string]$Session='',[switch]$Force){
    $file=Get-MigrationStatePath $Root;if(-not (Test-Path $file)){return}
    $state=Read-TransportJson $file
    if(($Session -and $state.session -ne $Session) -or $state.phase -eq 'rolled-back' -or ($state.phase -eq 'accepted' -and -not $Force)){return}
    $state.phase='rolling-back';Write-TransportJson $file $state -Durable;Write-MigrationLog $Root 'rollback.start'
    # Best effort for every independent restoration; failed items remain retryable.
    $failed=$false
    try{Unregister-MigrationRecovery $Root $state}catch{$failed=$true;Write-MigrationLog $Root 'rollback.recovery-task.failed'}
    try{if(-not $state.PSObject.Properties['launcherTouched'] -or $state.launcherTouched){Stop-MigrationLauncher $Root}}catch{$failed=$true;Write-MigrationLog $Root 'rollback.launcher.failed'}
    foreach($p in @($state.profiles)){try{Set-MigrationSshBlock $p.path $Root $p.server $state.sshPort -Remove -OriginallyAbsent:($p.PSObject.Properties['existed'] -and -not $p.existed)}catch{$failed=$true;Write-MigrationLog $Root 'rollback.ssh.failed'}}
    if($state.controlChanged){try{Stop-MigrationControl $Root;Set-MigrationRun $state.names.controlRun $state.controlRun;Start-MigrationRun $state.controlRun}catch{$failed=$true;Write-MigrationLog $Root 'rollback.control.failed'}}
    if($state.channelChanged){try{Restore-MigrationChannel $state.names.channelTask $state.channel}catch{$failed=$true;Write-MigrationLog $Root 'rollback.channel.failed'}}
    if($state.diskChanged){try{$diskRoot=Join-Path $env:LOCALAPPDATA 'RemoteDisk';if($state.PSObject.Properties['diskHome'] -and $state.diskHome){$diskRoot=[string]$state.diskHome};Stop-MigrationDisk $diskRoot;Set-MigrationRun $state.names.diskRun $state.diskRun;if($state.diskRun){Start-MigrationRun $state.diskRun}}catch{$failed=$true;Write-MigrationLog $Root 'rollback.disk.failed'}}
    try{Remove-MigrationNavPane}catch{$failed=$true;Write-MigrationLog $Root 'rollback.navpane.failed'}
    if($state.launcherChanged){try{$oldRun=$state.launcherRun;if($oldRun -and $oldRun.IndexOf((Join-Path $Root 'RemoteAgents.exe'),[StringComparison]::OrdinalIgnoreCase) -ge 0){$oldRun=$null};Set-MigrationRun $state.names.launcherRun $oldRun}catch{$failed=$true;Write-MigrationLog $Root 'rollback.run.failed'}}
    # Disable supervised transport on later manual starts, without overwriting other config keys.
    try{Update-MigrationConfig $Root {param($c) foreach($name in @('transport','disk','control')){if($c.components.$name){$c.components.$name|Add-Member -Force enabled $false}}}}catch{$failed=$true}
    if($failed){Write-MigrationLog $Root 'rollback.incomplete';throw 'Откат неполный: смотрите migration.log'}
    $state.phase='rolled-back';Write-TransportJson $file $state -Durable
    if((Get-MigrationTask $state.names.rollbackTask).exists){Unregister-MigrationRollback $state.names.rollbackTask}
    Write-MigrationLog $Root 'rollback.complete'
}
function Confirm-Migration([string]$Root,[switch]$Explicit,[string]$Observer=''){
    $file=Get-MigrationStatePath $Root;if(-not (Test-Path $file)){return}
    $state=Read-TransportJson $file;if($state.phase -ne 'pending'){return}
    if($Observer -and $state.observer -ne $Observer){$state|Add-Member -Force observer $Observer;$state.greenSince=$null;$state.lastHealthyAt=$null}
    $now=[DateTime]::UtcNow
    if(($now-(Convert-TransportUtc $state.startedAt)).TotalSeconds -ge 600 -or ($now-(Convert-TransportUtc $state.startedAt)).TotalSeconds -lt -5){$state.greenSince=$null;Write-TransportJson $file $state -Durable;return}
    $watchdog=Get-MigrationTask $state.names.rollbackTask
    if(-not $watchdog.exists -or -not $watchdog.enabled){Invoke-MigrationRollback $Root $state.session;throw 'Watchdog отсутствует; переход откачен'}
    $healthy=Test-MigrationHealth $Root
    if(-not $healthy){$state.greenSince=$null;$state.lastHealthyAt=$null;Write-TransportJson $file $state -Durable;return}
    # A gap/restart cannot count as three continuously observed green minutes.
    if(-not $state.greenSince -or -not $state.lastHealthyAt -or ($now-(Convert-TransportUtc $state.lastHealthyAt)).TotalSeconds -gt 35 -or ($now-(Convert-TransportUtc $state.lastHealthyAt)).TotalSeconds -lt 0 -or ($now-(Convert-TransportUtc $state.greenSince)).TotalSeconds -lt 0){$state.greenSince=$now.ToString('o')}
    $state.lastHealthyAt=$now.ToString('o')
    if($Explicit -or ($now-(Convert-TransportUtc $state.greenSince)).TotalSeconds -ge 180){
        if($state.dryRun -and -not $Explicit){Write-TransportJson $file $state -Durable;return}
        Register-MigrationRecovery $Root $state # Failure keeps the independent rollback armed.
        # Persist acceptance before removing task: a fired stale task checks phase/session.
        $state.phase='accepted';Write-TransportJson $file $state -Durable
        try{Unregister-MigrationRollback $state.names.rollbackTask}catch{$state.phase='pending';Write-TransportJson $file $state -Durable;throw}
        Write-MigrationLog $Root 'install.accepted'
        # Started from the setup window on an old installation: acceptance completes the setup,
        # so later launches stay in the tray without a window.
        try{Update-MigrationConfig $Root {param($c) if($c.wizard -and $c.wizard.migrationRequested){$c.wizard|Add-Member -Force configured $true;$c.wizard.PSObject.Properties.Remove('migrationRequested')}}}catch{Write-MigrationLog $Root 'install.accepted.config-failed'}
    }else{Write-TransportJson $file $state -Durable}
}

function Write-MigrationPreflightFailure([string]$Root,[string]$Probe) {
    $file=Join-Path $Probe 'status/transport.json';$parts=@();$status=$null
    if(Test-Path $file){$status=Read-TransportJson $file}
    foreach($row in @($status.candidates)){
        if($null -eq $row){continue}
        $reason=if($row.diagnostic){Format-TransportDiagnostic $row.diagnostic}else{'candidate='+$row.tag+' reason='+$row.state+' (проба не завершена)'}
        Write-MigrationLog $Root 'preflight.candidate' $reason
        $parts+=($row.title+': '+$(if($row.diagnostic){$row.diagnostic.reason}else{$row.state}))
    }
    if(-not $parts.Count){$parts+= $(if($status.error){[string]$status.error}else{'нет статуса транспорта; см. state/migration-probe/logs/transport.log'})}
    $prefix='Нет рабочего пути к серверу: '
    if($status.ok){$prefix='Транспорт нашёл путь, но SSH на временном входе не прошёл: '}
    elseif(@($status.candidates|Where-Object {$_.state -eq 'ok'}).Count){$prefix='Есть проверенный путь, но выбранный режим транспорта недоступен: '}
    $message=$prefix+($parts -join '; ')+'. Прежний канал не остановлен.'
    Write-TransportJson (Join-Path $Root 'state/migration-error.json') @{message=$message;phase='preflight';updatedAt=[DateTime]::UtcNow.ToString('o')}
    Write-MigrationLog $Root 'preflight.failed' $message
    $message
}

function Save-MigrationFailure([string]$Root,$Record) {
    $path=Join-Path $Root 'state/migration-error.json'
    if(Test-Path $path){return}
    $message='Переход не выполнен: '+(Get-TransportErrorDetail $Record)+'. См. logs/migration.log.'
    Write-TransportJson $path @{message=$message;phase='failed';updatedAt=[DateTime]::UtcNow.ToString('o')}
    Write-MigrationLog $Root 'command.reason' $message
}
