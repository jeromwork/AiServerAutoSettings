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
function Get-FreePort {$l=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$l.Start();$port=[int]$l.LocalEndpoint.Port;$l.Stop();$port}
$script:events=New-Object Collections.ArrayList
$script:daemonOk=$true;$script:listener=$null
# Channel first never starts TUN, never enables the VPN component and never asks about a foreign VPN.
function Set-VpnEnabled($Root,$Enabled){[void]$script:events.Add('vpn-enabled')}
function Invoke-InstallChild($Bundle,$Script,$Arguments,$TimeoutSeconds){[void]$script:events.Add('child:'+$Script)}
# A foreign VPN (Happ in TUN mode) is running: the conflict probe of the bundle would report it.
$bundle=Join-Path $TestHome 'bundle';[void][IO.Directory]::CreateDirectory((Join-Path $bundle 'transport'))
$conflictMark=Join-Path $TestHome 'conflict-called'
[IO.File]::WriteAllText((Join-Path $bundle 'transport/Test-VpnConflict.ps1'),("param([string]`$Home)`r`n[IO.File]::WriteAllText('"+$conflictMark+"','x')`r`n'{""conflict"":true,""processHints"":""Happ""}'`r`n"))
$channelPort=Get-FreePort
function Start-WizardWorkingTransport($Root,$Bundle){
    $c=Read-TransportJson (Join-Path $Root 'config.json')
    Assert ($c.transport.channelFirst -eq $true -and $c.transport.bootstrap -eq $true) 'channelFirst written before the daemon starts'
    Assert ($null -eq $c.transport.openSsh) 'openSsh stays at its default'
    Assert ($c.transport.entries[0].name -eq 'fixture' -and $c.transport.relays[0].name -eq 'sparfum') 'catalog saved before the daemon starts'
    Assert ((Read-TransportJson $c.transport.channelPath).inbounds[0].override_port -eq 23456) 'channel snapshot applied before the daemon starts'
    [void]$script:events.Add('daemon')
    if(-not $script:daemonOk){return}
    if(-not $script:listener){$script:listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$channelPort);$script:listener.Start()}
    Write-TransportJson (Join-Path $Root 'status/transport.json') ([ordered]@{configRevision=(Get-TransportRevision $Root);summary='fixture';ok=$true;active='vless-relay-sparfum';candidates=@(@{tag='vless-direct';enabled=$true},@{tag='vless-relay-sparfum';enabled=$true});updatedAt=[DateTime]::UtcNow.ToString('o');error=$null})
}
$channel=Join-Path $root 'secrets/channel.json';Write-TransportJson $channel @{inbounds=@(@{tag='sync';override_port=23456});outbounds=@()} -Private
Write-TransportJson (Join-Path $root 'secrets/entries/fixture.json') @{server='fixture.example.invalid'} -Private
$binary=Join-Path $root 'sing-box.exe';Write-DiskUtf8 $binary 'fixture'
$profileFile=Join-Path $root 'profile-fixture.json';Write-TransportJson $profileFile @{serverAddress='server.invalid';login='worker'} -Private
$initial=@{channel=@{secret='vpn-channel'};catalog=@{schema=1;entries=@(@{name='fixture';ssh='fixture';kinds=@('hy2')});hops=@();relays=@(@{name='sparfum';host='192.0.2.10';port=8443});cdn=@()}}
$script:wanted=$true
function Reset {
    $script:events.Clear();if(Test-Path $conflictMark){Remove-Item $conflictMark}
    $status=Join-Path $root 'status/transport.json';if(Test-Path $status){Remove-Item $status}
    $vpn=@{checkUrl='https://fixture.example.invalid/';dnsServer='192.0.2.53'}
    if($script:wanted){$vpn.bootstrap=$initial}
    $c=@{schema=1;version=1;profile=@{vpn=$vpn};transport=@{profilePath=$profileFile;singBoxPath=$binary;openSsh=$false;channelSocksPort=$channelPort};components=@{}}
    [IO.File]::WriteAllText((Join-Path $root 'config.json'),(($c|ConvertTo-Json -Depth 25).Replace("`r",'').Replace("`n","`r`n")))
}
$script:WizardProgressFile=Join-Path $root 'progress.jsonl'
$request=[pscustomobject]@{parentPid=1234}
Reset
$r=Invoke-WizardStep $root $bundle 'Bootstrap' $request
Assert ($r.ok -and $r.vpn -eq 'channel' -and $r.channel -eq 'vless-relay-sparfum') 'channel raised through the relay candidate'
Assert ($r.summary -ceq 'Канал до сервера поднят: vless-relay-sparfum') 'contract summary'
Assert (($script:events -join ',') -eq 'daemon') 'only the transport daemon starts: no TUN, no VPN component, no UAC child'
Assert (-not (Test-Path $conflictMark)) 'a foreign VPN is not checked and does not block the channel'
$c=Read-TransportJson (Join-Path $root 'config.json')
Assert (-not $c.vpn.enabled -and -not $c.vpn.bootstrapTag) 'VPN component stays off'
$trace=@([IO.File]::ReadAllLines($script:WizardProgressFile)|ForEach-Object {(ConvertFrom-Json $_).text}|Where-Object {$_ -like '· *'})
Assert (@($trace|Where-Object {$_ -like '· кандидаты канала: vless-direct, vless-relay-sparfum'}).Count -eq 1) 'trace lists the candidates'
Assert (@($trace|Where-Object {$_ -like '· выбран кандидат канала: vless-relay-sparfum'}).Count -eq 1) 'trace names the chosen candidate'
Assert (@($trace|Where-Object {$_ -match '^· канал поднят за [0-9]+ мс$'}).Count -eq 1) 'trace records the time'
# The first «Связь» of this installation still runs as a first setup (Set-WizardInitialNetwork), not as a managed change.
Assert (-not (Test-WizardNetworkManaged $root)) 'channel-first bootstrap is not a managed network yet'
$r=Invoke-WizardStep $root $bundle 'Bootstrap' $request
Assert ($r.ok -and $r.vpn -eq 'channel') 'repeated Bootstrap reuses the running daemon'
# No channel in the config: nothing starts.
$script:wanted=$false;Reset
$r=Invoke-WizardStep $root $bundle 'Bootstrap' $request
Assert ($r.vpn -eq 'off' -and $script:events.Count -eq 0) 'off never starts the daemon'
Assert (-not (Read-TransportJson (Join-Path $root 'config.json')).transport.entries) 'absent bootstrap does not alter transport'
# A missing channel secret is an honest failure; the ordinary routes stay available.
$script:wanted=$true;Reset;Remove-Item -LiteralPath $channel
$r=Invoke-WizardStep $root $bundle 'Bootstrap' $request
Assert (-not $r.ok -and $r.vpn -eq 'channel-failed' -and $r.summary -like 'Канал до сервера не поднят: *. Доступны обычные маршруты') 'failure by contract'
Assert ($script:events.Count -eq 0) 'failed preparation starts nothing'
Write-TransportJson $channel @{inbounds=@(@{tag='sync';override_port=23456});outbounds=@()} -Private
# A daemon without a working candidate: the wait ends with the reason (short limit for the test).
$script:daemonOk=$false;Reset
Write-TransportJson (Join-Path $root 'status/transport.json') ([ordered]@{configRevision='other';ok=$false;active=$null;candidates=@();updatedAt=[DateTime]::UtcNow.ToString('o');error='нет связи'})
$failed=$null;try{Wait-WizardChannel $root (Get-FreePort) 2|Out-Null}catch{$failed=$_.Exception.Message}
Assert ($failed -like 'нет рабочего кандидата за 2 с*') 'no candidate in time is a failure'
$script:daemonOk=$true
# The contracted bootstrap form needs no extra public catalog field.
$initial.Remove('catalog');$initial.entries=@{fixture=@{secret='vpn-entry-fixture'}}
function Start-WizardWorkingTransport($Root,$Bundle){[void]$script:events.Add('daemon');Write-TransportJson (Join-Path $Root 'status/transport.json') ([ordered]@{configRevision=(Get-TransportRevision $Root);ok=$true;active='vless-direct';candidates=@(@{tag='vless-direct';enabled=$true});updatedAt=[DateTime]::UtcNow.ToString('o')})}
Reset
$r=Invoke-WizardStep $root $bundle 'Bootstrap' $request
Assert ($r.ok -and $r.vpn -eq 'channel' -and $r.channel -eq 'vless-direct') 'materialized entries work with the minimal contract bootstrap form'
# Channel first through an SSH hop of the catalog: the key comes from materialized.json, host keys from the catalog.
$pinKey='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHopHostKeyFixtureHopHostKey0'
$hopKey=Join-Path $root 'secrets/vpn-hop-fixture';Write-DiskUtf8 $hopKey "KEY`n"
Write-TransportJson (Join-Path $root 'secrets/materialized.json') @{schema=1;channelPath=$channel;hops=@{vhop=@{name='vpn-hop-fixture';ssh='hopuser@127.0.0.1:2222';keyFile=$hopKey}}} -Private
$initial.channel=@{secret='vpn-channel'};$initial.catalog=@{schema=1;entries=@(@{name='fixture';ssh='fixture';kinds=@('hy2')});hops=@(@{name='vhop';ssh='vhop';hostKey=@($pinKey)});relays=@();cdn=@()}
$initial.hops=@{vhop=@{host='127.0.0.1';port=2222;user='hopuser';key=@{secret='vpn-hop-vhop'}}}
Reset
$r=Invoke-WizardStep $root $bundle 'Bootstrap' $request
$hop=@((Read-TransportJson (Join-Path $root 'config.json')).transport.hops)[0]
$conf=[IO.File]::ReadAllText([string]$hop.configPath)
Assert ($r.ok -and $hop.ssh -eq 'vhop' -and $conf.Contains('Host vhop') -and $conf.Contains('Port 2222') -and $conf.Contains('User hopuser') -and $conf.Contains($hopKey) -and $conf.Contains('StrictHostKeyChecking yes')) 'channel hop alias mapped to the materialized key'
Assert ([IO.File]::ReadAllText($hopKey+'.known_hosts').Trim() -ceq ('[127.0.0.1]:2222 '+$pinKey)) 'channel hop pinned to the catalog host key'
Remove-Item -LiteralPath (Join-Path $root 'secrets/materialized.json');Reset
$r=Invoke-WizardStep $root $bundle 'Bootstrap' $request
Assert (-not $r.ok -and $r.vpn -eq 'channel-failed') 'channel hop without its materialized key is an honest failure'

