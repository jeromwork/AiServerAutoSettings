#requires -Version 5.1
# Long actions own only their mutable resource. Config R/M/W retains its short mutex.
function Get-WizardResources([string]$Action,$Request) {
    switch($Action){
        'ConfigSync' {return @('bridge','connection','vpn')}
        'RollbackNetwork' {return @('connection','vpn')}
        'Connection' {return @('connection')}
        {$_ -in @('Bridge','RollbackBridge')} {return @('bridge')}
        {$_ -in @('Account','ResumeAccount')} {return @('account')}
        {$_ -in @('Disk')} {return @('disk')}
        {$_ -in @('Vpn','Bootstrap')} {return @('vpn')}
        {$_ -in @('Proxy','Lan','LanRemove')} {return @('server-network')}
        'Server' {return @('profile')}
        'Skip' {if($Request.step -eq 'Disk'){return @('disk')}}
        'Operation' {if($Request.start){return @('server-install-'+[string]$Request.start)}}
    }
    return @()
}
function Invoke-WizardResourceLock([string]$Root,[string]$Resource,[scriptblock]$Work,[int]$TimeoutMs=120000) {
    $name='Global\RemoteAgentsWizard-'+(Get-TransportFingerprint $Resource (Get-TransportHome $Root).ToLowerInvariant())
    $mutex=New-Object Threading.Mutex($false,$name);$locked=$false
    try{
        try{$locked=$mutex.WaitOne($TimeoutMs)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){throw ('Раздел занят: '+$Resource+'; повторите после завершения')}
        & $Work
    }finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Invoke-WizardAction([string]$Root,[string]$Action,$Request,[scriptblock]$Body) {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try{
        $resources=@(Get-WizardResources $Action $Request)
        Invoke-WizardResourceSet $Root $resources $Body
    }finally{
        # Same JSONL envelope as other progress messages, including failed stages.
        Write-WizardProgress ('timing '+$Action+' '+$watch.ElapsedMilliseconds)
    }
}

function Start-WizardWorkingTransport([string]$Root,[string]$Bundle) {
    # The daemon's own per-Home mutex arbitrates with the tray supervisor.
    $stop=Join-Path $Root 'state/transport.stop';if(Test-Path $stop){Remove-Item -LiteralPath $stop -Force}
    $si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=Get-TransportPowerShell
    $si.Arguments=((@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $Bundle 'transport/Transport.Daemon.ps1'),'-Home',$Root)|ForEach-Object {Quote-Transport $_}) -join ' ')
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    $child=New-Object Diagnostics.Process;$child.StartInfo=$si
    try{[void]$child.Start();[void]$child.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null);[void]$child.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)}finally{$child.Dispose()}
}
function Wait-WizardWorkingProof([string]$Root,[DateTime]$Mark,[int]$Timeout=120) {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds -lt $Timeout){
        if(Test-WizardNetworkProof $Root $Mark){return}
        Start-Sleep -Milliseconds 200
    }
    throw 'Рабочая связь не подтверждена; повторите раздел «Связь»'
}
function Set-WizardInitialNetwork([string]$Root,[string]$Bundle,$Transport) {
    $previous=(Read-TransportJson (Join-Path $Root 'config.json')).transport;$mark=[DateTime]::UtcNow
    # Channel first: the new transport keeps the channel entry and the relays it was raised through.
    if($previous.channelFirst){
        foreach($field in @('channelFirst','channelSocksPort')){if($null -ne $previous.$field -and $null -eq $Transport.$field){$Transport|Add-Member -Force $field $previous.$field}}
        if(-not @($Transport.relays|Where-Object {$null -ne $_}).Count -and @($previous.relays|Where-Object {$null -ne $_}).Count){$Transport|Add-Member -Force relays @($previous.relays|Where-Object {$null -ne $_})}
    }
    try{
        Update-LauncherConfig $Root {param($c) $c|Add-Member -Force transport $Transport}
        # A running daemon (same Home mutex) re-reads the changed config itself: the new process exits at once and
        # the working one restarts only sing-box after a background check, so the channel SOCKS entry is gone briefly.
        Start-WizardWorkingTransport $Root $Bundle
        Wait-WizardWorkingProof $Root $mark
    }catch{
        Update-LauncherConfig $Root {param($c) $c|Add-Member -Force transport $previous}
        throw
    }
}
function Register-WizardDeviceName([string]$Root,[string]$DeviceName) {
    if(-not $DeviceName -or $DeviceName.Length -gt 80 -or $DeviceName -match '[\x00-\x1f\x7f]'){throw 'Некорректное название компьютера'}
    $hostId=Split-Path (Split-Path (Find-InstallProfile $Root) -Parent) -Leaf
    $payload=@{hostId=$hostId;deviceName=$DeviceName}|ConvertTo-Json -Compress
    $source=@'
import json,sys,runpy
from pathlib import Path
h=Path.home();api=runpy.run_path(str(h/'.local/share/codex-remote/server_node_catalog.py'))
r=json.load(sys.stdin);directory=h/'.local/share/remote-agents-nodes'
record=next(x for x in api['records'](directory,h) if x['projectId']=='control' and x['hostId']==r['hostId'])
record['deviceName']=r['deviceName'];api['register'](directory,record,h)
assert next(x for x in api['records'](directory,h) if x['projectId']=='control' and x['hostId']==r['hostId'])['deviceName']==r['deviceName']
print('device-name-ok')
'@
    $code=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source))
    $reply=Invoke-WizardSsh $Root ('python3 -c ''import base64;exec(base64.b64decode("'+$code+'"))''') $payload
    if($reply.Trim() -cne 'device-name-ok'){throw 'Сервер не подтвердил название компьютера'}
    Update-LauncherConfig $Root {param($c) Set-ConfigDefault $c profile ([pscustomobject]@{});Set-ConfigDefault $c.profile device ([pscustomobject]@{});$c.profile.device|Add-Member -Force name $DeviceName}
}

