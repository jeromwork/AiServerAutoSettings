#requires -Version 5.1
[CmdletBinding()]
param([string]$OutputConfig='',[string]$SingBox='')
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
$work=Join-Path ([IO.Path]::GetTempPath()) ('transport-test-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($work)
$count=0
function Assert($Condition,[string]$Message){if(-not $Condition){throw ('Тест: '+$Message)};$script:count++}
try{
    $key=Join-Path $work 'key';$known=Join-Path $work 'known_hosts'
    $keygen=Get-Command ssh-keygen -ErrorAction SilentlyContinue
    if($keygen){[void](Invoke-TransportText $keygen.Source @('-q','-t','ed25519','-N','','-f',$key))}
    elseif($SingBox){throw 'Для sing-box check нужен ssh-keygen: установите OpenSSH'}
    else{[IO.File]::WriteAllText($key,'test-only-placeholder')}
    [IO.File]::WriteAllText($known,'203.0.113.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDKtkImHp4iQlyBtwBY4Vx3cBxfNF0Hdga/ucaszwI2r'+"`n")
    $p=[pscustomobject]@{sshExecutable='ssh.exe';serverAddress='203.0.113.10';login='alice';keyPath=$key;knownHostsPath=$known;arguments=@('-p','22','alice@203.0.113.10')}
    if(Get-Command ssh -ErrorAction SilentlyContinue){
        $spaceKnown=Join-Path $work 'Пользователь с пробелом/known hosts'
        $spaceProfile=[pscustomobject]@{keyPath=$key;login='alice';serverAddress='example.invalid';knownHostsPath=$spaceKnown}
        $effective=(& ssh -G @(Get-TransportSshArguments $spaceProfile 22371) example.invalid 2>$null) -join "`n"
        Assert ($LASTEXITCODE -eq 0 -and $effective.Contains('userknownhostsfile '+$spaceKnown)) 'OpenSSH сохраняет путь known_hosts с пробелом и кириллицей'
    }
    $reality='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    $channel=@{inbounds=@(@{tag='ssh';override_port=22},@{tag='sync';override_port=23456});outbounds=@(@{type='vless';tag='old';server='203.0.113.10';server_port=443;uuid='00000000-0000-4000-8000-000000000001';tls=@{enabled=$true;server_name='example.com';utls=@{enabled=$true;fingerprint='chrome'};reality=@{enabled=$true;public_key=$reality;short_id='abcdef01'}}})}
    $t=[pscustomobject]@{entries=@([pscustomobject]@{name='edge';alias='edge-example'});relays=@([pscustomobject]@{name='relay';server='203.0.113.30';port=8443});hops=@([pscustomobject]@{name='jump';alias='jump-example'})}
    $e=@{server='203.0.113.20';sni='example.com';cover='example.com';domain='entry.example.com';insecure=$true;ports=@{hy2=443;hy2_obfs=3478;tuic=8445;trojan=8446;reality=8447;shadowtls=8448};secrets=@{hy2='fake';hy2_obfs='fake';tuic_uuid='00000000-0000-4000-8000-000000000002';tuic='fake';trojan='fake';vless_uuid='00000000-0000-4000-8000-000000000003';reality_public=$reality;short_id='abcd';shadowtls='fake';ss='AAAAAAAAAAAAAAAAAAAAAA==';ws_path='/example';ws_uuid='00000000-0000-4000-8000-000000000004'}}
    $cache=Join-Path $work 'secrets/entries/edge.json';Write-TransportJson $cache $e -Private
    # CRLF JSON и SSH -G: проверяем реальный путь чтения, а не отдельную копию парсера.
    $text=ConvertTo-Json -InputObject $e -Depth 20;[IO.File]::WriteAllText($cache,$text.Replace("`r",'').Replace("`n","`r`n"),(New-Object Text.UTF8Encoding($true)))
    $script:fakeHop="hostname 203.0.113.40`r`nuser alice`r`nidentityfile $key`r`nport 22`r`n"
    $realText=${function:Invoke-TransportText};$realHostKeys=${function:Get-TransportHostKeys}
    function Invoke-TransportText($Exe,$Arguments){$script:fakeHop}
    function Get-TransportHostKeys($Ssh,$HostName,$KnownHosts){'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDKtkImHp4iQlyBtwBY4Vx3cBxfNF0Hdga/ucaszwI2r'}
    $options=@{sshPort=2222;syncPort=22001;probePortBase=26000;socksPortBase=28000;apiPort=29090;bindPhysical=$true;openSsh=$true;stallSeconds=5;probeTimeoutSec=45}
    $settings=[pscustomobject]@{Options=$options;Transport=$t;Profile=$p;Channel=(Copy-TransportObject $channel)}
    $paths=Get-TransportCandidates $settings $work
    foreach($tag in @('singbox-ssh-direct','hop-jump')){
        $sshOut=$paths.Outbounds|Where-Object {$_.tag -eq $tag}
        Assert (@($sshOut.host_key_algorithms).Count -eq 1 -and $sshOut.host_key_algorithms[0] -eq 'ssh-ed25519') ('SSH negotiates pinned ed25519 only: '+$tag)
    }
    foreach($type in @('ssh-ed25519','ecdsa-sha2-nistp256','ecdsa-sha2-nistp384','ecdsa-sha2-nistp521','ssh-rsa')){
        foreach($object in @(@{host_key=@($type+' fixture')},[pscustomobject]@{host_key=@($type+' fixture')})){
            Set-TransportHostKeyAlgorithms $object
            $expectedAlgorithms=if($type -eq 'ssh-rsa'){'rsa-sha2-512,rsa-sha2-256'}else{$type}
            Assert (($object.host_key_algorithms -join ',') -eq $expectedAlgorithms -and $object.host_key[0] -eq ($type+' fixture')) ('pinned key type for hashtable/PSCustomObject: '+$type)
        }
    }
    $mixed=[pscustomobject]@{host_key=@("ssh-ed25519 fixture`r`n",'ecdsa-sha2-nistp256 fixture','ssh-ed25519 fixture','ssh-rsa fixture');host_key_algorithms=@('unrelated')}
    Set-TransportHostKeyAlgorithms $mixed
    Assert (($mixed.host_key_algorithms -join ',') -eq 'ssh-ed25519,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256') 'mixed pins deduplicate algorithms and replace stale preferences with CRLF input'
    foreach($pins in @(@(),@('unknown fixture'))){
        $rejected=$false;try{Set-TransportHostKeyAlgorithms @{host_key=$pins}}catch{$rejected=$true}
        Assert $rejected 'empty/unknown pins fail closed'
    }
    $pinned=Copy-TransportObject $settings;$pinned.Channel.outbounds+=@([pscustomobject]@{type='ssh';tag='old-ssh';server=$p.serverAddress;host_key=@('ecdsa-sha2-nistp384 fixture');host_key_algorithms=@('ssh-ed25519')})
    $pinnedPaths=Get-TransportCandidates $pinned $work
    Assert ((($pinnedPaths.Outbounds|Where-Object {$_.tag -eq 'singbox-ssh-direct'}).host_key_algorithms -join ',') -eq 'ecdsa-sha2-nistp384') 'existing channel pins determine negotiation too'
    # Local hops accept a key path; sing-box uses the same private_key_path field as the target SSH.
    $keyHop=Copy-TransportObject $t;$hopKey=Join-Path $work 'Пользователь с пробелом/hop key'
    $keyHop.hops[0]|Add-Member keyFile $hopKey
    $keySettings=[pscustomobject]@{Options=$options;Transport=$keyHop;Profile=$p;Channel=(Copy-TransportObject $channel)}
    $keyPaths=Get-TransportCandidates $keySettings $work
    $jump=@($keyPaths.Tunnels|Where-Object {$_.tag -eq 'openssh-jump-jump'})[0]
    $pc=@($jump.arguments|Where-Object {$_ -like 'ProxyCommand=*'})[0]
    Assert ($pc.Contains('"-i" "'+$hopKey+'"') -and $pc.Contains('IdentitiesOnly=yes') -and $pc.EndsWith('"jump-example"')) 'OpenSSH jump uses explicit hop key before destination'
    Assert (($keyPaths.Outbounds|Where-Object {$_.tag -eq 'hop-jump'}).private_key_path -eq $hopKey) 'sing-box SSH hop overrides default identity with explicit key path'
    Assert (($paths.Outbounds|Where-Object {$_.tag -eq 'hop-jump'}).private_key_path -eq $key) 'legacy hop still uses resolved default identity'
    $personal=[pscustomobject]@{used='hop';hop=[pscustomobject]@{name='personal';ssh='jumper@hop.example.invalid:2207';keyFile=$hopKey;hostKey='unrelated-saved-key'}}
    $overlay=Copy-TransportObject $settings
    $overlay.Transport|Add-Member serverRoute $personal
    $overlay.Profile|Add-Member configPath (Join-Path $work 'ssh.conf')
    $before=ConvertTo-Json -InputObject $overlay.Transport -Depth 30 -Compress
    $script:hopKnown='';$script:hopResolve=@()
    function Get-TransportHostKeys($Ssh,$HostName,$KnownHosts){if($KnownHosts -like '*known_hosts-hop'){$script:hopKnown=$KnownHosts};'ssh-ed25519 fixture-pinned-hop-key'}
    function Invoke-TransportText($Exe,$Arguments){$script:hopResolve=@($Arguments);$script:fakeHop}
    $personalPaths=Get-TransportCandidates $overlay $work
    Assert ((ConvertTo-Json -InputObject $overlay.Transport -Depth 30 -Compress) -ceq $before) 'personal overlay does not mutate public catalog lists'
    Assert ($script:hopKnown -eq (Join-Path $work 'known_hosts-hop')) 'personal hop host key comes from known_hosts-hop'
    $outHop=$personalPaths.Outbounds|Where-Object {$_.tag -eq 'hop-wizard-server-route'}
    Assert ($outHop.private_key_path -eq $hopKey -and $outHop.host_key[0] -eq 'ssh-ed25519 fixture-pinned-hop-key') 'sing-box personal hop uses explicit key and pinned host key'
    $jump=$personalPaths.Tunnels|Where-Object {$_.tag -eq 'openssh-jump-wizard-server-route'}
    $pc=@($jump.arguments|Where-Object {$_ -like 'ProxyCommand=*'})[0]
    Assert ($pc.Contains('"-i" "'+$hopKey+'"') -and $pc.Contains('known_hosts-hop') -and $pc.Contains('StrictHostKeyChecking=yes')) 'persistent personal OpenSSH hop pins its own known_hosts file'
    Assert ($pc.Contains('"-l" "jumper"') -and $pc.Contains('"-p" "2207"') -and $pc.EndsWith('"hop.example.invalid"')) 'persistent hop separates endpoint login and port before destination'
    Assert ($script:hopResolve[-1] -eq 'hop.example.invalid' -and $script:hopResolve -contains '2207' -and $script:hopResolve -contains $hopKey) 'ssh -G resolves the same explicit endpoint and identity'
    $overlay.Transport.relays=@();$overlay.Transport.entries=@()
    $overlay.Channel=[pscustomobject]@{outbounds=@();inbounds=@([pscustomobject]@{tag='sync';override_port=23456})}
    # No VLESS on a fresh server: OpenSSH still carries bridge and disk.
    $noVless=Get-TransportCandidates $overlay $work
    Assert (@($noVless.Tunnels|Where-Object {$_.tag -eq 'openssh-jump-wizard-server-route'}).Count -eq 1) 'fresh SSH-only server keeps personal hop'
    Assert (@($noVless.Candidates|Where-Object {$_.tag -like 'vless-sshhop-*'}).Count -eq 0) 'SSH-only channel has no fabricated VLESS hop'
    $overlay.Transport.serverRoute=[pscustomobject]@{used='direct';hop=$personal.hop}
    $direct=Get-TransportCandidates $overlay $work
    Assert ($direct.Tunnels.Count -eq 2 -and @($direct.Candidates|Where-Object {$_.tag -like '*wizard-server-route*' -or $_.tag -eq 'openssh-proxy'}).Count -eq 0) 'direct route adds no personal candidate'
    $helper=Join-Path $work 'RemoteAgents.exe';[IO.File]::WriteAllText($helper,'fixture-only')
    $overlay.Transport.serverRoute=[pscustomobject]@{used='proxy';proxy=[pscustomobject]@{type='http';host='127.0.0.1';port=1080};proxyExecutable=$helper}
    $proxyPaths=Get-TransportCandidates $overlay $work
    $proxyTunnel=$proxyPaths.Tunnels|Where-Object {$_.tag -eq 'openssh-proxy'}
    $pc=@($proxyTunnel.arguments|Where-Object {$_ -like 'ProxyCommand=*'})[0]
    Assert ($pc.Contains('--proxy-connect http 127.0.0.1 1080 %h %p') -and $proxyTunnel.target -eq $p.serverAddress) 'persistent proxy uses local exe and target profile'
    Assert (@($proxyPaths.Candidates|Where-Object {$_.tag -eq 'openssh-proxy'}).Count -eq 1) 'persistent proxy participates in transport selection'
    Remove-Item $helper
    $failed=$false;try{Get-TransportCandidates $overlay $work|Out-Null}catch{$failed=$_.Exception.Message -like '*RemoteAgents.exe*'}
    Assert $failed 'persistent proxy without helper fails clearly'
    $overlay.Transport.serverRoute=[pscustomobject]@{used='hop';hop=[pscustomobject]@{ssh='hop.example.invalid'}}
    $failed=$false;try{Get-TransportCandidates $overlay $work|Out-Null}catch{$failed=$_.Exception.Message -like '*ключ для промежуточного сервера*'}
    Assert $failed 'password-only personal hop cannot silently disappear from persistent transport'
    Set-Item function:Invoke-TransportText $realText;Set-Item function:Get-TransportHostKeys $realHostKeys
    $expected=@('vless-direct','singbox-ssh-direct','vless-relay-relay','vless-sshhop-jump','hy2-edge','hy2obfs-edge','tuic-edge','trojan-edge','reality-edge','shadowtls-edge','ws-direct-edge','ws-cdn-edge','openssh-direct','openssh-jump-jump')
    Assert ($paths.Candidates.Count -eq $expected.Count) 'число кандидатов'
    foreach($tag in $expected){Assert ($tag -in @($paths.Candidates|ForEach-Object {$_.tag})) ('путь '+$tag)}
    $cfg=New-TransportConfig $settings $paths 'test-secret' 'trojan-edge'
    Assert ($cfg.inbounds.Count -eq $expected.Count+2) 'рабочие и проверочные входы'
    Assert ($cfg.inbounds[0].listen_port -eq 2222 -and $cfg.inbounds[1].listen_port -eq 22001) 'рабочие порты'
    Assert ($cfg.inbounds[1].override_port -eq 23456) 'порт синхронизации взят из канала'
    foreach($inbound in $cfg.inbounds){Assert ($inbound.listen -eq '127.0.0.1' -and $inbound.type -eq 'direct' -and $inbound.override_address -eq '127.0.0.1') 'только loopback direct'}
    for($i=0;$i -lt $expected.Count;$i++){
        $c=$paths.Candidates[$i];$in=$cfg.inbounds|Where-Object {$_.tag -eq ('probe-'+$c.tag)}
        $rule=$cfg.route.rules|Where-Object {$_.inbound[0] -eq $in.tag}
        Assert ($in.listen_port -eq 26000+$i -and $in.override_port -eq 22 -and $rule.outbound -eq $c.tag) 'проверочный вход ведёт в свой путь'
    }
    Assert (@($cfg.route.rules|Where-Object {$_.outbound -eq 'active'}).Count -eq 2) 'рабочие входы в selector'
    $selector=$cfg.outbounds|Where-Object {$_.tag -eq 'active'}
    Assert ($selector.type -eq 'selector' -and $selector.default -eq 'trojan-edge' -and -not $selector.interrupt_exist_connections) 'selector без обрыва сессий'
    Assert ($selector.outbounds.Count -eq $expected.Count+1) 'selector содержит кандидатов и недоступный путь'
    Assert ($cfg.experimental.clash_api.external_controller -eq '127.0.0.1:29090' -and $cfg.experimental.clash_api.secret -eq 'test-secret') 'защищённый loopback clash API'
    Assert (@($cfg.inbounds|Where-Object {$_.type -eq 'tun'}).Count -eq 0) 'нет TUN'
    Assert $cfg.route.auto_detect_interface 'bindPhysical по умолчанию'
    $bound=New-TransportConfig $settings $paths 'test-secret' '' 'Ethernet'
    Assert (($bound.outbounds|Where-Object {$_.tag -eq 'vless-direct'}).bind_interface -eq 'Ethernet') 'внешний сокет привязан к NIC'
    Assert (-not ($bound.outbounds|Where-Object {$_.tag -eq 'openssh-direct'}).bind_interface) 'локальный SOCKS не привязан к NIC'
    $options.bindPhysical=$false;$unbound=New-TransportConfig $settings $paths 'test-secret' '' 'Ethernet'
    Assert (-not $unbound.route.auto_detect_interface -and -not ($unbound.outbounds|Where-Object {$_.tag -eq 'vless-direct'}).bind_interface) 'bindPhysical=false';$options.bindPhysical=$true
    $options.apiPort=2222;$bad=$false;try{New-TransportConfig $settings $paths 'x' '' | Out-Null}catch{$bad=$true};Assert $bad 'конфликт портов отвергнут';$options.apiPort=29090
    $rows=@([pscustomobject]@{tag='a';state='ok';kbps=12;checkedAt='2026-01-01T00:00:00Z'},[pscustomobject]@{tag='b';state='ok';kbps=80;checkedAt='2026-01-01T00:00:00Z'},[pscustomobject]@{tag='c';state='frozen';kbps=900;checkedAt=$null})
    Assert ((Get-TransportBest $rows).tag -eq 'b') 'выбор лучшего живого'
    Assert ((Get-TransportBest $rows @('a')).tag -eq 'a') 'ограничение top набора'
    $rankOptions=@{topOnMetered=1}
    Assert (@(Get-TransportRankTags $rows $paths.Candidates $rankOptions $true)[0] -eq 'b') 'на лимитной сети лучший из памяти'
    Assert (@(Get-TransportRankTags $rows $paths.Candidates $rankOptions $null).Count -eq 1) 'неизвестная стоимость экономит трафик'
    Assert (@(Get-TransportRankTags $rows $paths.Candidates $rankOptions $false).Count -eq $paths.Candidates.Count) 'без лимита полный рейтинг'
    $s=New-TransportProbeState 65536 5 45
    [void](Update-TransportProbeState $s 16384 1);[void](Update-TransportProbeState $s 65536 2)
    Assert ($s.state -eq 'ok' -and $s.kbps -eq 32) 'жив и эффективная скорость от начала пробы'
    $s=New-TransportProbeState 65536 5 45;[void](Update-TransportProbeState $s 16384 1);[void](Update-TransportProbeState $s 16384 6)
    Assert ($s.state -eq 'frozen') 'первые 16К и остановка'
    $s=New-TransportProbeState 65536 5 45;[void](Update-TransportProbeState $s 16384 1);[void](Update-TransportProbeState $s 65536 8)
    Assert ($s.state -eq 'frozen') 'возобновление после stall не считается живым'
    $s=New-TransportProbeState 65536 5 10;foreach($time in 1..10){[void](Update-TransportProbeState $s ($time*100) $time)}
    Assert ($s.state -eq 'slow') 'течёт, но N не скачал — не жив'
    Assert (-not (Get-TransportBest @([pscustomobject]@{tag='s';state='slow';kbps=10}))) 'slow не допускается как живой'
    $s=New-TransportProbeState 65536 5 10;[void](Update-TransportProbeState $s 0 10)
    Assert ($s.state -eq 'fail') 'нет первого байта'
    $s=New-TransportProbeState 65536 5 10;[void](Update-TransportProbeState $s 100 1 $true)
    Assert ($s.state -eq 'fail') 'обрыв короткого потока'
    $n1=Get-TransportFingerprint "aa:bb:cc:dd:ee:ff`r`n" "Office`r`n";$n2=Get-TransportFingerprint 'AA-BB-CC-DD-EE-FF' 'Office'
    Assert ($n1 -eq $n2 -and $n1.Length -eq 64) 'CRLF и нормализация MAC'
    Assert ($n1 -ne (Get-TransportFingerprint 'AA-BB-CC-DD-EE-FF' 'Home')) 'разные сети'
    Assert (-not (Get-TransportFingerprint '' 'Home')) 'неизвестный шлюз не имеет отпечатка'
    # Подставляем только Windows cmdlets; алгоритм выбора физического шлюза остаётся настоящим.
    $mockNames=@('Get-NetAdapter','Get-NetRoute','Get-NetIPInterface','Get-NetConnectionProfile','Get-NetNeighbor','Get-NetIPAddress');$priorFunctions=@{}
    foreach($name in $mockNames){if(Test-Path ('function:'+$name)){$priorFunctions[$name]=(Get-Item ('function:'+$name)).ScriptBlock}}
    try{
        function Get-NetRoute {param($DestinationPrefix,$ErrorAction)
            @([pscustomobject]@{InterfaceIndex=1;NextHop='203.0.113.1';RouteMetric=1},[pscustomobject]@{InterfaceIndex=2;NextHop='203.0.113.1';RouteMetric=5},[pscustomobject]@{InterfaceIndex=3;NextHop='203.0.113.1';RouteMetric=100})
        }
        function Get-NetIPInterface {param($InterfaceIndex,$AddressFamily,$ErrorAction)
            $metric=100;if($InterfaceIndex -eq 3){$metric=1};[pscustomobject]@{InterfaceMetric=$metric}
        }
        function Get-NetConnectionProfile {param($InterfaceIndex,$ErrorAction) [pscustomobject]@{Name="Office`r`n"}}
        function Get-NetNeighbor {param($InterfaceIndex,$IPAddress,$ErrorAction) [pscustomobject]@{State='Reachable';LinkLayerAddress='AA:BB:CC:DD:EE:FF'}}
        function Get-NetIPAddress {param($InterfaceIndex,$AddressFamily,$ErrorAction) [pscustomobject]@{AddressState='Preferred';IPAddress='203.0.113.3'}}
        # -Physical — switch у настоящего cmdlet.
        function Get-NetAdapter {param([switch]$Physical,$ErrorAction)
            @([pscustomobject]@{ifIndex=1;Name='Tailscale';InterfaceDescription='Tailscale';Status='Up'},[pscustomobject]@{ifIndex=2;Name='Wi-Fi';InterfaceDescription='Wireless';Status='Up'},[pscustomobject]@{ifIndex=3;Name='Ethernet';InterfaceDescription='Ethernet';Status='Up'})
        }
        $net=Get-TransportNetwork
        Assert ($net.available -and $net.interface -eq 'Ethernet' -and $net.id -eq $n1) 'физический шлюз: исключение VPN и сумма метрик'
    }finally{
        foreach($name in $mockNames){Remove-Item ('function:'+$name);if($priorFunctions.ContainsKey($name)){Set-Item ('function:'+$name) $priorFunctions[$name]}}
    }
    $memory=Read-TransportMemory $work;Save-TransportMemory $work $memory $n1 $rows
    $memory=Read-TransportMemory $work;$remembered=@(Get-TransportRemembered $memory $n1 @([pscustomobject]@{tag='a'},[pscustomobject]@{tag='b'}))
    Assert ((Get-TransportBest $remembered -Remembered).tag -eq 'b') 'память per-network'
    Assert (-not (Get-TransportBest $remembered)) 'память ещё не подтверждает здоровье'
    Assert (@(Get-TransportRemembered $memory 'other' @([pscustomobject]@{tag='a'}))[0].state -eq 'unknown') 'нет переноса рейтинга между сетями'
    $oldLocalAppData=$env:LOCALAPPDATA
    try{
        $env:LOCALAPPDATA=$work
        $profileFile=Join-Path $work 'profile.json';$channelFile=Join-Path $work 'channel.json'
        Write-TransportJson $profileFile $p;Write-TransportJson $channelFile $channel
        Write-TransportJson (Join-Path $work 'config.json') @{version=1;transport=@{profilePath=$profileFile;channelPath=$channelFile}}
        $defaults=Read-TransportSettings $work
        Assert ($defaults.Options.bindPhysical -and $defaults.Options.activeProbeBytes -eq 65536 -and $defaults.Options.rankProbeBytes -eq 262144) 'реальные значения по умолчанию'
        Assert ($defaults.Options.activeIntervalSec -eq 120 -and $defaults.Options.meteredActiveIntervalSec -eq 300 -and $defaults.Options.rankIntervalSec -eq 1800) 'интервалы по умолчанию'
        Assert ($defaults.Options.topOnMetered -eq 3 -and $defaults.Options.apiPort -eq 29090) 'экономный режим и API по умолчанию'
        $personalConfig=Read-TransportJson (Join-Path $work 'config.json')
        $personalConfig|Add-Member wizard ([pscustomobject]@{serverRoute=$personal})
        Write-TransportJson (Join-Path $work 'config.json') $personalConfig
        $restored=Read-TransportSettings $work
        Assert ($restored.Transport.serverRoute.used -eq 'hop' -and $restored.Transport.serverRoute.hop.keyFile -eq $hopKey) 'runtime restores old wizard route as local overlay'
        Assert (-not (Read-TransportJson (Join-Path $work 'config.json')).transport.serverRoute) 'loading old route does not modify persisted settings'
        $revision=Get-TransportRevision $work
        $personalConfig.wizard.serverRoute=[pscustomobject]@{used='direct';hop=$personal.hop}
        Write-TransportJson (Join-Path $work 'config.json') $personalConfig
        Assert ((Get-TransportRevision $work) -ne $revision) 'route changes invalidate transport revision'
        Assert (-not (Read-TransportSettings $work).Transport.serverRoute) 'direct wizard route adds no runtime overlay'
        $personalConfig.transport|Add-Member serverRoute $personal
        Write-TransportJson (Join-Path $work 'config.json') $personalConfig
        Assert ((Read-TransportSettings $work).Transport.serverRoute.used -eq 'hop') 'verified transport overlay survives independent wizard selection'
        $personalConfig.PSObject.Properties.Remove('wizard');$personalConfig.transport.PSObject.Properties.Remove('serverRoute')
        Write-TransportJson (Join-Path $work 'config.json') $personalConfig
        $probeArgs=@(Get-TransportSshArguments $p 26000)
        Assert ('ProxyCommand=none' -in $probeArgs -and ('HostKeyAlias='+$p.serverAddress) -in $probeArgs -and $p.keyPath -in $probeArgs -and ('UserKnownHostsFile="'+$p.knownHostsPath.Replace('\','/')+'"') -in $probeArgs -and '-n' -in $probeArgs) 'SSH-проба использует свой профиль'
        if($keygen){Assert (@(Get-TransportHostKeys $keygen.Source $p.serverAddress $known).Count -eq 1) 'host key из known_hosts'}
        $options.metered='true';Assert (Get-TransportMetered $options) 'явная лимитная сеть'
        $options.metered='false';Assert (-not (Get-TransportMetered $options)) 'явная безлимитная сеть'
    }finally{$env:LOCALAPPDATA=$oldLocalAppData}
    $secret1=Get-TransportSecret $work;$secret2=Get-TransportSecret $work
    Assert ($secret1 -eq $secret2 -and $secret1.Length -ge 40) 'секрет постоянен'
    Write-TransportLog $work 'fatal' 'password=short';Assert (-not ([IO.File]::ReadAllText((Join-Path $work 'logs/transport.log'))).Contains('short')) 'исключение с коротким паролем не пишется в журнал'
    Write-TransportLog $work 'fatal' 'Имена узлов должны быть уникальны @Transport.Common.ps1:12';Assert (([IO.File]::ReadAllText((Join-Path $work 'logs/transport.log'))).Contains('уникальны @Transport.Common.ps1:12')) 'своя причина пишется в журнал'
    Write-TransportLog $work 'fatal' 'Ошибка ключ Zm9vYmFyYmF6cXV4MTIzNDU2 @x.ps1:1';Assert (-not ([IO.File]::ReadAllText((Join-Path $work 'logs/transport.log'))).Contains('Zm9vYmFy')) 'токен в своей причине не пишется'
    Write-TransportLog $work 'switch';Write-TransportLog $work 'password=do-not-log'
    $log=[IO.File]::ReadAllText((Join-Path $work 'logs/transport.log'))
    Assert ($log -notmatch 'do-not-log|password=') 'секреты не попали в журнал'
    [IO.File]::WriteAllText((Join-Path $work 'logs/transport.log'),('x'*1MB));Write-TransportLog $work 'start'
    Assert (Test-Path -LiteralPath (Join-Path $work 'logs/transport.log.1')) 'ротация 1 МБ'
    $status=Join-Path $work 'status/transport.json';Write-TransportJson $status @{ok=$false};Write-TransportJson $status @{ok=$true}
    Assert ((Read-TransportJson $status).ok) 'атомарная замена JSON'
    # Тест настоящего счётчика и pipeline CopyToAsync без SSH/сети.
    Initialize-TransportCounter;$sink=New-Object RemoteAgents.TransportCounter
    try{
        $bytes=New-Object byte[] 16384;$sink.Write($bytes,0,$bytes.Length);Start-Sleep -Milliseconds 20;$sink.Write($bytes,0,$bytes.Length)
        $snapshot=$sink.Snapshot();Assert ($snapshot[0] -eq 32768 -and $snapshot[2] -gt $snapshot[1]) 'счётчик байтов потока'
        $state=New-TransportProbeState 32768 5 45;$probe=[pscustomobject]@{sink=$sink;copy=[Threading.Tasks.Task]::FromResult(0);state=$state}
        Assert ((Receive-TransportProbe $probe) -and $state.state -eq 'ok' -and $state.kbps -gt 0) 'реальный счётчик даёт живой поток'
    }finally{$sink.Dispose()}
    # Регрессия: копирование заканчивается между чтением счётчика и проверкой IsCompleted.
    $source=New-Object 'Threading.Tasks.TaskCompletionSource[int]'
    $freq=[long][Diagnostics.Stopwatch]::Frequency
    $racingSink=[pscustomobject]@{Started=([Diagnostics.Stopwatch]::GetTimestamp()-$freq);step=0;source=$source;freq=$freq}
    $racingSink|Add-Member ScriptMethod Snapshot {
        $bytes=32768
        if($this.step -eq 0){$this.step=1;$this.source.SetResult(0);$bytes=16384}
        [long[]]@($bytes,($this.Started+$this.freq/4),($this.Started+$this.freq/2),8192,0)
    }
    $race=[pscustomobject]@{sink=$racingSink;copy=$source.Task;state=(New-TransportProbeState 32768 5 45)}
    Assert (-not (Receive-TransportProbe $race)) 'завершение CopyToAsync не опережает снимок байтов'
    Assert ((Receive-TransportProbe $race) -and $race.state.state -eq 'ok') 'последние байты принимаются следующим снимком'
    # Задача C: настоящие CLI-команды на CRLF config, без сетевых команд.
    $configFile=Join-Path $work 'config.json';$originalConfig=Read-TransportJson $configFile
    $text=ConvertTo-Json -InputObject $originalConfig -Depth 40
    [IO.File]::WriteAllText($configFile,$text.Replace("`r",'').Replace("`n","`r`n"),(New-Object Text.UTF8Encoding($true)))
    & (Join-Path $PSScriptRoot 'Set-TransportPath.ps1') -Home $work -Tag 'ws-direct-edge'|Out-Null
    $pin=Read-TransportPin $work
    Assert ($pin.mode -eq 'pinned' -and $pin.tag -eq 'ws-direct-edge') 'pin записан CLI атомарно'
    Assert ((Get-TransportSelection $pin $rows $paths.Candidates) -eq 'ws-direct-edge') 'pin игнорирует рейтинг'
    $pin.tag='removed-tag';Assert ((Get-TransportSelection $pin $rows $paths.Candidates) -eq 'removed-tag') 'удалённый pin не подменяется лучшим'
    $blocked=New-TransportConfig $settings $paths 'secret' 'removed-tag'
    Assert (($blocked.outbounds|Where-Object {$_.tag -eq 'active'}).default -eq 'unavailable') 'отсутствующий pin закрыт'
    & (Join-Path $PSScriptRoot 'Set-TransportPath.ps1') -Home $work -Auto|Out-Null
    Assert ((Read-TransportPin $work).mode -eq 'auto') 'auto CLI'
    Assert ((Get-TransportSelection (Read-TransportPin $work) $rows $paths.Candidates) -eq 'b') 'auto выбирает рейтинг'
    & (Join-Path $PSScriptRoot 'Edit-Transport.ps1') -Home $work -AddEntry 'ru-in' -Ssh 'ru-alias' -Kinds @('ws-direct','trojan')|Out-Null
    & (Join-Path $PSScriptRoot 'Edit-Transport.ps1') -Home $work -AddRelay 'relay-two' -Host '203.0.113.88' -Port 443|Out-Null
    & (Join-Path $PSScriptRoot 'Edit-Transport.ps1') -Home $work -AddHop 'hop-two' -Ssh 'hop-alias'|Out-Null
    & (Join-Path $PSScriptRoot 'Edit-Transport.ps1') -Home $work -AddCdn 'cdn-two' -Domain 'cdn.example.com' -Entry 'ru-in' -Path '/other'|Out-Null
    $edited=Read-TransportJson $configFile
    Assert ($edited.transport.entries[0].ssh -eq 'ru-alias' -and $edited.transport.relays[0].host -eq '203.0.113.88' -and $edited.version -eq 1) 'edit сохраняет CRLF config и поля лаунчера'
    & (Join-Path $PSScriptRoot 'Edit-Transport.ps1') -Home $work -Disable 'ru-in'|Out-Null
    & (Join-Path $PSScriptRoot 'Edit-Transport.ps1') -Home $work -Disable 'vless-direct'|Out-Null
    $edited=Read-TransportJson $configFile
    Assert (-not $edited.transport.entries[0].enabled -and 'vless-direct' -in $edited.transport.disabledTags) 'disable имени и tag'
    & (Join-Path $PSScriptRoot 'Edit-Transport.ps1') -Home $work -Enable 'vless-direct'|Out-Null
    & (Join-Path $PSScriptRoot 'Edit-Transport.ps1') -Home $work -Enable 'ru-in'|Out-Null
    Assert ((Read-TransportJson $configFile).transport.entries[0].enabled -and @((Read-TransportJson $configFile).transport.disabledTags).Count -eq 0) 'enable имени и tag'
    $listed=(& (Join-Path $PSScriptRoot 'Edit-Transport.ps1') -Home $work -List)|Out-String
    Assert ((ConvertFrom-Json $listed).cdn[0].path -eq '/other') 'List JSON'
    $rejected=$false;try{& (Join-Path $PSScriptRoot 'Edit-Transport.ps1') -Home $work -Remove 'ru-in'|Out-Null}catch{$rejected=$true};Assert $rejected 'защита от висячего entry CDN'
    foreach($name in @('cdn-two','ru-in','relay-two','hop-two')){& (Join-Path $PSScriptRoot 'Edit-Transport.ps1') -Home $work -Remove $name|Out-Null}
    Assert (@((Read-TransportJson $configFile).transport.entries).Count -eq 0 -and @((Read-TransportJson $configFile).transport.cdn).Count -eq 0) 'Remove всех типов'
    $before=Get-TransportRevision $work;Set-VpnEnabled $work $false
    Assert ((Get-TransportRevision $work) -eq $before) 'vpn не перезапускает основной транспорт'
    Assert (-not (Get-VpnOptions (Read-TransportSettings $work)).enabled) 'vpn выключен по умолчанию'
    # Ограничение kinds, CDN стороннего провайдера, disabledTags, enabled=false без кэша.
    $ct=Copy-TransportObject $t
    $ct.entries[0]|Add-Member kinds @('ws-direct','trojan')
    $ct|Add-Member cdn @([pscustomobject]@{name='russian-cdn';domain='cdn.example.com';path='/cdn';entry='edge';enabled=$true})
    $ct|Add-Member disabledTags @('trojan-edge')
    $ct.entries+=@([pscustomobject]@{name='offline-node';ssh='unused';enabled=$false;kinds=@('hy2')})
    $cs=[pscustomobject]@{Options=$options;Transport=$ct;Profile=$p;Channel=(Copy-TransportObject $channel)}
    $realText=${function:Invoke-TransportText};$realHostKeys=${function:Get-TransportHostKeys}
    try{
        function Invoke-TransportText($Exe,$Arguments){$script:fakeHop}
        function Get-TransportHostKeys($Ssh,$HostName,$KnownHosts){'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDKtkImHp4iQlyBtwBY4Vx3cBxfNF0Hdga/ucaszwI2r'}
        $cp=Get-TransportCandidates $cs $work
    }finally{Set-Item function:Invoke-TransportText $realText;Set-Item function:Get-TransportHostKeys $realHostKeys}
    Assert ('hy2-edge' -notin @($cp.AllCandidates|ForEach-Object {$_.tag}) -and 'hy2-offline-node' -in @($cp.AllCandidates|ForEach-Object {$_.tag})) 'kinds и отключённый узел без чтения кэша'
    Assert ('trojan-edge' -notin @($cp.Candidates|ForEach-Object {$_.tag}) -and -not ($cp.AllCandidates|Where-Object {$_.tag -eq 'trojan-edge'}).enabled) 'отдельный tag исключён из selector'
    $cdn=$cp.Outbounds|Where-Object {$_.tag -eq 'cdn-russian-cdn'}
    Assert (($cp.AllCandidates|Where-Object {$_.tag -eq 'cdn-russian-cdn'}).via -eq 'edge') 'via CDN указывает имя entry'
    Assert ($cdn.server -eq 'cdn.example.com' -and $cdn.transport.path -eq '/cdn' -and $cdn.uuid -eq $e.secrets.ws_uuid) 'CDN берёт uuid из entry и путь из конфига'
    if($SingBox){$file=Join-Path $work 'edited-check.json';Write-TransportJson $file (New-TransportConfig $cs $cp 'test-secret' 'cdn-russian-cdn' 'Ethernet');Test-TransportConfigFile $SingBox $file}
    Assert (($cp.AllCandidates|Where-Object {$_.tag -eq 'ws-direct-edge'}).title -eq 'WebSocket через edge') 'понятные title/kind/via'
    $disabledRows=@(Get-TransportRemembered $memory $n1 $cp.AllCandidates)
    Assert (($disabledRows|Where-Object {$_.tag -eq 'trojan-edge'}).state -eq 'disabled') 'статус отключённого пути'
    $snap=[pscustomobject]@{Processes=@(
        [pscustomobject]@{Name='sing-box.exe';ProcessId=11;ExecutablePath='C:\ours\sing-box.exe'},
        [pscustomobject]@{Name='Happ.exe';ProcessId=12;ExecutablePath='C:\Happ\Happ.exe'},
        [pscustomobject]@{Name='sing-box.exe';ProcessId=13;ExecutablePath='C:\foreign\sing-box.exe'});
        Adapters=@([pscustomobject]@{ifIndex=1;Name='OpenVPN';Status='Up';InterfaceDescription='TAP-Windows OpenVPN'},
            [pscustomobject]@{ifIndex=2;Name='Tailscale';Status='Up';InterfaceDescription='Tailscale Tunnel'},
            [pscustomobject]@{ifIndex=3;Name='OtherVPN';Status='Up';InterfaceDescription='Wintun'},
            [pscustomobject]@{ifIndex=4;Name='RemoteAgents-TUN';Status='Up';InterfaceDescription='Wintun'});
        Routes=@([pscustomobject]@{DestinationPrefix='192.0.2.0/24';InterfaceIndex=1;NextHop='198.51.100.9'},
            [pscustomobject]@{DestinationPrefix='0.0.0.0/1';InterfaceIndex=1;NextHop='198.51.100.9'},
            [pscustomobject]@{DestinationPrefix='128.0.0.0/1';InterfaceIndex=3;NextHop='0.0.0.0'})}
    $conf=Find-VpnConflicts $snap @(11) 'RemoteAgents-TUN'
    Assert ($conf.conflict -and $conf.items.Count -eq 2) 'конфликты: только адаптер и маршрут'
    Assert (@($conf.items|Where-Object {$_.name -in @('OpenVPN','Tailscale','RemoteAgents-TUN')}).Count -eq 0) 'OpenVPN/Tailscale/наш адаптер не конфликтуют'
    Assert (@($conf.items|Where-Object {$_.kind -eq 'process'}).Count -eq 0) 'процессы служат лишь подсказкой имени'
    $empty=[pscustomobject]@{Processes=@();Adapters=@();Routes=@()}
    Assert (-not (Find-VpnConflicts $empty).conflict) 'нет конфликтов на пустом снимке'
    $idle=[pscustomobject]@{Processes=@([pscustomobject]@{Name='sing-box.exe';ProcessId=71;ExecutablePath='C:\Local\Tools\sing-box.exe'},[pscustomobject]@{Name='AmneziaVPN-service.exe';ProcessId=72});Adapters=@();Routes=@()}
    Assert (-not (Find-VpnConflicts $idle).conflict) 'старый канал и Amnezia-служба без туннеля не конфликт'
    foreach($name in @('happ-default-tun','happ-xray')){
        $happ=[pscustomobject]@{Processes=$idle.Processes;Adapters=@([pscustomobject]@{ifIndex=9;Name=$name;Status='Up';InterfaceDescription=$(if($name -eq 'happ-default-tun'){'SocksTunnel Tunnel'}else{'Happ Virtual Adapter'});HardwareInterface=$false});Routes=@([pscustomobject]@{DestinationPrefix='0.0.0.0/0';InterfaceIndex=9;NextHop='0.0.0.0'})}
        Assert ((Find-VpnConflicts $happ).conflict) ('реальный Happ default через '+$name)
        $happ.Routes=@([pscustomobject]@{DestinationPrefix='0.0.0.0/1';InterfaceIndex=9;NextHop='0.0.0.0'},[pscustomobject]@{DestinationPrefix='128.0.0.0/1';InterfaceIndex=9;NextHop='0.0.0.0'})
        Assert ((Find-VpnConflicts $happ).conflict) ('split-default через '+$name)
    }
    $physical=[pscustomobject]@{Processes=$idle.Processes;Adapters=@([pscustomobject]@{ifIndex=5;Name='Ethernet';Status='Up';HardwareInterface=$true;Virtual=$false;InterfaceDescription='Ethernet'});Routes=@([pscustomobject]@{DestinationPrefix='0.0.0.0/0';InterfaceIndex=5;NextHop='192.0.2.1'})}
    Assert (-not (Find-VpnConflicts $physical).conflict) 'физический default с VPN-службой не конфликт'
    $settings|Add-Member Vpn ([pscustomobject]@{enabled=$false;excludeCidrs=@('198.51.100.0/24')})
    $realText=${function:Invoke-TransportText}
    try{function Invoke-TransportText($Exe,$Arguments){$script:fakeHop}
        $exclusions=Get-VpnExclusions $settings $paths $snap @{'entry.example.com'=@('203.0.113.55')} -Root $work
    }finally{Set-Item function:Invoke-TransportText $realText}
    foreach($cidr in @('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16','100.64.0.0/10','169.254.0.0/16','224.0.0.0/4','203.0.113.10/32','203.0.113.20/32','203.0.113.30/32','203.0.113.40/32','203.0.113.55/32','192.0.2.0/24','198.51.100.9/32','198.51.100.0/24')){Assert ($cidr -in $exclusions) ('TUN исключение '+$cidr)}
    Assert ('0.0.0.0/1' -notin $exclusions) 'OpenVPN default не исключает весь интернет'
    $tunConfigs=@()
    foreach($candidate in $paths.Candidates){
        if($candidate.tunCapable){
            $tun=New-VpnTunConfig $settings $paths $candidate.tag $exclusions 'Ethernet';$tunConfigs+=@($tun)
            Assert ($tun.inbounds[0].type -eq 'tun' -and $tun.inbounds[0].auto_route -and -not $tun.inbounds[0].strict_route -and $tun.inbounds[0].stack -eq 'system') 'TUN system/auto_route/strict_route'
            Assert (@($tun.outbounds|Where-Object {$_.type -in @('ssh','socks')}).Count -eq 0 -and $tun.route.final -eq 'vpn-active') 'TUN без SSH и direct fallback'
            Assert (($tun.route.rules[0].override_address -eq $settings.Profile.serverAddress) -and $tun.route.rules[0].override_port -eq (Get-TransportServerPort $settings.Profile)) 'служебная проба идёт до SSH сервера через TUN'
            if($SingBox){$file=Join-Path $work 'tun-check.json';Write-TransportJson $file $tun;Test-TransportConfigFile $SingBox $file}
        }else{
            $bad=$false;try{New-VpnTunConfig $settings $paths $candidate.tag $exclusions 'Ethernet'|Out-Null}catch{$bad=$true};Assert $bad ('SSH запрещён в TUN '+$candidate.tag)
        }
    }
    Assert ($tunConfigs.Count -eq 10) 'TUN check для всех 10 интернет-путей'
    # Find-NetRoute возвращает IPAddress И Route: тестируем оба объекта и чужой интерфейс.
    function Find-NetRoute {param($RemoteIPAddress,$ErrorAction) @([pscustomobject]@{IPAddress='172.31.255.1';InterfaceIndex=4},[pscustomobject]@{DestinationPrefix='0.0.0.0/1';InterfaceIndex=4})}
    try{Assert-VpnTunRoute '198.18.0.1' 4;$bad=$false;try{Assert-VpnTunRoute '198.18.0.1' 3}catch{$bad=$true};Assert $bad 'маршрут вне TUN отвергается'}finally{Remove-Item function:Find-NetRoute}
    # Проверяем watchdog на mock ScheduledTasks: никакие настоящие задачи не создаются.
    $oldSystemRoot=$env:SystemRoot;$env:SystemRoot=$work;$taskCalls=@{}
    function New-ScheduledTaskAction {param($Execute,$Argument) $script:taskCalls.action=[pscustomobject]@{Execute=$Execute;Argument=$Argument};$script:taskCalls.action}
    function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel) $script:taskCalls.principal=$RunLevel;@{}}
    function New-ScheduledTaskSettingsSet {param([switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,[switch]$StartWhenAvailable,$ExecutionTimeLimit) @{}}
    function New-ScheduledTaskTrigger {param([switch]$Once,$At) $script:taskCalls.at=$At;@{}}
    function Register-ScheduledTask {param($TaskName,$Action,$Trigger,$Principal,$Settings,[switch]$Force) $script:taskCalls.name=$TaskName}
    # WindowsIdentity недоступен на Linux: отдельный helper principal тестируется через mock ниже.
    # Сама сборка action/trigger вынесена в переносимую функцию; UserId передаётся явно.
    try{
        Register-VpnRollbackTask $work 'test-session' (Join-Path $PSScriptRoot 'Vpn.Tun.ps1') -UserId 'test-user'
        Assert ($taskCalls.name -eq (Get-VpnTaskNames $work).Rollback -and $taskCalls.principal -eq 'Highest') 'отдельная задача отката с highest'
        Assert (($taskCalls.at-(Get-Date)).TotalSeconds -gt 295 -and ($taskCalls.at-(Get-Date)).TotalSeconds -le 300) 'watchdog через пять минут'
        Assert ($taskCalls.action.Argument -match '-Rollback' -and $taskCalls.action.Argument -match 'test-session') 'watchdog привязан к своему сеансу'
    }finally{
        $env:SystemRoot=$oldSystemRoot
        foreach($name in @('New-ScheduledTaskAction','New-ScheduledTaskPrincipal','New-ScheduledTaskSettingsSet','New-ScheduledTaskTrigger','Register-ScheduledTask')){Remove-Item ('function:'+$name)}
    }
    $ownerTime=[DateTime]::UtcNow
    Write-TransportJson (Join-Path $work 'state/transport-owner.json') @{pid=111;exe=(Join-Path $work 'sing-box.exe');config=(Join-Path $work 'state/transport-sing-box.json');startedAt=$ownerTime.ToString('o')}
    $ownership=[pscustomobject]@{Processes=@(
        [pscustomobject]@{ProcessId=111;ExecutablePath=(Join-Path $work 'foreign.exe');CommandLine=(Join-Path $work 'state/transport-sing-box.json');CreationDate=$ownerTime})}
    Assert (@(Get-VpnOwnedProcessIds $work $ownership).Count -eq 0) 'повторно использованный PID чужого процесса не наш'
    $ownership.Processes[0].ExecutablePath=Join-Path $work 'sing-box.exe'
    Assert (@(Get-VpnOwnedProcessIds $work $ownership)[0] -eq 111) 'наш процесс проверяется по PID, exe, config и времени'
    $ownership.Processes[0].CommandLine+='.foreign';Assert (@(Get-VpnOwnedProcessIds $work $ownership).Count -eq 0) 'совпадение префикса config не даёт права остановить чужой процесс'
    # Синхронизация отсутствующего client.json: только фиксированная SSH-команда, CRLF нормализуется.
    $ss=[pscustomobject]@{Profile=$p;Transport=[pscustomobject]@{entries=@([pscustomobject]@{name='new-node';ssh='new-alias';enabled=$true})}}
    $realText=${function:Invoke-TransportText};$script:cacheCalls=0
    try{function Invoke-TransportText($Exe,$Arguments){$script:cacheCalls++;Assert ($Arguments[-1] -eq 'cat /opt/rd-entry/client.json' -and '-o' -in $Arguments) 'фиксированная команда получения кэша';(ConvertTo-Json $e -Depth 20).Replace("`r",'').Replace("`n","`r`n")}
        Sync-TransportEntryCache $ss $work;Sync-TransportEntryCache $ss $work
        Assert ($cacheCalls -eq 1 -and (Read-TransportJson (Join-Path $work 'secrets/entries/new-node.json')).server -eq $e.server) 'новый кэш загружается один раз без сети в тесте'
    }finally{Set-Item function:Invoke-TransportText $realText}

    # Очистка ограничена GUID, а не переиспользованным именем/индексом адаптера.
    Write-TransportJson (Join-Path $work 'state/vpn-interface.json') @{session='cleanup-test';guid='our-guid';name='RemoteAgents-TUN'}
    $script:removedRoutes=@();$script:mockGuid='foreign-guid';$script:routeRemoved=$false
    function Get-NetAdapter {param([switch]$IncludeHidden,$ErrorAction) [pscustomobject]@{InterfaceGuid=$script:mockGuid;Name='RemoteAgents-TUN';ifIndex=44}}
    function Get-NetRoute {param($InterfaceIndex,$ErrorAction) if(-not $script:routeRemoved){[pscustomobject]@{InterfaceIndex=$InterfaceIndex;DestinationPrefix='0.0.0.0/1'}}}
    function Remove-NetRoute {param([Parameter(ValueFromPipeline=$true)]$InputObject,[switch]$Confirm) process {$script:removedRoutes+=@($InputObject);$script:routeRemoved=$true}}
    try{
        Clear-VpnRoutes $work 'other-session'
        Assert ((Test-Path -LiteralPath (Join-Path $work 'state/vpn-interface.json')) -and $removedRoutes.Count -eq 0) 'старый сеанс не очищает новый'
        Clear-VpnRoutes $work 'cleanup-test'
        Assert ($removedRoutes.Count -eq 0) 'GUID чужого адаптера не трогаем'
        Write-TransportJson (Join-Path $work 'state/vpn-interface.json') @{session='cleanup-test';guid='our-guid';name='RemoteAgents-TUN'}
        $script:mockGuid='our-guid';Clear-VpnRoutes $work 'cleanup-test'
        Assert ($removedRoutes.Count -eq 1 -and $removedRoutes[0].InterfaceIndex -eq 44) 'удалены только маршруты нашего GUID'
    }finally{foreach($name in @('Get-NetAdapter','Get-NetRoute','Remove-NetRoute')){Remove-Item ('function:'+$name)}}
    $time=[DateTime]::UtcNow
    Assert ([Math]::Abs(((Convert-TransportUtc $time.ToString('o'))-$time).TotalMilliseconds) -lt 1 -and [Math]::Abs(((Convert-TransportUtc $time)-$time).TotalMilliseconds) -lt 1) 'UTC одинаков для JSON PS5 string и PS7 DateTime'

    # АСТ содержит только синтаксис PS 5.1: запрещаем PS7-only операторы.
    foreach($scriptFile in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1'){
        $source=[IO.File]::ReadAllBytes($scriptFile.FullName);Assert ($source.Length -ge 3 -and $source[0] -eq 239 -and $source[1] -eq 187 -and $source[2] -eq 191) ('UTF-8 BOM '+$scriptFile.Name)
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName,[ref]$tokens,[ref]$errors)
        Assert (@($errors).Count -eq 0) ('парсер '+$scriptFile.Name)
        Assert (@($tokens|Where-Object {$_.Kind.ToString() -in @('QuestionQuestion','QuestionQuestionEquals','QuestionMark','AndAnd','OrOr')}).Count -eq 0) ('нет PS7 операторов '+$scriptFile.Name)
    }

    if($OutputConfig){Write-TransportJson ([IO.Path]::GetFullPath($OutputConfig)) $cfg}
    if($SingBox){
        $file=Join-Path $work 'check.json';Write-TransportJson $file $cfg
        & $SingBox check -c $file
        if($LASTEXITCODE -ne 0){throw 'sing-box check не прошёл'}
        # Настоящий Clash API без внешнего трафика: не открываем рабочие TCP-пути.
        $apiConfig=Copy-TransportObject $cfg;$listeners=New-Object Collections.ArrayList;$child=$null
        try{
            $used=@{}
            foreach($input in $apiConfig.inbounds){
                $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$listener.Start();[void]$listeners.Add($listener)
                $input.listen_port=$listener.LocalEndpoint.Port;$used[[int]$input.listen_port]=$true
            }
            $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$listener.Start();[void]$listeners.Add($listener)
            $apiOptions=@{apiPort=$listener.LocalEndpoint.Port};$apiConfig.experimental.clash_api.external_controller='127.0.0.1:'+$apiOptions.apiPort
            Write-TransportJson $file $apiConfig
            foreach($listener in $listeners){$listener.Stop()};$listeners.Clear()
            $child=Start-TransportProcess $SingBox @('run','-c',$file);$ready=$false
            for($i=0;$i -lt 40;$i++){
                try{Set-TransportSelector $apiOptions 'test-secret' 'hy2-edge';$ready=$true;break}catch{Start-Sleep -Milliseconds 100}
                if($child.Process.HasExited){throw 'sing-box run не запустился'}
            }
            Assert $ready 'настоящий PUT /proxies/active'
            $req=[Net.HttpWebRequest]::Create(('http://127.0.0.1:'+$apiOptions.apiPort+'/proxies/active'));$req.Proxy=$null;$req.Timeout=1500;$req.Headers['Authorization']='Bearer test-secret'
            $response=$req.GetResponse();$reader=New-Object IO.StreamReader($response.GetResponseStream())
            try{$selected=ConvertFrom-Json $reader.ReadToEnd()}finally{$reader.Dispose();$response.Dispose()}
            Assert ($selected.now -eq 'hy2-edge' -and -not $child.Process.HasExited) 'API сменил selector в том же процессе'
            $rejected=$false;try{Set-TransportSelector $apiOptions 'wrong-secret' 'trojan-edge'}catch{$rejected=$true}
            Assert $rejected 'API отвергает неправильный секрет'
        }finally{foreach($listener in $listeners){$listener.Stop()};Stop-TransportProcess $child}
    }
    Write-TransportJson (Join-Path $work 'status/transport.json') @{ok=$true;updatedAt=[DateTime]::UtcNow.AddMinutes(1).ToString('o');candidates=@()}
    $futureStatus=(& (Join-Path $PSScriptRoot 'Get-TransportStatus.ps1') -Home $work) -join "`n"
    Assert ($futureStatus.Contains('статус устарел') -and -not $futureStatus.Contains('соединение проверено')) 'будущий статус после перевода часов не считается проверенной связью'
    $sshOnly=Copy-TransportObject $settings
    $sshOnly.Channel=[pscustomobject]@{inbounds=@();outbounds=@()}
    $generated=New-TransportConfig $sshOnly $paths 'fixture' 'unavailable'
    Assert (@($generated.inbounds|Where-Object {$_.tag -eq 'ssh'}).Count -eq 1) 'SSH-only channel retains SSH inbound'
    Assert (@($generated.inbounds|Where-Object {$_.tag -eq 'sync'}).Count -eq 0) 'SSH-only channel has no fabricated Syncthing port'
    $sshOnly.Channel.inbounds=@([pscustomobject]@{tag='sync';override_port=23456})
    $generated=New-TransportConfig $sshOnly $paths 'fixture' 'unavailable'
    Assert (@($generated.inbounds|Where-Object {$_.tag -eq 'sync' -and $_.override_port -eq 23456}).Count -eq 1) 'disk port can be added later'
    Write-Output ('OK: '+$count+' проверок без сети')
}finally{Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