# Daemon config: the channel SOCKS entry and its rules come first; without channelFirst nothing changes.
$options=@{sshPort=2222;channelSocksPort=2223;syncPort=22001;probePortBase=26000;socksPortBase=28000;apiPort=29090;bindPhysical=$false;openSsh=$true}
$settings=[pscustomobject]@{Options=$options;Transport=[pscustomobject]@{channelFirst=$true};Profile=[pscustomobject]@{arguments=@('-p','2022')};Channel=[pscustomobject]@{inbounds=@();outbounds=@()}}
$paths=[pscustomobject]@{Candidates=@();Outbounds=@()}
$cfg=New-TransportConfig $settings $paths 'fixture-secret' 'unavailable'
$in=@($cfg.inbounds|Where-Object {$_.tag -eq 'channel-socks'})
Assert ($in.Count -eq 1 -and $in[0].type -eq 'mixed' -and $in[0].listen -eq '127.0.0.1' -and $in[0].listen_port -eq 2223) 'channel-socks inbound by contract'
Assert ($cfg.route.rules[0].inbound[0] -eq 'channel-socks' -and $cfg.route.rules[0].action -eq 'route-options' -and $cfg.route.rules[0].override_address -eq '127.0.0.1' -and $cfg.route.rules[0].override_port -eq 2022) 'first rule overrides the target to the server sshd'
Assert ($cfg.route.rules[1].inbound[0] -eq 'channel-socks' -and $cfg.route.rules[1].outbound -eq 'active') 'second rule sends the channel through the active path'
if(Test-Path '/usr/bin/sing-box'){
    $file=Join-Path $root 'state/channel-check.json';Write-TransportJson $file $cfg -Private
    Test-TransportConfigFile '/usr/bin/sing-box' $file;$script:checks++
}
$settings.Transport=[pscustomobject]@{}
Assert (-not @((New-TransportConfig $settings $paths 'fixture-secret' 'unavailable').inbounds|Where-Object {$_.tag -eq 'channel-socks'}).Count) 'no channel entry without channelFirst'
$options.channelSocksPort=2222;$settings.Transport=[pscustomobject]@{channelFirst=$true}
$bad=$false;try{New-TransportConfig $settings $paths 'x' ''|Out-Null}catch{$bad=$true};Assert $bad 'channel port conflict rejected';$options.channelSocksPort=2223
$helper=Join-Path $root 'RemoteAgents.exe';Write-DiskUtf8 $helper 'fixture'
$profile=[pscustomobject]@{sshExecutable='ssh';serverAddress='server.invalid';login='worker';keyPath=(Join-Path $root 'key');knownHostsPath=(Join-Path $root 'missing-known-hosts');arguments=@('-p','22')}
$own=[pscustomobject]@{Options=$options;Profile=$profile;Channel=[pscustomobject]@{outbounds=@()};Transport=[pscustomobject]@{bootstrap=$true;serverRoute=[pscustomobject]@{used='proxy';proxy=[pscustomobject]@{type='socks';host='127.0.0.1';port=2223};proxyExecutable=$helper}}}
Assert (-not @((Get-TransportCandidates $own $root).Candidates|Where-Object {$_.tag -eq 'openssh-proxy'}).Count) 'a saved route through the own channel entry is not a daemon path (no loop)'
$own.Transport.serverRoute.proxy.port=1080
Assert (@((Get-TransportCandidates $own $root).Candidates|Where-Object {$_.tag -eq 'openssh-proxy'}).Count -eq 1) 'another local proxy stays a daemon path'

