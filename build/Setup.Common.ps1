#requires -Version 5.1
# Shared helpers of the setup wizard and uninstall. Small Windows adapters are replaceable in offline tests.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'transport/Transport.Common.ps1')
function Write-SetupLog([string]$Root,[string]$Event,[string]$Detail=''){
    $mutex=New-Object Threading.Mutex($false,('Global\RemoteAgentsSetupLog-'+(Get-TransportFingerprint 'log' (Get-TransportHome $Root).ToLowerInvariant())))
    $locked=$false
    try{
        try{$locked=$mutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){throw 'Журнал настройки занят'}
    $dir=Join-Path $Root 'logs';[void][IO.Directory]::CreateDirectory($dir);$file=Join-Path $dir 'setup.log'
    if((Test-Path $file) -and (Get-Item $file).Length -gt 1MB){Move-Item $file ($file+'.1') -Force}
    [IO.File]::AppendAllText($file,([DateTime]::UtcNow.ToString('o')+' '+$Event+$(if($Detail){' '+$Detail}else{''})+"`n"),(New-Object Text.UTF8Encoding($false)))
    }finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Update-LauncherConfig([string]$Root,[scriptblock]$Edit){
    $mutex=New-Object Threading.Mutex($false,('Global\RemoteAgentsConfig-'+(Get-TransportFingerprint 'config' (Get-TransportHome $Root).ToLowerInvariant())))
    $locked=$false
    try{
        try{$locked=$mutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$locked=$true};if(-not $locked){throw 'Конфиг занят'}
        $path=Join-Path $Root 'config.json';$c=[pscustomobject]@{};if(Test-Path -LiteralPath $path){$c=Read-TransportJson $path}
        & $Edit $c;Write-TransportJson $path $c -Durable
    }finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Set-ConfigDefault($Object,[string]$Key,$Value){if(-not $Object.PSObject.Properties[$Key]){$Object|Add-Member $Key $Value}}
function Get-RunValue([string]$Name){
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
    try{if($key){$key.GetValue($Name,$null)}}finally{if($key){$key.Dispose()}}
}
function Set-RunValue([string]$Name,$Value){
    $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
    try{if($null -eq $Value){$key.DeleteValue($Name,$false)}else{$key.SetValue($Name,[string]$Value)}}finally{$key.Dispose()}
}
function Get-TaskState([string]$Name){
    $task=Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if($task){[pscustomobject]@{exists=$true;enabled=[bool]$task.Settings.Enabled;running=($task.State -eq 'Running')}}else{[pscustomobject]@{exists=$false;enabled=$false;running=$false}}
}
function Start-SetupDetached([string]$Exe,[string[]]$Arguments){
    $created=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=((Quote-Transport $Exe)+' '+(($Arguments|ForEach-Object {Quote-Transport $_}) -join ' '))}
    if($created.ReturnValue -ne 0){throw 'Не удалось запустить процесс'}
}
function Start-RunCommand([string]$Command){
    if(-not $Command){return}
    $created=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$Command}
    if($created.ReturnValue -ne 0){throw 'Не удалось восстановить автозапуск'}
}
function Stop-ManagedControl([string]$Root){
    $file=Join-Path $Root 'managed-control/control.pid'
    if(Test-Path -LiteralPath $file){
        $id=0;if([int]::TryParse([IO.File]::ReadAllText($file).Trim(),[ref]$id)){
            $p=Get-CimInstance Win32_Process -Filter "ProcessId=$id"
            if($p -and $p.CommandLine -match 'Start-WindowsControl\.ps1' -and ([string]$p.CommandLine).IndexOf($Root,[StringComparison]::OrdinalIgnoreCase) -ge 0){& "$env:SystemRoot/System32/taskkill.exe" /T /F /PID $id *> $null}
        }
    }
}
function Stop-ManagedDisk([string]$DiskRoot){
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'disk/Disk.Engine.ps1')
    Stop-DiskEngineProcesses $DiskRoot
}
function Remove-ExplorerNavPane {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'disk/Disk.NavPane.ps1')
    Remove-DiskNavPane
}
function Test-StatusFresh([string]$Root,[string]$Name){
    $file=Join-Path $Root ('status/'+$Name+'.json')
    if(-not (Test-Path $file)){return $false}
    $c=Read-TransportJson $file;if($Name -eq 'transport' -and $c.configError){return $false};$age=([DateTime]::UtcNow-(Convert-TransportUtc $c.updatedAt)).TotalSeconds
    [bool]($c.ok -and $age -ge -5 -and $age -le 30)
}
function Test-LocalSsh([string]$Root,[int]$Port){
    $c=Read-TransportJson (Join-Path $Root 'config.json');$profile=Read-TransportJson $c.transport.profilePath
    $child=$null
    try{
        $child=Start-TransportProcess $profile.sshExecutable ((Get-TransportSshArguments $profile $Port)+@('127.0.0.1','true'))
        if(-not $child.Process.WaitForExit(15000)){return $false};$child.Process.ExitCode -eq 0
    }finally{Stop-TransportProcess $child}
}
function Get-BridgeProbe {
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
print('bridge-probe-ok')
'@
}
function Wait-TransportReady([string]$Root,[int]$Timeout=180){
    $deadline=[DateTime]::UtcNow.AddSeconds($Timeout)
    do{if(Test-StatusFresh $Root transport){return};Start-Sleep -Seconds 1}while([DateTime]::UtcNow -lt $deadline)
    throw 'Нет проверенного transport'
}
# A candidate transport config is proven on separate ports before the working daemon sees it.
function Invoke-TransportPreflight([string]$Root,[string]$Bundle,$Config){
    $probe=Join-Path $Root 'state/transport-probe';[void][IO.Directory]::CreateDirectory($probe)
    $copy=Copy-TransportObject $Config
    # The check must not skip the only working path on a metered/unknown network.
    $copy.transport|Add-Member -Force metered 'false'
    # Readiness comes from the daemon's parallel liveness probes (all paths at once, first answer wins), so this takes seconds.
    # The per-path limit is not shortened: a hop through a DPI filter sometimes answers after 15-20 s. Speed ranking runs later, unawaited.
    $copy.transport|Add-Member -Force rankProbeBytes 65536
    if($env:REMOTEAGENTS_WIZARD_PROGRESS){$copy.transport|Add-Member -Force probeTimeoutSec 30;$copy.transport|Add-Member -Force stallSeconds 5}
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
        if($env:REMOTEAGENTS_WIZARD_PROGRESS){Wait-TransportReady $probe 45}else{Wait-TransportReady $probe}
        if(-not (Test-LocalSsh $probe $ports[0])){throw 'SSH на временном входе не прошёл'}
        Write-SetupLog $Root 'preflight.ok'
    }catch{
        $message=Write-PreflightFailure $Root $probe
        throw $message
    }finally{
        [IO.File]::WriteAllText($stop,'stop');if($child){[void]$child.Process.WaitForExit(10000)};Stop-TransportProcess $child
    }
}
function Write-PreflightFailure([string]$Root,[string]$Probe) {
    $file=Join-Path $Probe 'status/transport.json';$parts=@();$status=$null
    if(Test-Path $file){$status=Read-TransportJson $file}
    foreach($row in @($status.candidates)){
        if($null -eq $row){continue}
        $reason=if($row.diagnostic){Format-TransportDiagnostic $row.diagnostic}else{'candidate='+$row.tag+' reason='+$row.state+' (проба не завершена)'}
        Write-SetupLog $Root 'preflight.candidate' $reason
        $parts+=($row.title+': '+$(if($row.diagnostic){$row.diagnostic.reason}else{$row.state}))
    }
    if(-not $parts.Count){$parts+= $(if($status.error){[string]$status.error}else{'нет статуса транспорта; см. state/transport-probe/logs/transport.log'})}
    $prefix='Нет рабочего пути к серверу: '
    if($status.ok){$prefix='Транспорт нашёл путь, но SSH на временном входе не прошёл: '}
    elseif(@($status.candidates|Where-Object {$_.state -eq 'ok'}).Count){$prefix='Есть проверенный путь, но выбранный режим транспорта недоступен: '}
    $message=$prefix+($parts -join '; ')+'. Рабочая связь не изменена.'
    Write-SetupLog $Root 'preflight.failed' $message
    $message
}
function Find-InstallProfile([string]$Root) {
    $config=Join-Path $Root 'config.json'
    if(Test-Path $config){$c=Read-TransportJson $config;if($c.wizard.pendingProfile){return [string]$c.wizard.pendingProfile};if($c.transport.profilePath){return [string]$c.transport.profilePath}}
    $files=@(Get-ChildItem -Path (Join-Path $Root 'ssh-profiles/*/project-connections/*/ssh-transport.json') -File -ErrorAction SilentlyContinue)
    if($files.Count -eq 1){return $files[0].FullName}
    if($files.Count -gt 1){throw 'Несколько профилей: задайте transport.profilePath в config.json'}
    return ''
}
function Invoke-InstallChild([string]$Bundle,[string]$Script,[string[]]$Arguments,[int]$TimeoutSeconds=900) {
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=Get-TransportPowerShell
    $sta=@();if($env:OS -eq 'Windows_NT'){$sta=@('-STA')}
    $psi.Arguments=(@('-NoLogo','-NoProfile','-NonInteractive')+$sta+@('-ExecutionPolicy','Bypass','-File',(Join-Path $Bundle $Script))+$Arguments|ForEach-Object {Quote-Transport ([string]$_)}) -join ' '
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $p=[Diagnostics.Process]::Start($psi)
    $out=$p.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null);$err=$p.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
    try{if(-not $p.WaitForExit($TimeoutSeconds*1000)){$p.Kill();throw ('Таймаут шага ('+$TimeoutSeconds+' с)')};if($p.ExitCode -ne 0){throw 'Шаг установки не выполнен'}}finally{$p.Dispose()}
}