function Invoke-WizardResourceSet([string]$Root,[string[]]$Resources,[scriptblock]$Body) {
    if(-not $Resources.Count){& $Body;return}
    Invoke-WizardResourceLock $Root $Resources[0] {
        $tail=@();if($Resources.Count -gt 1){$tail=@($Resources[1..($Resources.Count-1)])}
        Invoke-WizardResourceSet $Root $tail $Body
    }
}
function Get-WizardRuntimeFiles {
    @('build/Wizard.ps1','build/Wizard.Common.ps1','build/Wizard.Engine.ps1','build/Wizard.Session.ps1','build/Wizard.SessionHost.ps1','build/Wizard.Server.ps1','build/Wizard.Bootstrap.ps1','build/Wizard.Refresh.ps1','build/Wizard.Network.ps1','build/Wizard.Lan.ps1','build/Setup.Common.ps1','transport/Transport.Common.ps1','transport/Route.Proxy.ps1','transport/server-transport-catalog.py','disk/Disk.Common.ps1','disk/Disk.Union.ps1','disk/Disk.Selective.ps1','disk/stignore.txt','disk/stignore-previous.sha256')
}
function Install-WizardConfigSync([string]$Root,[string]$Bundle) {
    if(-not (Test-WizardWindows)){return @{supported=$false;intervalSec=300}}
    $files=@(Get-WizardRuntimeFiles)
    $hashes=@($files|ForEach-Object {(Get-FileHash -LiteralPath (Join-Path $Bundle $_) -Algorithm SHA256).Hash})
    $version=(Get-TransportFingerprint 'config-sync' ($hashes -join '')).Substring(0,24)
    $dest=Join-Path $Root ('state/config-sync/'+$version)
    foreach($file in $files){
        $target=Join-Path $dest $file
        if(-not (Test-Path $target)){[void][IO.Directory]::CreateDirectory((Split-Path $target -Parent));Copy-Item -LiteralPath (Join-Path $Bundle $file) -Destination $target}
    }
    $task='RemoteAgents config sync '+(Get-TransportFingerprint 'sync' $Root.ToLowerInvariant()).Substring(0,16)
    $args=@('-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',(Join-Path $dest 'build/Wizard.ps1'),'-Home',$Root,'-Action','ConfigSync')
    $action=New-ScheduledTaskAction -Execute (Get-TransportPowerShell) -Argument (($args|ForEach-Object {Quote-Transport $_}) -join ' ')
    $user=Get-WizardInteractiveUser
    $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 4)
    Register-ScheduledTask -TaskName $task -Action $action -Trigger @($trigger,(New-ScheduledTaskTrigger -AtLogOn -User $user)) -Principal $principal -Settings $settings -Force|Out-Null
    $registered=Get-TaskState $task
    if(-not $registered.exists -or -not $registered.enabled){throw 'Не зарегистрировано автообновление конфига каждые 5 минут'}
    return @{supported=$true;intervalSec=300;task=$task}
}
function Get-WizardHostId([string]$Root) {
    Invoke-WizardResourceLock $Root 'device-identity' {
        $file=Join-Path $Root 'state/device-id.json'
        if(Test-Path $file){$value=[string](Read-TransportJson $file).hostId;if($value -cmatch '\Apc-[a-f0-9]{32}\z'){return $value};throw 'Повреждён идентификатор компьютера'}
        $value='pc-'+[guid]::NewGuid().ToString('N')
        Write-TransportJson $file @{hostId=$value} -Durable
        return $value
    }
}

