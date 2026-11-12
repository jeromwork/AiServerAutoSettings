#requires -Version 5.1
param([string]$TestHome,[string]$Payload,[string]$Profile,[string]$SingBoxFile,[string]$Mode='refresh')
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Wizard.Common.ps1')
$root=Join-Path $TestHome 'RemoteAgents';$env:LOCALAPPDATA=$TestHome
[void][IO.Directory]::CreateDirectory($root)
$profileData=Read-TransportJson $Profile;$data=Read-TransportJson $Payload
$channel=Join-Path $root 'channel.json';Write-TransportJson $channel $data.bootstrap.channel
Write-TransportJson (Join-Path $root 'config.json') @{schema=1;version=1;transport=@{profilePath=$Profile;channelPath=$channel;singBoxPath='fixture';entries=@();hops=@();relays=@(@{name='old';host='127.0.0.2';port=1234});cdn=@()};wizard=@{configured=$true};bridge=@{enabled=$true;allowShell=$true};happier=@{label='kept'};disk=@{folders=@('Project/docs')};vpn=@{enabled=$true;checkUrl='https://old.invalid/';dnsServer='192.0.2.1';excludeCidrs=@('192.0.2.0/24')}}
Write-TransportJson (Join-Path $root 'state/transport-pin.json') @{mode='pinned';tag='vless-relay-old'}
if($Mode -eq 'old-route'){
    Update-LauncherConfig $root {param($c) $c.transport|Add-Member serverRoute ([pscustomobject]@{used='proxy';proxy=[pscustomobject]@{type='http';host='127.0.0.1';port=1};proxyExecutable=(Join-Path $root 'obsolete.exe')})}
}
$script:checks=0;$script:preflights=0;$script:watchdog=0;$script:proofFails=$false
function Assert($OK,$Why){if(-not $OK){throw $Why};$script:checks++}
function Register-WizardRollback($Root,$Bundle,$Kind,$Session,$Task){$script:watchdog++}
function Unregister-ScheduledTask {param($TaskName,[switch]$Confirm,[string]$ErrorAction)}
function Invoke-TransportPreflight($Root,$Bundle,$Candidate){
    $script:preflights++
    $p=Read-TransportJson $Candidate.transport.profilePath
    Assert ((Get-WizardDeviceKey $p) -ceq (Get-WizardDeviceKey $profileData)) 'private key preserved'
    Assert ($Candidate.transport.relays[0].name -eq 'new') 'removed old route; new catalog applied'
    # Real OpenSSH checks the candidate's NEW pins and device key (Linux TUN is stubbed).
    [void](Invoke-DiskProcess $p.sshExecutable (@($p.arguments)+@('true')) -TimeoutSeconds 10)
}
function Test-WizardNetworkProof($Root,$Mark){return (-not $script:proofFails)}
$request=[pscustomobject]@{path=$Payload;askpassExecutable='fixture';singBoxFile=$SingBoxFile;offlineInstaller=($Mode -eq 'offline')}
$before=[IO.File]::ReadAllText((Join-Path $root 'config.json'));$oldProfile=[IO.File]::ReadAllText($Profile)
if($Mode -in @('foreign','expired','untrusted')){
    if($Mode -eq 'untrusted'){$data.type='settings';$request=[pscustomobject]@{data=$data}}
    $why='';try{Update-WizardInviteSettings $root $repo $request|Out-Null}catch{$why=$_.Exception.Message}
    $pattern=switch($Mode){'foreign'{'*другому компьютеру*'};'expired'{'*Срок обновления истёк*'};'untrusted'{'*доверенный SSH*'}}
    Assert ($why -like $pattern) ('understandable rejection: '+$why)
    Assert ($script:preflights -eq 0 -and $script:watchdog -eq 0) 'refuse before writes/network'
    Assert ([IO.File]::ReadAllText((Join-Path $root 'config.json')) -ceq $before) 'config unchanged'
    Assert ([IO.File]::ReadAllText($Profile) -ceq $oldProfile) 'pins unchanged'
}else{
    if($Mode -eq 'sync'){
        Write-TransportJson (Join-Path $root 'state/invite-device.json') @{name='Ноутбук';id='fixture'}
        $result=Sync-WizardInviteSettings $root $repo $request
    }else{$result=Update-WizardInviteSettings $root $repo $request}
    Assert ($result.ok -and $result.changed) 'settings applied'
    $c=Read-TransportJson (Join-Path $root 'config.json')
    if($Mode -eq 'old-route'){Assert (-not $c.transport.serverRoute) 'new direct route removes obsolete transport overlay'}
    Assert ($c.transport.relays[0].name -eq 'new' -and @($c.transport.relays).Count -eq 1) 'new route replaces removed route'
    Assert ($c.disk.folders[0] -eq 'Project/docs' -and $c.happier.label -eq 'kept' -and $c.bridge.enabled) 'Disk Happier bridge preserved'
    Assert ($c.vpn.enabled -and $c.vpn.dnsServer -eq '192.0.2.53' -and $c.vpn.excludeCidrs[0] -eq '192.0.2.0/24') 'VPN updates preserve local choice and exclusions'
    if($SingBoxFile -and $Mode -ne 'sync'){Assert ((Get-FileHash $c.transport.singBoxPath).Hash -ceq (Get-FileHash $SingBoxFile).Hash) 'VPN executable staged without overwriting running binary'}
    Assert ($c.transport.profilePath -eq $Profile -and (Read-TransportJson $Profile).keyPath -eq $profileData.keyPath) 'stable shared profile and key'
    Assert ((Read-TransportPin $root).mode -eq 'auto') 'removed pinned path returns to automatic choice'
    Assert ($script:watchdog -eq 1) 'independent rollback armed'
    if($Mode -eq 'offline'){
        Assert (Test-Path (Join-Path $root 'state/wizard-network.json')) 'offline installer keeps independent rollback'
        $script:proofFails=$true
        Assert (-not (Confirm-WizardInviteSettings $root)) 'unconfirmed connection cannot disarm rollback'
        $script:proofFails=$false
        Assert (Confirm-WizardInviteSettings $root) 'healthy tray confirms deferred transaction'
        Assert (-not (Test-Path (Join-Path $root 'state/wizard-network.json'))) 'confirmed transaction disarms rollback'
    }
    $revision=Get-TransportRevision $root
    if($Mode -eq 'sync'){$again=Sync-WizardInviteSettings $root $repo $request}else{$again=Update-WizardInviteSettings $root $repo $request}
    Assert ($again.ok -and -not $again.changed -and $script:preflights -eq 1) 'same file/snapshot idempotent'
    Assert ((Get-TransportRevision $root) -ceq $revision) 'repeat does not restart VPN'
    # Replay recovery from a crash (receipt survives launcher). Production undo, stub scheduler only.
    $saved=Join-Path $root 'state/wizard-network.json'
    Write-TransportJson $saved @{session='crash';previous=(ConvertFrom-Json $before).transport;profileFile=$Profile;profile=(ConvertFrom-Json $oldProfile);vpn=(ConvertFrom-Json $before).vpn;task='fixture';refreshReceipt=(Join-Path $root ('state/refresh-used-'+$data.id+'.json'));versionFile=(Join-Path $root 'state/invite-settings-version.json')}
    Undo-WizardNetwork $root 'crash'
    Assert ((Read-TransportJson (Join-Path $root 'config.json')).transport.relays[0].name -eq 'old') 'crash restores prior transport'
    Assert ((ConvertTo-Json (Read-TransportJson $Profile) -Depth 30 -Compress) -ceq (ConvertTo-Json (ConvertFrom-Json $oldProfile) -Depth 30 -Compress)) 'crash restores pins and profile'
    Assert (-not (Test-Path $saved)) 'recovery receipt consumed'
}
Write-Host ('PASS refresh '+$Mode+': '+$script:checks+' checks (real own-key SSH; scheduler/transport/TUN stubs)')
