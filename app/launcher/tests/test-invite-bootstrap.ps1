#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Wizard.Common.ps1')
$env:LOCALAPPDATA=$TestHome
$root=Join-Path $TestHome 'RemoteAgents'
[void][IO.Directory]::CreateDirectory($root)
$script:checks=0
function Assert($Ok,[string]$Why){if(-not $Ok){throw $Why};$script:checks++}
$script:events=New-Object Collections.ArrayList
$script:foreign=$false;$script:fail=$false
function Get-WizardInviteVpnConflict($Root,$Bundle){[void]$script:events.Add('conflict');return @{conflict=$script:foreign;processHints='Happ'}}
function Select-WizardInviteInternetPath($Root){
    $c=Read-TransportJson (Join-Path $Root 'config.json')
    Assert ($c.transport.entries[0].name -eq 'fixture') 'catalog must be saved before selecting VPN'
    Assert ((Read-TransportJson $c.transport.channelPath).inbounds[0].override_port -eq 23456) 'channel snapshot applied before network'
    Assert ((Read-TransportJson (Join-Path $Root 'secrets/entries/fixture.json')).server -eq 'fixture.example.invalid') 'entry cache applied before network'
    [void]$script:events.Add('path');return 'hy2-fixture'
}
function Start-WizardInviteTun($Root,$Bundle,$ParentPid){
    $c=Read-TransportJson (Join-Path $Root 'config.json')
    Assert ($c.components.vpn.enabled -and $c.vpn.enabled) 'exact existing VPN component enabled before registration'
    [void]$script:events.Add('tun')
    if($script:fail){throw 'stub VPN failure'}
}
function Wait-WizardInviteTun($Root){return 'on'}
$path=Join-Path $TestHome 'invite.rainvite'
$invite=@{schema=1;id=('a'*32);serverAddress='fixture.example.invalid';serverPort=2222;workerUser='worker';enrollUser='ra-enroll';hostKeys=@('ssh-ed25519 AAAA');vpn='on';bootstrap=@{catalog=@{schema=1;entries=@(@{name='fixture';ssh='fixture';kinds=@('hy2')});hops=@();relays=@();cdn=@()};channel=@{inbounds=@(@{tag='sync';override_port=23456});outbounds=@()};entries=@{fixture=@{server='fixture.example.invalid'}};hops=@{};vpn=@{checkUrl='https://fixture.example.invalid/';dnsServer='192.0.2.53'}}}
function Reset {
    $script:events.Clear()
    Write-TransportJson (Join-Path $root 'config.json') @{schema=1;version=1;transport=@{};components=@{}}
    # Windows-style text, including the invitation boundary.
    [IO.File]::WriteAllText($path,(($invite|ConvertTo-Json -Depth 25).Replace("`r`n","`n").Replace("`n","`r`n")))
}
$request=[pscustomobject]@{path=$path;parentPid=1234}
Reset
$r=Invoke-WizardStep $root $repo 'InvitePrepare' $request
Assert ($r.ok -and $r.vpn -eq 'on') 'on verified by stub'
Assert (($script:events -join ',') -eq 'conflict,path,tun') 'VPN order'
# Bootstrap uses HTTPS only until SSH is registered; never fake transport.ok.
$c=Read-TransportJson (Join-Path $root 'config.json')
$state=Get-VpnTransportState $root ([pscustomobject]@{Transport=$c.transport;Vpn=$c.vpn})
Assert ($state.bootstrap -and $state.active -eq 'hy2-fixture') 'bootstrap path without SSH probe'
Assert (-not (Test-Path (Join-Path $root 'status/transport.json'))) 'no forged transport status'
$invite.vpn='off';Reset
$r=Invoke-WizardStep $root $repo 'InvitePrepare' $request
Assert ($r.vpn -eq 'off' -and $script:events.Count -eq 0) 'off never checks or starts VPN'
Assert ((Read-TransportJson (Join-Path $root 'config.json')).transport.entries[0].name -eq 'fixture') 'off still applies catalog'
$invite.vpn='on';$script:foreign=$true;Reset
$r=Invoke-WizardStep $root $repo 'InvitePrepare' $request
Assert ($r.vpn -eq 'conflict' -and ($script:events -join ',') -eq 'conflict') 'foreign VPN untouched'
Assert (-not (Read-TransportJson (Join-Path $root 'config.json')).components.vpn.enabled) 'foreign VPN leaves our component off'
$script:foreign=$false;$script:fail=$true;Reset
$r=Invoke-WizardStep $root $repo 'InvitePrepare' $request
Assert ($r.ok -and $r.vpn -eq 'unavailable') 'VPN failure allows enrollment route fallback'
Assert (-not (Read-TransportJson (Join-Path $root 'config.json')).components.vpn.enabled) 'failed VPN component rolled back'
# Once bootstrap is retired, a stale/missing transport is a failure again.
$bad=$false;try{Get-VpnTransportState $root ([pscustomobject]@{Transport=@{};Vpn=@{}})|Out-Null}catch{$bad=$true}
Assert $bad 'regular VPN still requires a live SSH transport check'
Write-Host ('PASS: invitation VPN bootstrap/on/off/foreign/failure/CRLF: '+$script:checks+' assertions (OS and TUN stubbed)')