# Step «Сервер»: the channel route comes first, before the routes of the config, and is saved as a proxy route.
$pin='ssh-ed25519 Zml4dHVyZQ=='
$key=Join-Path $root 'key';Write-DiskUtf8 $key 'fixture-key-never-used-by-stub'
$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$listener.Start();$socks=[int]$listener.LocalEndpoint.Port
Write-TransportJson (Join-Path $root 'config.json') @{schema=1;version=1;transport=@{channelFirst=$true;channelSocksPort=$socks}}
$script:routes=$null
function Select-WizardRoute($Profile,$Worker,$Routes){$script:routes=$Routes;$script:WizardRoute=$Routes[0]}
function Invoke-WizardLogin($Profile,$User,$Command,$InputText=''){return ''}
function Get-TransportHostKeys($Ssh,$HostName,$KnownHosts){return $pin}
$data=@{schema=1;serverAddress='server.invalid';serverPort=22;workerUser='worker';hostKeys=@($pin);routes=@(@{kind='direct'},@{kind='proxy';proxy=@{type='http';host='127.0.0.1';port=3128}})}
$result=Connect-WizardSnapshot $root ([pscustomobject]@{data=(Copy-TransportObject $data);keyPath=$key;askpassExecutable=$helper})
Assert ($script:routes.Count -eq 3 -and $script:routes[0].kind -eq 'proxy' -and $script:routes[0].title -ceq 'через канал') 'channel route first, titled by contract'
Assert ($script:routes[0].options[1] -like ('*--proxy-connect socks 127.0.0.1 '+$socks+' %h %p')) 'channel route is a SOCKS proxy to the daemon entry'
Assert ($script:routes[1].kind -eq 'direct' -and $script:routes[2].title -like '*3128*') 'config routes follow in their order'
$saved=(Read-TransportJson (Join-Path $root 'config.json')).wizard.serverRoute
Assert ($saved.used -eq 'proxy' -and $saved.proxy.type -eq 'socks' -and $saved.proxy.host -eq '127.0.0.1' -and $saved.proxy.port -eq $socks) 'chosen channel route saved as proxy'
$p=Read-TransportJson $result.profile
Assert ($p.routeProxyCommand -like ('*--proxy-connect socks 127.0.0.1 '+$socks+'*') -and [IO.File]::ReadAllText($p.configPath).Contains('ProxyCommand')) 'ProxyCommand kept in the profile and ssh.conf'
$listener.Stop()
$result=Connect-WizardSnapshot $root ([pscustomobject]@{data=(Copy-TransportObject $data);keyPath=$key;askpassExecutable=$helper})
Assert ($script:routes.Count -eq 2 -and $script:routes[0].kind -eq 'direct') 'a silent channel port adds no route'
if($script:listener){$script:listener.Stop()}