function Test-WizardWindows {return $env:OS -eq 'Windows_NT'}
function Get-WizardInteractiveUser {return [Security.Principal.WindowsIdentity]::GetCurrent().Name}
function Set-WizardDiskChannel([string]$Root) {
    Invoke-WizardResourceLock $Root 'connection' {
        $config=Read-TransportJson (Join-Path $Root 'config.json')
        if(-not $config.transport.channelPath){throw 'Сначала завершите раздел «Связь», затем повторите диск'}
        $ports=ConvertFrom-Json (Convert-TransportLF (Invoke-WizardSsh $Root 'cat "$HOME/.local/share/remote-disk/ports.json"'))
        $port=[int]$ports.listen;if($port -lt 1 -or $port -gt 65535){throw 'Сервер диска не сообщил порт Syncthing'}
        $channel=Read-TransportJson $config.transport.channelPath
        $existing=@($channel.inbounds|Where-Object {$_.tag -eq 'sync'})
        if($existing.Count -eq 1 -and [int]$existing[0].override_port -eq $port){return}
        $channel|Add-Member -Force inbounds (@($channel.inbounds|Where-Object {$_.tag -ne 'sync'})+@([pscustomobject]@{tag='sync';override_port=$port}))
        $file=Join-Path $Root ('secrets/channel-disk-'+(Get-TransportFingerprint 'channel' (ConvertTo-Json $channel -Depth 40 -Compress)).Substring(0,24)+'.json')
        Write-TransportJson $file $channel -Private
        $settings=Read-TransportSettings $Root;$settings.Channel=$channel
        $generated=New-TransportConfig $settings (Get-TransportCandidates $settings $Root) (Get-TransportSecret $Root) 'unavailable'
        $check=Join-Path $Root 'state/disk-channel-check.json'
        Write-TransportJson $check $generated -Private
        try{Test-TransportConfigFile $settings.Options.singBoxPath $check}finally{if(Test-Path $check){Remove-Item -LiteralPath $check -Force}}
        $previous=[string]$config.transport.channelPath;$mark=[DateTime]::UtcNow
        try{
            Update-LauncherConfig $Root {param($c) $c.transport|Add-Member -Force channelPath $file}
            Wait-WizardWorkingProof $Root $mark
        }catch{
            Update-LauncherConfig $Root {param($c) $c.transport|Add-Member -Force channelPath $previous}
            throw
        }
    }
}
