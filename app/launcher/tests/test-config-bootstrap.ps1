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
function Get-WizardBootstrapVpnConflict($Root,$Bundle){[void]$script:events.Add('conflict');return @{conflict=$script:foreign;processHints='Happ'}}
function Select-WizardBootstrapInternetPath($Root){
    $c=Read-TransportJson (Join-Path $Root 'config.json')
    Assert ($c.transport.entries[0].name -eq 'fixture') 'catalog must be saved before selecting VPN'
    Assert ((Read-TransportJson $c.transport.channelPath).inbounds[0].override_port -eq 23456) 'channel snapshot applied before network'
    Assert ((Read-TransportJson (Join-Path $Root 'secrets/entries/fixture.json')).server -eq 'fixture.example.invalid') 'entry cache applied before network'
    [void]$script:events.Add('path');return 'hy2-fixture'
}
function Start-WizardBootstrapTun($Root,$Bundle,$ParentPid){
    $c=Read-TransportJson (Join-Path $Root 'config.json')
    Assert ($c.components.vpn.enabled -and $c.vpn.enabled) 'exact existing VPN component enabled before SSH'
    [void]$script:events.Add('tun')
    if($script:fail){throw 'stub VPN failure'}
}
function Wait-WizardBootstrapTun($Root){return 'on'}
$channel=Join-Path $root 'secrets/channel.json';Write-TransportJson $channel @{inbounds=@(@{tag='sync';override_port=23456});outbounds=@()} -Private
Write-TransportJson (Join-Path $root 'secrets/entries/fixture.json') @{server='fixture.example.invalid'} -Private
$binary=Join-Path $root 'sing-box.exe';Write-DiskUtf8 $binary 'fixture'
$initial=@{channel=@{secret='vpn-channel'};catalog=@{schema=1;entries=@(@{name='fixture';ssh='fixture';kinds=@('hy2')});hops=@();relays=@();cdn=@()}}
$script:wanted=$true
function Reset {
    $script:events.Clear()
    $vpn=@{checkUrl='https://fixture.example.invalid/';dnsServer='192.0.2.53'}
    if($script:wanted){$vpn.bootstrap=$initial}
    $c=@{schema=1;version=1;profile=@{vpn=$vpn};transport=@{profilePath='fixture';singBoxPath=$binary};components=@{}}
    [IO.File]::WriteAllText((Join-Path $root 'config.json'),(($c|ConvertTo-Json -Depth 25).Replace("`r",'').Replace("`n","`r`n")))
}
$request=[pscustomobject]@{parentPid=1234}
Reset
$r=Invoke-WizardStep $root $repo 'Bootstrap' $request
Assert ($r.ok -and $r.vpn -eq 'on') 'on verified by stub'
Assert (($script:events -join ',') -eq 'conflict,path,tun') 'VPN order'
# Bootstrap uses HTTPS only until SSH is verified; never fake transport.ok.
$c=Read-TransportJson (Join-Path $root 'config.json')
$state=Get-VpnTransportState $root ([pscustomobject]@{Transport=$c.transport;Vpn=$c.vpn})
Assert ($state.bootstrap -and $state.active -eq 'hy2-fixture') 'bootstrap path without SSH probe'
Assert (-not (Test-Path (Join-Path $root 'status/transport.json'))) 'no forged transport status'
$script:wanted=$false;Reset
$r=Invoke-WizardStep $root $repo 'Bootstrap' $request
Assert ($r.vpn -eq 'off' -and $script:events.Count -eq 0) 'off never checks or starts VPN'
Assert (-not (Read-TransportJson (Join-Path $root 'config.json')).transport.entries) 'absent bootstrap does not alter transport'
$script:wanted=$true;$script:foreign=$true;Reset
$r=Invoke-WizardStep $root $repo 'Bootstrap' $request
Assert (-not $r.ok -and $r.vpn -eq 'conflict' -and ($script:events -join ',') -eq 'conflict') 'foreign VPN untouched'
Assert (-not (Read-TransportJson (Join-Path $root 'config.json')).components.vpn.enabled) 'foreign VPN leaves our component off'
$script:foreign=$false;$script:fail=$true;Reset
$r=Invoke-WizardStep $root $repo 'Bootstrap' $request
Assert (-not $r.ok -and $r.vpn -eq 'unavailable') 'VPN failure allows an honest failure'
Assert (-not (Read-TransportJson (Join-Path $root 'config.json')).components.vpn.enabled) 'failed VPN component rolled back'
# Once bootstrap is retired, a stale/missing transport is a failure again.
$bad=$false;try{Get-VpnTransportState $root ([pscustomobject]@{Transport=@{};Vpn=@{}})|Out-Null}catch{$bad=$true}
Assert $bad 'regular VPN still requires a live SSH transport check'
# The contracted bootstrap form needs no extra public catalog field.
$script:fail=$false;$script:wanted=$true
$initial.Remove('catalog');$initial.entries=@{fixture=@{secret='vpn-entry-fixture'}}
Reset
$r=Invoke-WizardStep $root $repo 'Bootstrap' $request
Assert ($r.ok -and $r.vpn -eq 'on') 'materialized entries work with the minimal contract bootstrap form'
# config export --vpn off: a public catalog without a channel is not a VPN-first request.
$initial.Remove('channel');$initial.catalog=@{schema=1;entries=@();hops=@();relays=@();cdn=@()};Reset
$r=Invoke-WizardStep $root $repo 'Bootstrap' $request
Assert ($r.ok -and $r.vpn -eq 'off' -and $script:events.Count -eq 0) 'catalog without a channel starts nothing'
# VPN-first through an SSH hop of the catalog: the key comes from materialized.json, host keys from the catalog.
$pinKey='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHopHostKeyFixtureHopHostKey0'
$hopKey=Join-Path $root 'secrets/vpn-hop-fixture';Write-DiskUtf8 $hopKey "KEY`n"
Write-TransportJson (Join-Path $root 'secrets/materialized.json') @{schema=1;channelPath=$channel;hops=@{vhop=@{name='vpn-hop-fixture';ssh='hopuser@127.0.0.1:2222';keyFile=$hopKey}}} -Private
$initial.channel=@{secret='vpn-channel'};$initial.catalog=@{schema=1;entries=@(@{name='fixture';ssh='fixture';kinds=@('hy2')});hops=@(@{name='vhop';ssh='vhop';hostKey=@($pinKey)});relays=@();cdn=@()}
$initial.hops=@{vhop=@{host='127.0.0.1';port=2222;user='hopuser';key=@{secret='vpn-hop-vhop'}}}
Reset
$r=Invoke-WizardStep $root $repo 'Bootstrap' $request
$hop=@((Read-TransportJson (Join-Path $root 'config.json')).transport.hops)[0]
$conf=[IO.File]::ReadAllText([string]$hop.configPath)
Assert ($r.ok -and $hop.ssh -eq 'vhop' -and $conf.Contains('Host vhop') -and $conf.Contains('Port 2222') -and $conf.Contains('User hopuser') -and $conf.Contains($hopKey) -and $conf.Contains('StrictHostKeyChecking yes')) 'VPN hop alias mapped to the materialized key'
Assert ([IO.File]::ReadAllText($hopKey+'.known_hosts').Trim() -ceq ('[127.0.0.1]:2222 '+$pinKey)) 'VPN hop pinned to the catalog host key'
Remove-Item -LiteralPath (Join-Path $root 'secrets/materialized.json');Reset
$r=Invoke-WizardStep $root $repo 'Bootstrap' $request
Assert (-not $r.ok -and $r.vpn -eq 'unavailable') 'VPN hop without its materialized key is an honest failure'
Write-Host ('PASS: config VPN bootstrap/on/off/foreign/failure/CRLF: '+$script:checks+' assertions (OS and TUN stubbed)')