# Honest SSH reason: a banner came, then the network cut SSH after the handshake.
$fake=Join-Path $TestHome 'fake-ssh';[void][IO.Directory]::CreateDirectory($fake)
$stderr="debug1: Remote protocol version 2.0, remote software version OpenSSH_9.6`ndebug1: SSH2_MSG_SERVICE_ACCEPT received`nssh: connect to host server.invalid port 22: Connection timed out"
if($env:OS -eq 'Windows_NT'){
    $ssh=Join-Path $fake 'ssh.cmd';$lines=@('@echo off')+@($stderr -split "`n"|ForEach-Object {'echo '+$_+' 1>&2'})+@('exit /b 255')
    [IO.File]::WriteAllText($ssh,(($lines -join "`r`n")+"`r`n"))
}else{
    $ssh=Join-Path $fake 'ssh';[IO.File]::WriteAllText($ssh,("#!/bin/sh`nprintf '%s\n' '"+($stderr -replace "`n","' '")+"' >&2`nexit 255`n"));& chmod +x $ssh
}
$message=$null;try{Invoke-DiskProcess $ssh @('-v','server.invalid','true') '' -TimeoutSeconds 10|Out-Null}catch{$message=$_.Exception.Message}
Assert ($message -like 'Сервер ответил, но сеть глушит SSH после рукопожатия — нужен обход (канал через промежуточный сервер)*') 'banner seen, then cut: not «no banner»'
$script:WizardNoBanner=$false;$script:WizardRoute=$null
$login=[pscustomobject]@{sshExecutable=$ssh;configPath=(Join-Path $root 'none.conf');keyPath=$key;knownHostsPath=(Join-Path $root 'kh');serverAddress='server.invalid';strictHostKey=$true}
Remove-Item function:Invoke-WizardLogin;. (Join-Path $repo 'build/Wizard.Server.ps1')
try{Invoke-WizardLogin $login 'worker' 'true'|Out-Null}catch{}
Assert (-not $script:WizardNoBanner) 'WizardNoBanner is not set for a cut after the handshake'
if($env:OS -ne 'Windows_NT'){[IO.File]::WriteAllText($ssh,"#!/bin/sh`necho 'kex_exchange_identification: Connection closed by remote host' >&2`nexit 255`n")}
else{[IO.File]::WriteAllText($ssh,"@echo off`r`necho kex_exchange_identification: Connection closed by remote host 1>&2`r`nexit /b 255`r`n")}
$message=$null;try{Invoke-DiskProcess $ssh @('server.invalid','true') '' -TimeoutSeconds 10|Out-Null}catch{$message=$_.Exception.Message}
Assert ($message -like 'Нет SSH-баннера от сервера*') 'no banner at all keeps the old reason'

