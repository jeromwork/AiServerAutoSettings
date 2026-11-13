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
function Stop-LegacyConfigSyncProcessTree($Process){
    $id=[int]$Process.ProcessId
    $current=Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop
    if(-not $current -or $current.CreationDate -ne $Process.CreationDate -or $current.CommandLine -cne $Process.CommandLine){return}
    & "$env:SystemRoot/System32/taskkill.exe" /T /F /PID $id *> $null
    if($LASTEXITCODE -ne 0 -and (Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop)){throw 'Не удалось остановить прежнюю сверку конфига'}
}
# Config refresh is owned by the launcher timer. Stop the legacy task before unregistering it.
function Remove-LegacyConfigSyncTask([string]$Root){
    if($env:OS -ne 'Windows_NT'){return}
    $task='RemoteAgents config sync '+(Get-TransportFingerprint 'sync' $Root.ToLowerInvariant()).Substring(0,16)
    $exists=(Get-TaskState $task).exists
    if($exists){Disable-ScheduledTask -TaskName $task -ErrorAction Stop|Out-Null}
    # Stop the whole old wscript/PowerShell/preflight tree before the scheduler can orphan its children.
    # Also catch a leftover worker if an earlier exit already removed the task.
    $prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\','/').Replace('/','\')+'\state\config-sync\'
    $pattern='(?i)"'+[regex]::Escape($prefix)+'[a-f0-9]{24}\\(?:config-sync-hidden\.vbs|build\\Wizard\.ps1)"(?=\s|$)'
    foreach($process in @(Get-CimInstance Win32_Process -Filter "Name='wscript.exe' OR Name='powershell.exe'" -ErrorAction Stop)){
        if(([string]$process.CommandLine).Replace('/','\') -match $pattern){Stop-LegacyConfigSyncProcessTree $process}
    }
    if($exists){
        Stop-ScheduledTask -TaskName $task -ErrorAction Stop
        Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction Stop
    }
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
    $config=Join-Path $Root 'config.json'
    if(-not (Test-Path -LiteralPath $config) -or -not (Read-TransportJson $config).wizard.configured){
        # Load the existing strict command parser in a child scope: its Stop-ManagedControl
        # function is first-install-only and must not replace this shutdown helper.
        $owned=& {
            . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Start-WindowsControl.ps1') -LibraryOnly
            Test-ManagedControlCommand ([string](Get-RunValue 'RemoteAgentsControl')) $Root
        }
        if($owned){Set-RunValue 'RemoteAgentsControl' $null}
    }
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
function Remove-ExplorerNavPane([string]$LauncherRoot='') {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'disk/Disk.NavPane.ps1')
    Remove-DiskNavPane
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'disk/Disk.Common.ps1')
    if($LauncherRoot){$c=Read-TransportJson (Join-Path $LauncherRoot 'config.json');if($c.disk.home){$script:DiskHome=[string]$c.disk.home}}
    Remove-DiskExplorer
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
# Keep reservations alive until the candidate config is written. Separate blocks
# let multiple Homes probe concurrently without touching any working listener.
function New-TransportPortReservation([int]$Count=1,[string]$Address='127.0.0.1',[int]$Port=0) {
    for($attempt=0;$attempt -lt 12;$attempt++){
        $sockets=@()
        try{
            $base=$Port
            for($i=0;$i -lt $Count;$i++){
                $socket=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse($Address),$(if($i -eq 0){$base}else{$base+$i}))
                $socket.Server.ExclusiveAddressUse=$true
                $sockets+=,$socket;$socket.Start()
                if($i -eq 0){$base=[int]$socket.LocalEndpoint.Port}
                if($base+$Count -gt 65535){throw 'Диапазон портов исчерпан'}
            }
            return [pscustomobject]@{base=$base;listeners=$sockets}
        }catch{foreach($socket in $sockets){$socket.Stop()};if($Port -or $attempt -eq 11){throw 'Не удалось выделить свободные порты для пробного транспорта'}}
    }
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
    $copy.transport|Add-Member -Force probeTimeoutSec 30;$copy.transport|Add-Member -Force stallSeconds 5
    # Reserve a disjoint block for inbounds, ranking probes and local SSH socks. Fail if occupied.
    $listeners=@();$ports=@()
    try{
        $t=$copy.transport
        $probeCount=8+9*@($t.entries|Where-Object {$_}).Count+2*@($t.hops|Where-Object {$_}).Count+@($t.relays|Where-Object {$_}).Count+@($t.cdn|Where-Object {$_}).Count
        $reserved=New-TransportPortReservation $probeCount;$listeners+=@($reserved.listeners)
        $copy.transport|Add-Member -Force probePortBase $reserved.base
        $reserved=New-TransportPortReservation (4+@($t.hops|Where-Object {$_}).Count);$listeners+=@($reserved.listeners)
        $copy.transport|Add-Member -Force socksPortBase $reserved.base
        for($i=0;$i -lt 4;$i++){$reserved=New-TransportPortReservation;$listeners+=@($reserved.listeners);$ports+=$reserved.base}
        $copy.transport|Add-Member -Force sshPort $ports[0];$copy.transport|Add-Member -Force syncPort $ports[1];$copy.transport|Add-Member -Force apiPort $ports[2]
        # channel-socks is another inbound even though channel.json only lists ssh/sync.
        $copy.transport|Add-Member -Force channelSocksPort $ports[3]
        if($copy.transport.channelFirst){
            $address='127.0.'+(Get-Random -Minimum 1 -Maximum 255)+'.'+(Get-Random -Minimum 2 -Maximum 255)
            $profile=Read-TransportJson $copy.transport.profilePath
            $reserved=New-TransportPortReservation 1 $address (Get-TransportServerPort $profile);$listeners+=@($reserved.listeners)
            $copy.transport|Add-Member -Force channelSshAddress $address
        }
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
        Wait-TransportReady $probe 45
        if(-not (Test-LocalSsh $probe ([int](Get-TransportEffectivePort $probe 'sshPort')))){throw 'SSH на временном входе не прошёл'}
        Write-SetupLog $Root 'preflight.ok'
    }catch{
        $detail=Protect-TransportDiagnostic ([string]$_.Exception.Message) $copy
        $message=Write-PreflightFailure $Root $probe
        throw ('Пробная связь: '+$detail+'. '+$message)
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
        $code=$(if($row.diagnostic){[string]$row.diagnostic.reason}else{[string]$row.state})
        $why=switch($code){
            'process-exited' {'процесс транспорта завершился'}
            'timeout' {'истекло время ожидания ответа'}
            'connection-refused' {'сервер отклонил соединение'}
            'network-unreachable' {'сеть недоступна'}
            'authentication-failed' {'сервер отклонил вход'}
            'executable-not-found' {'программа транспорта не найдена'}
            'ok' {'путь проверен'}
            default {'проверка не прошла ('+$code+')'}
        }
        if($row.diagnostic){
            $extra=([string]$row.diagnostic.stderr+' '+[string]$row.diagnostic.engineStderr).Trim()
            if($extra -match '(?i)address already in use|Only one usage|bind.+(?:denied|forbidden)'){$why='локальный порт пробного транспорта занят'}
            if($extra){$why+=': '+(Protect-TransportText $extra)}
            if($null -ne $row.diagnostic.exitCode){$why+=' (код '+$row.diagnostic.exitCode+')'}
        }
        $parts+=($row.title+': '+$why)
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
function Get-InstallFailureLines([string]$Text) {
    foreach($line in ($Text.Replace("`r",'') -split "`n")){
        $clean=($line -replace '\x1b\[[0-9;]*[a-zA-Z]','').Trim()
        # Ignore PS 5.1/7 source, location and stack decorations, preserving the actual error line.
        if($clean -and $clean -notmatch '^(At |строка:|[+~|]|\d+\s*\||CategoryInfo\s*:|FullyQualifiedErrorId\s*:|(?:Exception|Write-Error):\s+.*\.ps1:\d+)'){
            $masked=if(Get-Command Protect-DiskFailureText -ErrorAction SilentlyContinue){Protect-DiskFailureText $clean}else{Protect-TransportText $clean}
            if($masked -notmatch '^(<secret>|<uuid>)+$'){$masked}
        }
    }
}
function Get-InstallFailureRemedy([string]$Reason) {
    if(-not $Reason -or $Reason -match '^(Шаг установки не выполнен \(код \d+\)|Внешняя команда не выполнена \(код выхода \d+\))$'){
        return 'Проверьте SSH, состояние служб и журнал соответствующего шага; повторите проверку. Секреты в журнал не копируйте.'
    }
    return ''
}
function Invoke-InstallChild([string]$Bundle,[string]$Script,[string[]]$Arguments,[int]$TimeoutSeconds=900) {
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=Get-TransportPowerShell
    $sta=@();if($env:OS -eq 'Windows_NT'){$sta=@('-STA')}
    $psi.Arguments=(@('-NoLogo','-NoProfile','-NonInteractive')+$sta+@('-ExecutionPolicy','Bypass','-File',(Join-Path $Bundle $Script))+$Arguments|ForEach-Object {Quote-Transport ([string]$_)}) -join ' '
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    # Reuse the transport's bounded streams; asynchronous drains cannot deadlock on a full pipe.
    Initialize-TransportDiagnostics
    $stdout=New-Object RemoteAgents.TransportErrorBuffer;$stderr=New-Object RemoteAgents.TransportErrorBuffer
    $p=[Diagnostics.Process]::Start($psi)
    $out=$p.StandardOutput.BaseStream.CopyToAsync($stdout);$err=$p.StandardError.BaseStream.CopyToAsync($stderr)
    try{
        $timedOut=-not $p.WaitForExit($TimeoutSeconds*1000)
        if($timedOut){$p.Kill();[void]$p.WaitForExit(2000)}
        [void]$out.Wait(2000);[void]$err.Wait(2000)
        if($timedOut -or $p.ExitCode -ne 0){
            # The bounded buffer retains the FIRST line as well as the tail. Cutting the tail again
            # discarded the cause and could start in the middle of a word ("да не выполнена").
            $lines=@(Get-InstallFailureLines $stderr.Snapshot())+@(Get-InstallFailureLines $stdout.Snapshot())
            $detail=$lines -join "`n"
            if($detail.Length -gt 4096){$detail=$detail.Substring(0,4096)}
            if($detail -and (Get-Command Write-WizardProgress -ErrorAction SilentlyContinue)){Write-WizardProgress ('· '+$Script+"`n· "+($detail -replace "`n","`n· "))}
            $reason=if($timedOut){'Таймаут шага ('+$TimeoutSeconds+' с)'}else{'Шаг установки не выполнен (код '+$p.ExitCode+')'}
            if($lines.Count){$reason+=': '+$lines[0]}
            $failure=New-Object Exception($reason);$failure.Data['ChildOutput']=$detail;throw $failure
        }
    }finally{$p.Dispose();$stdout.Dispose();$stderr.Dispose()}
}