# Parallel sections: one repeat after 3 s for an SSH connection failure (code 255), only with channelFirst.
$env:REMOTEAGENTS_WIZARD_SESSION='0'
Write-TransportJson (Join-Path $root 'config.json') @{schema=1;version=1;transport=@{channelFirst=$true;profilePath=$result.profile}}
$script:calls=0
function Invoke-DiskProcess($Exe,$Arguments,[string]$InputText='',[string]$OutputFile='',[int]$TimeoutSeconds=45){$script:calls++;if($script:calls -eq 1){throw 'Нет связи с сервером (код выхода 255)'};return 'ok'}
$watch=[Diagnostics.Stopwatch]::StartNew();$reply=Invoke-WizardSsh $root 'true'
Assert ($reply -eq 'ok' -and $script:calls -eq 2 -and $watch.Elapsed.TotalSeconds -ge 2.9) 'one repeat after 3 s'
$script:calls=0;function Invoke-DiskProcess($Exe,$Arguments,[string]$InputText='',[string]$OutputFile='',[int]$TimeoutSeconds=45){$script:calls++;throw 'Внешняя команда не выполнена (код выхода 1)'}
try{Invoke-WizardSsh $root 'true'|Out-Null}catch{};Assert ($script:calls -eq 1) 'other codes are not repeated'
Update-LauncherConfig $root {param($c) $c.transport.PSObject.Properties.Remove('channelFirst')}
$script:calls=0;function Invoke-DiskProcess($Exe,$Arguments,[string]$InputText='',[string]$OutputFile='',[int]$TimeoutSeconds=45){$script:calls++;throw 'Нет связи с сервером (код выхода 255)'}
try{Invoke-WizardSsh $root 'true'|Out-Null}catch{};Assert ($script:calls -eq 1) 'no repeat without channelFirst'
Write-Host ('PASS: config channel-first bootstrap/route/socks/honest-reason/retry: '+$script:checks+' assertions (daemon and SSH stubbed; no Windows)')
