#requires -Version 5.1
[CmdletBinding()]
param([string]$OutputConfig='',[string]$SingBox='',[switch]$LanOnly)
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
$work=Join-Path ([IO.Path]::GetTempPath()) ('transport-test-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($work)
$count=0
function Assert($Condition,[string]$Message){if(-not $Condition){throw ('Тест: '+$Message)};$script:count++}

# Evaluate the generated ACL with supplied DNS answers: no DNS queries or sockets.
function Test-LanRuleMatch($Rule,[string]$Name,[string]$Address) {
    if($Rule.type -eq 'logical'){
        $values=@($Rule.rules|ForEach-Object {Test-LanRuleMatch $_ $Name $Address})
        if($Rule.mode -eq 'and'){return $false -notin $values}
        return $true -in $values
    }
    if($Rule.inbound -and 'lan-in' -notin $Rule.inbound){return $false}
    if($Rule.domain){return $Name -in $Rule.domain}
    if($Rule.domain_regex){foreach($pattern in $Rule.domain_regex){if($Name -match $pattern){return $true}};return $false}
    if($Rule.ip_cidr){
        foreach($answer in $Address.Split(',')){
            $ip=Assert-LanIPv4 $answer
            foreach($cidr in $Rule.ip_cidr){$parts=$cidr.Split('/');$start=Assert-LanIPv4 $parts[0];if($ip -ge $start -and $ip -lt $start+[Math]::Pow(2,32-[int]$parts[1])){return $true}}
        }
        return $false
    }
    return $true
}
function Get-LanDecision($Config,[string]$Name,[string]$Address) {
    foreach($rule in $Config.route.rules){
        if($rule.action -eq 'resolve'){continue}
        if(Test-LanRuleMatch $rule $Name $Address){return $rule.action}
    }
    return 'fallthrough'
}
function Test-LanIngress($Root) {
    $fixture=Read-TransportJson (Join-Path $PSScriptRoot '../server/lan-pc-access.clinic.example.json')
    $clinic=$fixture.lans[0]
    $raw=[pscustomobject]@{profile=[pscustomobject]@{lan=@(
        [pscustomobject]@{name=$clinic.name;testHost=$clinic.testHost;testPort=$clinic.testPort;share=[pscustomobject]@{subnets=$clinic.subnets;domains=$clinic.domains;dnsServers=$clinic.dnsServers;hosts=$clinic.hosts}},
        [pscustomobject]@{name='off';testHost='10.90.0.1';testPort=22;share=[pscustomobject]@{enabled=$false;subnets=@('10.90.0.0/24');domains=@('*.off.example.org');dnsServers=@('10.90.0.53')}},
        [pscustomobject]@{name='other';testHost='10.91.0.1';testPort=22;share=[pscustomobject]@{subnets=@('10.91.0.0/24');domains=@('*.other.example.org');dnsServers=@('10.91.0.53')}}
    )}}
    $settings=[pscustomobject]@{Root=$Root;Options=@{sshPort=2222;syncPort=22001;lanProxyPort=17880;vpnInPort=17881;apiPort=29090;bindPhysical=$false};Profile=[pscustomobject]@{};Channel=[pscustomobject]@{inbounds=@()};Transport=[pscustomobject]@{};Lan=(Get-TransportLan $raw)}
    $paths=[pscustomobject]@{Candidates=@([pscustomobject]@{tag='fixture';port=26000});Outbounds=@(@{type='socks';tag='fixture';server='127.0.0.1';server_port=28000})}
    $cfg=New-TransportConfig $settings $paths 'test-secret' 'fixture'
    Assert (@($cfg.dns.servers|Where-Object {$_.tag -like 'lan-dns-*'}).Count -eq 2 -and $cfg.dns.servers[1].type -eq 'tcp' -and $cfg.dns.servers[1].server -eq '192.168.88.11' -and $cfg.dns.servers[1].detour -eq 'active') 'каждая включённая ЛВС резолвится своим DNS по TCP через канал'
    Assert ($cfg.dns.final -eq 'transport-local' -and $cfg.dns.servers[0].type -eq 'local') 'обычные имена транспорта сохраняют системный DNS'
    Assert ($settings.Lan.networks[0].hosts[0] -eq 'portal.eastclinic.ru') 'hosts доходят до транспорта'
    Assert ((Get-LanDecision $cfg 'portal.eastclinic.ru' '192.168.88.244') -eq 'route') 'CONNECT по имени с ответом DNS из своей подсети разрешён'
    Assert ((Get-LanDecision $cfg 'portal.eastclinic.ru' '10.91.0.10') -eq 'reject') 'имя не получает доступ к подсети другой включённой ЛВС'
    foreach($public in @('151.236.83.93','212.41.27.201')){
        Assert ((Get-LanDecision $cfg 'eastclinic.ru' $public) -eq 'reject') 'корень wildcard не разрешён'
        Assert ((Get-LanDecision $cfg 'mobile.eastclinic.ru' $public) -eq 'reject') 'публичный ответ для разрешённого имени не уходит в ЛВС'
    }
    Assert ((Get-LanDecision $cfg 'portal.eastclinic.ru' '192.168.88.244,151.236.83.93') -eq 'reject') 'смешанный частный и публичный DNS-ответ отклоняется целиком'
    Assert ((Get-LanDecision $cfg 'eastclinic.ru' '192.168.88.244') -eq 'reject') '*.домен не включает корень даже с частным ответом'
    Assert ((Get-LanDecision $cfg 'unlisted.example.org' '192.168.88.244') -eq 'reject') 'неразрешённое имя не проходит через агрегат подсетей'
    Assert ((Get-LanDecision $cfg 'x.off.example.org' '10.90.0.10') -eq 'reject') 'выключенная сеть не разрешает имена'
    Assert ((Get-LanDecision $cfg '' '192.168.88.244') -eq 'route') 'числовые адреса ЛВС сохранены'
    Assert ((Get-LanDecision $cfg '' '151.236.83.93') -eq 'reject') 'завершающий reject числовых публичных адресов сохранён'
    $raw.profile.lan[0].share.domains=@('portal.eastclinic.ru')
    $settings.Lan=Get-TransportLan $raw
    $exact=New-TransportConfig $settings $paths 'test-secret' 'fixture'
    Assert ((Get-LanDecision $exact 'portal.eastclinic.ru' '192.168.88.244') -eq 'route' -and (Get-LanDecision $exact 'sub.portal.eastclinic.ru' '192.168.88.244') -eq 'reject') 'точное имя не включает поддомены'
    $raw.profile.lan[0].share|Add-Member -Force enabled $false;$raw.profile.lan[2].share|Add-Member -Force enabled $false
    $settings.Lan=Get-TransportLan $raw
    $disabled=New-TransportConfig $settings $paths 'test-secret' 'fixture'
    Assert (-not $disabled.dns -and (Get-LanDecision $disabled 'portal.eastclinic.ru' '192.168.88.244') -eq 'reject') 'все сети выключены: нет DNS, доступ закрыт'
    if($SingBox){$file=Join-Path $Root 'lan-only-check.json';Write-TransportJson $file $cfg;Test-TransportConfigFile $SingBox $file}
}
try{
    if($LanOnly){Test-LanIngress $work;Write-Output ('OK: '+$count+' LAN проверок без сети');return}
    # LAN contract only: no sockets, TUN, DNS requests or server changes.
    $lanOld=('{"profile":{"lan":[{"name":"office","kind":"openvpn","testHost":"10.123.0.10","testPort":443,"share":{"subnets":["10.123.0.0/24"]}}]}}'.Insert(1,"`r`n")|ConvertFrom-Json)
    $lan=Get-TransportLan $lanOld
    Assert ($lan.enabled -and @($lan.networks).Count -eq 1 -and $lan.networks[0].enabled -and @($lan.networks[0].dnsServers).Count -eq 0) 'old CRLF LAN defaults to enabled and empty DNS'
    $lanOld.profile.lan[0].share|Add-Member domains @('*.example.org')
    $message='';try{Get-TransportLan $lanOld|Out-Null}catch{$message=$_.Exception.Message}
    Assert ($message -eq 'Для доменов сети office укажите share.dnsServers (DNS-серверы внутри ЛВС)') 'domains without DNS name the affected LAN'
    $lanOld.profile.lan[0].share|Add-Member dnsServers @('10.123.0.53')
    $lanOld.profile.lan[0].share|Add-Member forwards @([pscustomobject]@{name='legacy';host='legacy.example.net';port=5432;localPort=15432})
    $lan=Get-TransportLan $lanOld
    Assert (@($lan.forwards).Count -eq 0 -and $lan.dnsServers[0] -eq '10.123.0.53') 'deprecated forwards ignored, DNS retained'
    $branch=[pscustomobject]@{name='branch';testHost='10.124.0.10';testPort=22;share=[pscustomobject]@{subnets=@('10.124.0.0/24');domains=@('*.branch.example.org');dnsServers=@('10.124.0.53');enabled=$true}}
    $lanOld.profile.lan+=@($branch)
    $lan=Get-TransportLan $lanOld
    Assert (@($lan.networks).Count -eq 2 -and @($lan.subnets).Count -eq 2 -and @($lan.dnsServers).Count -eq 2 -and $lan.probeHost -eq '10.123.0.10') 'separate LANs retain legacy aggregate and first active probe'
    Assert ($lan.networks[1].name -eq 'branch' -and $lan.networks[1].subnets[0] -eq '10.124.0.0/24' -and $lan.networks[1].domains[0] -eq '*.branch.example.org' -and $lan.networks[1].dnsServers[0] -eq '10.124.0.53' -and $lan.networks[1].testPort -eq 22) 'each row keeps its own DNS and probe'
    $lanOld.profile.lan[0].share|Add-Member enabled $false
    $lan=Get-TransportLan $lanOld
    Assert (@($lan.networks).Count -eq 2 -and -not $lan.networks[0].enabled -and @($lan.subnets).Count -eq 1 -and $lan.probeHost -eq '10.124.0.10') 'disabled LAN stays listed without legacy destinations'
    foreach($badDns in @('8.8.8.8','10.124.0.53','10.123.0.999','10.123.0.053','::1')){
        $bad=Copy-TransportObject $lanOld;$bad.profile.lan[0].share.dnsServers=@($badDns)
        $rejected=$false;try{Get-TransportLan $bad|Out-Null}catch{$rejected=$true}
        Assert $rejected ('reject invalid or foreign DNS '+$badDns)
    }
    foreach($badDns in @('"10.123.0.53"','null','[null]','[53]','["10.123.0.53","10.123.0.53"]','["10.123.0.51","10.123.0.52","10.123.0.53","10.123.0.54","10.123.0.55"]')){
        $bad=Copy-TransportObject $lanOld;$bad.profile.lan[0].share.dnsServers=('{"value":'+$badDns+'}'|ConvertFrom-Json).value
        $rejected=$false;try{Get-TransportLan $bad|Out-Null}catch{$rejected=$true}
        Assert $rejected 'reject invalid DNS shape, duplicates or count'
    }
    foreach($badEnabled in @('false',0)){
        $bad=Copy-TransportObject $lanOld;$bad.profile.lan[0].share.enabled=$badEnabled
        $rejected=$false;try{Get-TransportLan $bad|Out-Null}catch{$rejected=$true}
        Assert $rejected 'enabled is a boolean'
    }
    $branch.share.enabled=$false
    Assert (-not (Get-TransportLan $lanOld).enabled) 'all LANs disabled keep legacy proxy disabled'
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
        # User SSH config can contain Match exec/CanonicalizeHostname and block even ssh -G.
        # This offline argument test must use its own empty config.
        $emptySshConfig=Join-Path $work 'ssh-empty.conf';[IO.File]::WriteAllText($emptySshConfig,'')
        $sshCommand=Get-Command ssh -CommandType Application|Select-Object -First 1
        $effective=(Invoke-TransportText $sshCommand.Source (@('-F',$emptySshConfig,'-G')+@(Get-TransportSshArguments $spaceProfile 22371)+@('example.invalid')))
        Assert ($effective.Contains('hostname example.invalid')) 'OpenSSH -G uses only the isolated test config'
        Assert ($effective.Contains('userknownhostsfile '+$spaceKnown)) 'OpenSSH сохраняет путь known_hosts с пробелом и кириллицей'
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
    $options=@{sshPort=2222;syncPort=22001;lanProxyPort=17880;vpnInPort=17881;probePortBase=26000;socksPortBase=28000;apiPort=29090;bindPhysical=$true;openSsh=$true;stallSeconds=5;probeTimeoutSec=45}
    $settings=[pscustomobject]@{Root=$work;Options=$options;Transport=$t;Profile=$p;Channel=(Copy-TransportObject $channel)}
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
    $keySettings=[pscustomobject]@{Root=$work;Options=$options;Transport=$keyHop;Profile=$p;Channel=(Copy-TransportObject $channel)}
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
    [IO.File]::WriteAllText((Join-Path $work 'known_hosts-hop'),'fixture')
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
    $overlay|Add-Member -Force LocalWeb ([pscustomobject]@{enabled=$true;available=$true;port=47831;serverPort=47832})
    $proxyWeb=New-TransportConfig $overlay $proxyPaths 'test-secret' 'openssh-proxy'
    Assert (@($proxyWeb.inbounds|Where-Object {$_.tag -eq 'happier-web' -and $_.override_port -eq 47832}).Count -eq 1 -and ($proxyWeb.outbounds|Where-Object {$_.tag -eq 'active'}).default -eq 'openssh-proxy') 'OpenSSH proxy keeps Happier input'

    Remove-Item $helper
    $failedPaths=Get-TransportCandidates $overlay $work
    Assert ('openssh-proxy' -notin @($failedPaths.Candidates.tag) -and ($failedPaths.AllCandidates|Where-Object {$_.tag -eq 'openssh-proxy'}).buildFailed) 'proxy without helper fails per candidate'
    $overlay.Transport.serverRoute=[pscustomobject]@{used='hop';hop=[pscustomobject]@{ssh='hop.example.invalid'}}
    $failedPaths=Get-TransportCandidates $overlay $work
    Assert ('openssh-jump-wizard-server-route' -notin @($failedPaths.Candidates.tag) -and ($failedPaths.AllCandidates|Where-Object {$_.tag -eq 'openssh-jump-wizard-server-route'}).buildFailed) 'password-only hop remains visible as failed candidate'
    Set-Item function:Invoke-TransportText $realText;Set-Item function:Get-TransportHostKeys $realHostKeys
    # Real host-key lookup: code 1 means no match; missing files are diagnosed before ssh-keygen.
    $reason=$null;try{Get-TransportHostKeys 'ssh' 'absent.example.invalid' $known|Out-Null}catch{$reason=$_.Exception.Data['transportReason']}
    Assert ($reason -eq 'host-key-missing') 'ssh-keygen -F exit 1 is a missing pin, not command failure'
    $reason=$null;try{Get-TransportHostKeys 'ssh' 'example.invalid' (Join-Path $work 'absent-known')|Out-Null}catch{$reason=$_.Exception.Data['transportReason']}
    Assert ($reason -eq 'host-key-missing') 'missing known_hosts file has explicit reason'
    $reason=$null;$message='';try{Invoke-TransportText (Join-Path $work 'absent-executable') @()|Out-Null}catch{$reason=$_.Exception.Data['transportDiagnostic'].reason;$message=$_.Exception.Message}
    Assert ($reason -eq 'executable-not-found' -and $message -eq 'Программа или файл запуска не найдены') 'missing executable differs from nonzero exit'
    $reason=$null;$exitCode=$null;try{Invoke-TransportText (Get-TransportPowerShell) @('-NoProfile','-NonInteractive','-Command','exit 7')|Out-Null}catch{$reason=$_.Exception.Data['transportDiagnostic'].reason;$exitCode=$_.Exception.Data['transportDiagnostic'].exitCode}
    Assert ($reason -eq 'command-failed' -and $exitCode -eq 7) 'nonzero exit is retained without raw output'
    # Old local hop overlay with no host pin must not hide working VLESS/relay or occupy selector/rank slots.
    $broken=Copy-TransportObject $settings;$broken.Transport|Add-Member serverRoute $personal
    $broken.Transport.entries=@();$broken.Transport.hops=@()
    Remove-Item -LiteralPath (Join-Path $work 'known_hosts-hop')
    $brokenPaths=Get-TransportCandidates $broken $work
    $badTags=@('vless-sshhop-wizard-server-route','openssh-jump-wizard-server-route')
    Assert ('vless-direct' -in @($brokenPaths.Candidates.tag) -and 'vless-relay-relay' -in @($brokenPaths.Candidates.tag)) 'missing overlay pin keeps direct VLESS and relay'
    Assert (@($brokenPaths.Candidates|Where-Object {$_.tag -in $badTags}).Count -eq 0 -and @($brokenPaths.Tunnels|Where-Object {$_.tag -in $badTags}).Count -eq 0) 'failed overlay has no selector path or SSH tunnel'
    $oldMemory=@{version=1;networks=@{fixture=@{candidates=@([pscustomobject]@{tag=$badTags[0];state='ok';kbps=99999;checkedAt='2026-01-01T00:00:00Z'})}}}
    $failedRows=@(Get-TransportRemembered $oldMemory 'fixture' $brokenPaths.AllCandidates)
    Assert (@($failedRows|Where-Object {$_.tag -in $badTags -and $_.state -eq 'fail' -and $_.diagnostic.reason -eq 'hop-host-key-missing' -and $_.diagnostic.stderr -eq 'Нет ключа хоста промежуточного сервера' -and $null -eq $_.kbps}).Count -eq 2) 'both overlay candidates have a safe failure, overriding remembered success'
    Assert (-not (Get-TransportBest $failedRows -Remembered)) 'failed construction never selected from memory'
    for($i=0;$i -lt $brokenPaths.Candidates.Count;$i++){Assert ($brokenPaths.Candidates[$i].port -eq 26000+$i) 'probe ports remain contiguous after a skipped candidate'}
    $selector=(New-TransportConfig $broken $brokenPaths 'fixture' 'vless-relay-relay').outbounds|Where-Object {$_.tag -eq 'active'}
    Assert (@($selector.outbounds|Where-Object {$_ -in $badTags}).Count -eq 0) 'generated selector has no failed dependencies'
    $log=[IO.File]::ReadAllText((Join-Path $work 'logs/transport.log'))
    Assert ($log.Contains('reason=hop-host-key-missing') -and -not $log.Contains('hop.example.invalid') -and -not $log.Contains($hopKey)) 'candidate failure journal contains no endpoint or private path'
    # Independent direct SSH pin, catalog hop, relay and entry failures all leave the working channel alive.
    $broken.Profile.knownHostsPath=Join-Path $work 'no-server-known'
    $broken.Transport.PSObject.Properties.Remove('serverRoute')
    $broken.Transport.hops=@([pscustomobject]@{name='bad-hop';ssh='-invalid';knownHostsPath=(Join-Path $work 'missing-hop-known')})
    $broken.Transport.relays+=@([pscustomobject]@{name='bad-relay';host='secret.invalid';port=0})
    $broken.Transport.entries=@([pscustomobject]@{name='missing-entry';ssh='missing';kinds=@('hy2')})
    $candidateProfile=Join-Path $work 'candidate-profile.json';$candidateChannel=Join-Path $work 'candidate-channel.json'
    Write-TransportJson $candidateProfile $broken.Profile;Write-TransportJson $candidateChannel $broken.Channel
    $broken.Transport|Add-Member -Force profilePath $candidateProfile;$broken.Transport|Add-Member -Force channelPath $candidateChannel
    Write-TransportJson (Join-Path $work 'config.json') @{schema=1;transport=$broken.Transport}
    $loadedBroken=Read-TransportSettings $work
    $brokenPaths=Get-TransportCandidates $loadedBroken $work
    Assert ('vless-relay-relay' -in @($brokenPaths.Candidates.tag)) 'runtime validation isolates invalid relay/hop settings too'
    foreach($tag in @('singbox-ssh-direct','vless-sshhop-bad-hop','openssh-jump-bad-hop','vless-relay-bad-relay','hy2-missing-entry')){
        Assert ($tag -notin @($brokenPaths.Candidates.tag) -and ($brokenPaths.AllCandidates|Where-Object {$_.tag -eq $tag}).buildFailed) ('isolated build failure '+$tag)
    }
    Assert ('vless-relay-relay' -in @($brokenPaths.Candidates.tag)) 'valid relay survives all independent build errors'
    function Invoke-TransportText($Exe,$Arguments){throw 'secret.invalid token=do-not-print'}
    try{Sync-TransportEntryCache $broken $work}finally{Set-Item function:Invoke-TransportText $realText}
    Assert (-not [IO.File]::ReadAllText((Join-Path $work 'logs/transport.log')).Contains('do-not-print')) 'cache fetch failure is isolated and sanitized before candidate construction'
    $broken.Channel.outbounds=@();$broken.Transport.relays=@();$broken.Transport.hops=@();$broken.Transport.entries=@();$broken.Options.openSsh=$false
    $fatal=$null;try{Get-TransportCandidates $broken $work|Out-Null}catch{$fatal=$_.Exception.Message}
    Assert ($fatal -eq 'Нет доступных кандидатов транспорта') 'no remaining candidates is fatal'
    $expected=@('vless-direct','singbox-ssh-direct','vless-relay-relay','vless-sshhop-jump','hy2-edge','hy2obfs-edge','tuic-edge','trojan-edge','reality-edge','shadowtls-edge','ws-direct-edge','ws-cdn-edge','openssh-direct','openssh-jump-jump')
    Assert ($paths.Candidates.Count -eq $expected.Count) 'число кандидатов'
    foreach($tag in $expected){Assert ($tag -in @($paths.Candidates|ForEach-Object {$_.tag})) ('путь '+$tag)}
    $webRaw=ConvertFrom-Json '{"happier":{"localWeb":{"enabled":true,"port":47831,"serverPort":47832}}}'
    Assert ((Get-TransportLocalWeb $webRaw).port -eq 47831) 'manual localWeb settings accepted'
    $webRaw|Add-Member profile (ConvertFrom-Json '{"happier":{"localWeb":{"enabled":false,"port":1024,"serverPort":65535}}}')
    Assert (-not (Get-TransportLocalWeb $webRaw).enabled) 'disabled profile takes priority over manual settings'
    Assert (-not (Get-TransportLocalWeb ([pscustomobject]@{})).enabled) 'missing localWeb stays disabled'
    foreach($invalid in @('null','[]','true','{"enabled":"true","port":47831,"serverPort":47832}','{"enabled":true,"port":1023,"serverPort":47832}','{"enabled":true,"port":47831,"serverPort":65536}','{"enabled":true,"port":47831.5,"serverPort":47832}','{"enabled":true,"port":"47831","serverPort":47832}','{"enabled":true,"port":47831}','{"enabled":true,"port":47831,"serverPort":47832,"extra":true}')){
        $rejected=$false;try{Get-TransportLocalWeb (ConvertFrom-Json ('{"happier":{"localWeb":'+$invalid+'}}'))|Out-Null}catch{$rejected=$true}
        Assert $rejected 'invalid manual localWeb rejected'
    }
    $revisionRoot=Join-Path $work 'web-revision';[void][IO.Directory]::CreateDirectory($revisionRoot)
    $revisionFile=Join-Path $revisionRoot 'config.json'
    Write-TransportJson $revisionFile @{transport=@{}}
    $noWebRevision=Get-TransportRevision $revisionRoot
    Write-TransportJson $revisionFile $webRaw
    $offRevision=Get-TransportRevision $revisionRoot
    $webRaw.profile.happier.localWeb.enabled=$true;Write-TransportJson $revisionFile $webRaw
    $onRevision=Get-TransportRevision $revisionRoot
    Assert ($noWebRevision -ne $offRevision -and $offRevision -ne $onRevision) 'localWeb changes transport revision for hot reload'
    $webRaw.profile.happier.localWeb.port=47833;Write-TransportJson $revisionFile $webRaw
    Assert ((Get-TransportRevision $revisionRoot) -ne $onRevision) 'fixed port change triggers reload'
    # Each candidate carries the same fixed browser origin through active (including OpenSSH -D).
    $localSettings=Copy-TransportObject $settings
    $localSettings|Add-Member LocalWeb ([pscustomobject]@{enabled=$true;available=$true;port=47831;serverPort=47832;conflict=$null})
    foreach($candidate in $paths.Candidates){
        $webConfig=New-TransportConfig $localSettings $paths 'test-secret' $candidate.tag
        $web=@($webConfig.inbounds|Where-Object {$_.tag -eq 'happier-web'})
        Assert ($web.Count -eq 1 -and $web[0].listen -eq '127.0.0.1' -and $web[0].listen_port -eq 47831 -and $web[0].override_address -eq '127.0.0.1' -and $web[0].override_port -eq 47832 -and $web[0].network -eq 'tcp') ('fixed Happier loopback: '+$candidate.tag)
        Assert (@($webConfig.route.rules|Where-Object {$_.inbound -contains 'happier-web' -and $_.outbound -eq 'active'}).Count -eq 1 -and ($webConfig.outbounds|Where-Object {$_.tag -eq 'active'}).default -eq $candidate.tag) ('Happier uses active: '+$candidate.tag)
        if($candidate.tag -like 'openssh-*'){
            $tunnel=$paths.Tunnels|Where-Object {$_.tag -eq $candidate.tag}
            Assert ($tunnel.arguments -contains '-D' -and ($webConfig.outbounds|Where-Object {$_.tag -eq $candidate.tag}).type -eq 'socks') ('OpenSSH SOCKS carries Happier: '+$candidate.tag)
        }
        if($SingBox){$file=Join-Path $work 'happier-check.json';Write-TransportJson $file $webConfig;Test-TransportConfigFile $SingBox $file}
    }
    $localSettings.LocalWeb.available=$false
    $webConfig=New-TransportConfig $localSettings $paths 'test-secret' 'trojan-edge'
    Assert (@($webConfig.inbounds|Where-Object {$_.tag -eq 'happier-web'}).Count -eq 0 -and @($webConfig.inbounds|Where-Object {$_.tag -in @('ssh','sync')}).Count -eq 2) 'occupied Happier port skips only that input'
    Assert (@((New-TransportConfig $settings $paths 'test-secret' 'trojan-edge').inbounds|Where-Object {$_.tag -eq 'happier-web'}).Count -eq 0) 'old settings have no Happier listener'
    $localSettings.LocalWeb.available=$true;$localSettings.LocalWeb.enabled=$false
    Assert (@((New-TransportConfig $localSettings $paths 'test-secret' 'trojan-edge').inbounds|Where-Object {$_.tag -eq 'happier-web'}).Count -eq 0) 'disabled localWeb has no listener'
    $cfg=New-TransportConfig $settings $paths 'test-secret' 'trojan-edge'
    Assert ($cfg.inbounds.Count -eq $expected.Count+4) 'рабочие и проверочные входы'
    Assert ($cfg.inbounds[0].listen_port -eq 2222 -and $cfg.inbounds[1].listen_port -eq 22001) 'рабочие порты'
    Assert ($cfg.inbounds[1].override_port -eq 23456) 'порт синхронизации взят из канала'
    foreach($inbound in $cfg.inbounds|Where-Object {$_.tag -notin @('lan-in','vpn-in')}){Assert ($inbound.listen -eq '127.0.0.1' -and $inbound.type -eq 'direct' -and $inbound.override_address -eq '127.0.0.1') 'только loopback direct'}
    for($i=0;$i -lt $expected.Count;$i++){
        $c=$paths.Candidates[$i];$in=$cfg.inbounds|Where-Object {$_.tag -eq ('probe-'+$c.tag)}
        $rule=$cfg.route.rules|Where-Object {$_.inbound[0] -eq $in.tag}
        Assert ($in.listen_port -eq 26000+$i -and $in.override_port -eq 22 -and $rule.outbound -eq $c.tag) 'проверочный вход ведёт в свой путь'
    }
    Assert (@($cfg.route.rules|Where-Object {$_.outbound -eq 'active'}).Count -eq 3) 'рабочие входы в selector'
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
    # Helper credentials persist independently of channel/API credentials and are never in public status.
    $helper=Get-TransportHelperSecret $work;$helperFile=Join-Path $work 'state/helper-socks.json'
    $helperText=[IO.File]::ReadAllText($helperFile);$helperTime=[IO.File]::GetLastWriteTimeUtc($helperFile)
    $again=Get-TransportHelperSecret $work
    Assert ($helper.user -ceq 'ra-helper' -and [Convert]::FromBase64String($helper.password).Length -eq 32) 'секрет помощника: 32 случайных байта base64'
    Assert ($again.password -ceq $helper.password -and [IO.File]::GetLastWriteTimeUtc($helperFile) -eq $helperTime) 'секрет создаётся один раз, чтение его не переписывает'
    foreach($invalid in @('{"user":"foreign","password":"bad"}','{"user":"ra-helper","password":"YQ=="}','not-json')){
        [IO.File]::WriteAllText($helperFile,$invalid);$rejected=$false
        try{Get-TransportHelperSecret $work|Out-Null}catch{$rejected=$_.Exception.Message -eq 'Неверный секрет помощника'}
        Assert ($rejected -and [IO.File]::ReadAllText($helperFile) -ceq $invalid) 'повреждённый секрет не заменяется молча'
    }
    [IO.File]::WriteAllText($helperFile,$helperText)
    if($env:OS -eq 'Windows_NT'){
        $acl=Get-Acl -LiteralPath $helperFile;$userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
        Assert ($acl.AreAccessRulesProtected -and $rules.Count -eq 2 -and @($rules|Where-Object {$_.IdentityReference.Value -notin @($userSid,'S-1-5-18') -or $_.AccessControlType -ne 'Allow'}).Count -eq 0) 'ACL секрета: только текущий пользователь и SYSTEM'
        Assert (@($rules|Where-Object {$_.IdentityReference.Value -eq 'S-1-5-18'}).Count -eq 1) 'SYSTEM читает секрет помощника'
    }else{
        $mode=(& stat -c '%a' -- $helperFile)|Out-String
        Assert ($LASTEXITCODE -eq 0 -and $mode.Trim() -eq '600') 'секрет закрыт mode 600 на Linux'
    }
    foreach($tag in @('lan-in','vpn-in')){
        $helperInput=@($cfg.inbounds|Where-Object {$_.tag -eq $tag})
        Assert ($helperInput.Count -eq 1 -and $helperInput[0].listen -eq '127.0.0.1' -and $helperInput[0].type -eq 'mixed' -and @($helperInput[0].users).Count -eq 1 -and $helperInput[0].users[0].username -ceq $helper.user -and $helperInput[0].users[0].password -ceq $helper.password) ('защищённый loopback '+$tag)
    }
    Assert (@($cfg.inbounds|Where-Object {$_.tag -eq 'lan-proxy'}).Count -eq 0) 'старый вход без пароля заменён'
    $emptyLanRules=@($cfg.route.rules|Where-Object {$_.inbound -contains 'lan-in'})
    Assert ($emptyLanRules.Count -eq 1 -and $emptyLanRules[0].action -eq 'reject') 'без сетей lan-in отклоняет всё'
    $lanRaw=ConvertFrom-Json '{"profile":{"lan":[{"name":"one","enabled":true,"testHost":"10.71.0.1","share":{"subnets":["10.71.0.0/24"],"domains":["*.example.org"],"dnsServers":["10.71.0.53"],"forwards":[{"name":"ssh","host":"10.99.0.2","port":22,"localPort":18222}]}},{"name":"two","enabled":true,"testHost":"172.22.0.1","share":{"subnets":["172.22.0.0/16"]}},{"name":"off","subnets":["192.168.77.0/24"],"share":{"enabled":false,"subnets":["192.168.78.0/24"]}}]}}'
    $lanFile=Join-Path $work 'helper-lan.json'
    [IO.File]::WriteAllText($lanFile,((ConvertTo-Json $lanRaw -Depth 20).Replace("`r",'').Replace("`n","`r`n")))
    $helperSettings=Copy-TransportObject $settings;$helperSettings|Add-Member Lan (Get-TransportLan (Read-TransportJson $lanFile))
    $helperConfig=New-TransportConfig $helperSettings $paths 'test-secret' 'vless-direct'
    $lanRules=@($helperConfig.route.rules|Where-Object {$_.inbound -contains 'lan-in'})
    Assert ($lanRules[-1].action -eq 'reject' -and @($lanRules|Where-Object {$_.action -eq 'route' -and ($_.ip_cidr -join ',') -eq '10.71.0.0/24,172.22.0.0/16'}).Count -eq 1) 'lan-in: числовые адреса включённых сетей и завершающий reject'
    Assert (@($lanRules|Where-Object {$_.port}).Count -eq 0 -and '192.168.77.0/24' -notin @($helperSettings.Lan.subnets) -and '192.168.78.0/24' -notin @($helperSettings.Lan.subnets)) 'выключенные сети и forwards не расширяют lan-in';Test-LanIngress $work
    $vpnRules=@($helperConfig.route.rules|Where-Object {$_.inbound -contains 'vpn-in'})
    Assert ($vpnRules.Count -eq 1 -and $vpnRules[0].action -eq 'route' -and $vpnRules[0].outbound -eq 'active' -and -not $vpnRules[0].ip_cidr) 'vpn-in направляет всё в active'
    $legacyLan=Get-TransportLan (ConvertFrom-Json '{"profile":{"lan":[{"testHost":"10.72.0.1","share":{"subnets":["10.72.0.0/24"]}}]}}')
    Assert ($legacyLan.subnets[0] -eq '10.72.0.0/24') 'поддержан прежний share-only профиль'
    foreach($candidate in $paths.Candidates){
        $public=Get-TransportHelperStatus $settings $candidate.tag $paths.Outbounds
        Assert ($public.udp -eq (Test-TransportInternetPath $candidate.tag $paths.Outbounds)) ('helper.udp следует полному пути '+$candidate.tag)
    }
    $public=Get-TransportHelperStatus $settings 'singbox-ssh-direct' $paths.Outbounds
    Assert (-not $public.udp -and $public.lanInPort -eq 17880 -and $public.vpnInPort -eq 17881) 'helper: порты и udp=false для SSH'
    Assert (-not (Get-TransportHelperStatus $settings 'openssh-direct' $paths.Outbounds).udp -and -not (Get-TransportHelperStatus $settings 'vless-sshhop-jump' $paths.Outbounds).udp -and -not (Get-TransportHelperStatus $settings '' $paths.Outbounds).udp) 'SOCKS, SSH detour и отсутствие пути не обещают UDP'
    $publicFile=Join-Path $work 'status/helper-test.json';Write-TransportJson $publicFile @{helper=$public}
    $publicJson=[IO.File]::ReadAllText($publicFile)
    Assert (-not $publicJson.Contains($helper.password) -and -not $publicJson.Contains('password') -and @($public.PSObject.Properties).Count -eq 3) 'статус содержит только порты и UDP, без секрета'
    # Execute only the real publisher body, never the daemon/network lifecycle.
    $daemonAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Transport.Daemon.ps1'),[ref]$null,[ref]$null)
    $clockBody=$daemonAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DaemonTime'},$true).Body.GetScriptBlock()
    Assert ([Math]::Abs((& $clockBody)-[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -lt 1000) 'Unix-время демона независимо от локального часового пояса'
    $publisher=$daemonAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Publish-TransportStatus'},$true).Body.GetScriptBlock()
    & {
        param($root,$settings,$paths,$active,$publisher)
        # Parent-scope reads of Publish-TransportStatus: root, settings, paths, active,
        # rows, engine, network, confirmed, errorText, revision, exitCode, retryAt, pin,
        # verdict, decision, initialRound, reloadError, portConflict, stopping, metered,
        # daemonStarted, script:engineAttempted and script:checkingSince.
        # Match daemon initialization; only root/settings/paths/active/revision are fixture data.
        $rows=@();$engine=$null;$network=$null;$confirmed=$false;$errorText='Запуск';$revision='fixture';$exitCode=0;$retryAt=[DateTime]::MinValue;$pin=[pscustomobject]@{mode='auto';tag=$null}
        $verdict=$null;$decision=$null;$initialRound=$false;$reloadError=$null;$portConflict=$null;$stopping=$false;$metered=$null
        $daemonStarted=[DateTime]::Now
        try{$daemonStarted=(Get-Process -Id $PID).StartTime}catch{}
        $script:engineAttempted=$false;$script:checkingSince=$daemonStarted.ToUniversalTime()
        & $publisher
        $startupStatus=Read-TransportJson (Join-Path $root 'status/transport.json')
        Assert ($startupStatus.phase -eq 'checking' -and -not $startupStatus.ok -and $startupStatus.summary -ceq 'запуск модуля связи') 'до первой попытки запуска движка publisher сообщает checking, а не failed'
        Assert ((Convert-TransportUtc $startupStatus.checkingSince) -eq $daemonStarted.ToUniversalTime()) 'checkingSince начинается со времени запуска процесса демона'
        # Exercise the fallback that exposed the missing daemonStarted in this fixture.
        $script:checkingSince=$null
        & $publisher
        $startupStatus=Read-TransportJson (Join-Path $root 'status/transport.json')
        Assert ($startupStatus.phase -eq 'checking' -and -not $startupStatus.ok -and $startupStatus.summary -ceq 'запуск модуля связи' -and (Convert-TransportUtc $startupStatus.checkingSince) -eq $daemonStarted.ToUniversalTime()) 'publisher восстанавливает отсутствующий checkingSince из daemonStarted'
        $script:engineAttempted=$true;$errorText='fixture'
        & $publisher
        $failedStatus=Read-TransportJson (Join-Path $root 'status/transport.json')
        Assert ($failedStatus.phase -eq 'failed' -and -not $failedStatus.ok -and $failedStatus.summary -ceq 'нет связи: fixture') 'после неудачной попытки запуска движка publisher сохраняет failed и причину'
        $engine=@{Process=@{HasExited=$false}}
        $verdict=@{action='searching';localNet='down';reason=@{code='local-network-down';text='Нет интернета у вас (сеть), жду';since=0}}
        $decision=@{switches=@(@{at=0;from='a';to='b';why='path-stalled'})}
        & $publisher
    } $work $settings $paths 'singbox-ssh-direct' $publisher
    $daemonStatus=Read-TransportJson (Join-Path $work 'status/transport.json')
    $statusText=[IO.File]::ReadAllText((Join-Path $work 'status/transport.json'))
    Assert ($statusText -match '"since"\s*:\s*"1970-01-01T00:00:00.0000000Z"' -and $statusText -match '"at"\s*:\s*"1970-01-01T00:00:00.0000000Z"') 'reason/switches используют ISO UTC'
    Assert ($daemonStatus.phase -eq 'searching' -and -not $daemonStatus.ok -and $daemonStatus.localNet -eq 'down' -and $daemonStatus.summary -ceq 'нет связи: fixture') 'после попытки запуска publisher сохраняет поиск и локальную причину'
    Assert ($daemonStatus.helper.lanInPort -eq 17880 -and $daemonStatus.helper.vpnInPort -eq 17881 -and -not $daemonStatus.helper.udp -and -not ([IO.File]::ReadAllText((Join-Path $work 'status/transport.json'))).Contains($helper.password)) 'настоящий publisher пишет helper без пароля'
    foreach($external in $paths.Outbounds|Where-Object {-not $_.detour -and $_.type -ne 'socks'}){
        $actual=$bound.outbounds|Where-Object {$_.tag -eq $external.tag}
        Assert ($actual.bind_interface -eq 'Ethernet') ('bindPhysical: '+$external.type+' '+$external.tag)
    }
    Assert (@($bound.outbounds|Where-Object {$_.detour -and $_.bind_interface}).Count -eq 0) 'detour не получает bind_interface'
    foreach($portKey in @('lanProxyPort','vpnInPort')){
        $old=$options[$portKey]
        foreach($conflictPort in @(2222,22001,29090,26000,28000,17880,17881)){
            if($conflictPort -eq $old){continue}
            $options[$portKey]=$conflictPort;$rejected=$false
            try{New-TransportConfig $settings $paths 'test-secret' ''|Out-Null}catch{$rejected=$_.Exception.Message -eq 'Пересечение или неверный порт'}
            Assert $rejected ('пересечение порта помощника отклонено: '+$portKey+' '+$conflictPort)
        }
        $options[$portKey]=$old
    }
    # All preferred helper/channel ports deliberately collide, including fixed Happier.
    $portRoot=Join-Path $work 'helper-ports';[void][IO.Directory]::CreateDirectory($portRoot)
    $portTransport=[pscustomobject]@{channelFirst=$true;sshPort=26000;syncPort=26000;channelSocksPort=26000;apiPort=26000;probePortBase=26000;socksPortBase=26000;lanProxyPort=26000;vpnInPort=26000}
    $portOptions=Get-TransportPortDefaults
    $portProfile=Copy-TransportObject $p;$portProfile.arguments=@('-p','22220')
    $portProfileFile=Join-Path $portRoot 'profile.json';Write-TransportJson $portProfileFile $portProfile
    $portTransport|Add-Member profilePath $portProfileFile
    $portSettings=[pscustomobject]@{Options=$portOptions;Transport=$portTransport;Profile=$portProfile;Channel=$settings.Channel;Lan=(Copy-TransportObject $helperSettings.Lan);LocalWeb=[pscustomobject]@{enabled=$true;available=$true;port=26000;serverPort=47831;conflict=$null}}
    Write-TransportJson (Join-Path $portRoot 'config.json') @{transport=$portTransport}
    $portSettings=Resolve-TransportPorts $portRoot $portSettings 2 2
    $effective=Get-TransportEffectivePorts $portRoot;$saved=Read-TransportJson (Join-Path $portRoot 'state/transport-ports.json')
    Assert ($saved.defaults.vpnInPort -eq 17881 -and $saved.configured.vpnInPort -eq 26000 -and $effective.vpnInPort -eq $portOptions.vpnInPort -and $effective.vpnInPort -ne 26000 -and $effective.lanProxyPort -ne $effective.vpnInPort) 'vpnInPort выбран, сохранён и прочитан через effective'
    $portPaths=[pscustomobject]@{Candidates=@([pscustomobject]@{tag='one';port=$portOptions.probePortBase},[pscustomobject]@{tag='two';port=($portOptions.probePortBase+1)});Outbounds=@(@{type='socks';tag='one';server='127.0.0.1';server_port=$portOptions.socksPortBase},@{type='socks';tag='two';server='127.0.0.1';server_port=($portOptions.socksPortBase+1)})}
    $portConfig=New-TransportConfig $portSettings $portPaths 'test-secret' 'one'
    $allPorts=@(@($portConfig.inbounds|Where-Object {$_.listen -eq '127.0.0.1'}|ForEach-Object {$_.listen_port})+@($portOptions.apiPort)+@($portPaths.Outbounds|ForEach-Object {$_.server_port}))
    Assert (@($allPorts|Select-Object -Unique).Count -eq $allPorts.Count) 'входы помощника не пересекаются с рабочими входами, пробами, SOCKS, API и Happier'
    $portPublic=Get-TransportHelperStatus $portSettings 'one' $portPaths.Outbounds
    Assert ($portPublic.lanInPort -eq $effective.lanProxyPort -and $portPublic.vpnInPort -eq $effective.vpnInPort -and -not $portPublic.udp) 'helper публикует эффективные порты'
    if($SingBox){
        $file=Join-Path $work 'helper-check.json';Write-TransportJson $file $helperConfig;Test-TransportConfigFile $SingBox $file
        $file=Join-Path $work 'helper-ports-check.json';Write-TransportJson $file $portConfig;Test-TransportConfigFile $SingBox $file
    }
    $rows=@([pscustomobject]@{tag='a';state='ok';kbps=12;checkedAt='2026-01-01T00:00:00Z'},[pscustomobject]@{tag='b';state='ok';kbps=80;checkedAt='2026-01-01T00:00:00Z'},[pscustomobject]@{tag='c';state='frozen';kbps=900;checkedAt=$null})
    Assert ((Get-TransportBest $rows).tag -eq 'a') 'скорость не создаёт рейтинг путей'
    Assert ((Get-TransportBest $rows @('a')).tag -eq 'a') 'ограничение top набора'
    $preferred=Copy-TransportObject $rows
    $preferred[0]|Add-Member priority (Get-TransportPriority 'vless-direct' @('vless','vless-direct'))
    $preferred[1]|Add-Member priority 999
    Assert ($preferred[0].priority -eq 0 -and (Get-TransportPriority 'openssh-direct' @('vless')) -eq 999) 'первый подходящий префикс и fallback'
    Assert ((Get-TransportBest $preferred).tag -eq 'a') 'priority раньше скорости'
    $preferred[0].state='remembered'
    Assert ((Get-TransportBest $preferred -Remembered).tag -eq 'a') 'ok и remembered в общей группе перед priority'
    $ties=@([pscustomobject]@{tag='a';state='ok';kbps=900;latencyMs=20},[pscustomobject]@{tag='b';state='ok';kbps=1;latencyMs=10})
    Assert ((Get-TransportBest $ties).tag -eq 'b') 'задержка выбирает путь независимо от скорости'
    Assert ($cfg.log.level -eq 'warn') 'события ошибок доступны при уровне warn'
    $s=New-TransportProbeState 65536 5 45
    [void](Update-TransportProbeState $s 16384 1);[void](Update-TransportProbeState $s 65536 2)
    Assert ($s.state -eq 'ok' -and $s.kbps -eq 32) 'жив и эффективная скорость от начала пробы'
    $s=New-TransportProbeState 65536 5 45;[void](Update-TransportProbeState $s 16384 1);[void](Update-TransportProbeState $s 16384 6)
    Assert ($s.state -eq 'frozen') 'первые 16К и остановка'
    $s=New-TransportProbeState 65536 5 45;[void](Update-TransportProbeState $s 16384 1);[void](Update-TransportProbeState $s 65536 8)
    Assert ($s.state -eq 'ok' -and $s.maxGapMs -eq 7000) 'полная проба успешна даже после stall; пауза сохранена'
    $s=New-TransportProbeState 65536 5 45;[void](Update-TransportProbeState $s 16384 1);[void](Update-TransportProbeState $s 32768 8)
    Assert ($s.state -eq 'frozen' -and $s.maxGapMs -eq 7000) 'неполная проба после stall остаётся frozen'
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
        Assert ($net.available -and $net.interface -eq 'Ethernet' -and $net.ifIndex -eq 3 -and $net.id -eq $n1) 'физический шлюз: исключение VPN и сумма метрик'
    }finally{
        foreach($name in $mockNames){Remove-Item ('function:'+$name);if($priorFunctions.ContainsKey($name)){Set-Item ('function:'+$name) $priorFunctions[$name]}}
    }
    # Happ: happ-xray (виртуальный, default метрика 0) и Wi-Fi (default метрика 0), записи соседа шлюза нет.
    $happState=@{ifaceMetric=@{5=0;7=25};wifi='Wi-Fi';ip='192.168.43.20';gw='192.168.43.1'}
    try{
        function Get-NetRoute {param($DestinationPrefix,$ErrorAction)
            @([pscustomobject]@{InterfaceIndex=5;NextHop='172.19.0.2';RouteMetric=0},[pscustomobject]@{InterfaceIndex=7;NextHop=$happState.gw;RouteMetric=0})
        }
        function Get-NetIPInterface {param($InterfaceIndex,$AddressFamily,$ErrorAction) [pscustomobject]@{InterfaceMetric=$happState.ifaceMetric[[int]$InterfaceIndex]}}
        function Get-NetConnectionProfile {param($InterfaceIndex,$ErrorAction) throw 'нет профиля'}
        function Get-NetNeighbor {param($InterfaceIndex,$IPAddress,$ErrorAction) throw 'нет записи ARP'}
        function Get-NetIPAddress {param($InterfaceIndex,$AddressFamily,$ErrorAction) [pscustomobject]@{AddressState='Preferred';IPAddress=$happState.ip}}
        function Get-NetAdapter {param([switch]$Physical,$ErrorAction)
            @([pscustomobject]@{ifIndex=5;Name='happ-xray';InterfaceDescription='Wintun Userspace Tunnel';Status='Up'},[pscustomobject]@{ifIndex=7;Name=$happState.wifi;InterfaceDescription='Wireless';Status='Up';HardwareInterface=$true})
        }
        $happNet=Get-TransportNetwork
        Assert ($happNet.available -and $happNet.interface -eq 'Wi-Fi' -and $happNet.ip -eq '192.168.43.20') 'Happ: default happ-xray и Wi-Fi, сосед отсутствует -> available на Wi-Fi'
        Assert ($happNet.id -and $happNet.id.Length -eq 64) 'Happ: id без MAC считается по ifIndex+профиль+NextHop'
        # Сосед в Stale: сеть остаётся доступной, id берётся из MAC.
        function Get-NetNeighbor {param($InterfaceIndex,$IPAddress,$ErrorAction) [pscustomobject]@{State='Stale';LinkLayerAddress='AA:BB:CC:DD:EE:01'}}
        Assert ((Get-TransportNetwork).available) 'сосед Stale не делает сеть недоступной'
        # Смена default route Wi-Fi -> Ethernet: изменение распознаётся, движок пересоздаётся с новым интерфейсом.
        $before=Get-TransportNetwork
        function Get-NetRoute {param($DestinationPrefix,$ErrorAction)
            @([pscustomobject]@{InterfaceIndex=5;NextHop='172.19.0.2';RouteMetric=0},[pscustomobject]@{InterfaceIndex=9;NextHop='10.0.0.1';RouteMetric=0})
        }
        $happState.ifaceMetric[9]=10;$happState.ip='10.0.0.7'
        function Get-NetAdapter {param([switch]$Physical,$ErrorAction)
            @([pscustomobject]@{ifIndex=5;Name='happ-xray';InterfaceDescription='Wintun Userspace Tunnel';Status='Up'},[pscustomobject]@{ifIndex=9;Name='Ethernet';InterfaceDescription='Ethernet';Status='Up';HardwareInterface=$true})
        }
        $after=Get-TransportNetwork
        Assert ($after.available -and $after.interface -eq 'Ethernet') 'после смены default выбран Ethernet'
        Assert (Test-TransportNetworkChanged $before $after) 'смена default route Wi-Fi -> Ethernet распознана как смена сети'
        Assert (-not (Test-TransportNetworkChanged $after $after)) 'без изменений сеть не меняется'
    }finally{
        foreach($name in $mockNames){Remove-Item ('function:'+$name) -ErrorAction SilentlyContinue;if($priorFunctions.ContainsKey($name)){Set-Item ('function:'+$name) $priorFunctions[$name]}}
    }
    # Паузы 3/5/10/20/30 растут и ограничены; после ready счётчик обнуляется (сброс в демоне, паузы от первого шага).
    Assert ((@(1,2,3,4,5,6,9)|ForEach-Object {Get-TransportStartPause $_}) -join ',' -eq '3,5,10,20,30,30,30') 'паузы 3/5/10/20/30'
    Assert ((Get-TransportStartPause 0) -eq 3) 'после сброса снова 3 с'
    # error=: текст исключения в одну строку, <=300 символов, UUID/ключи/пароль замаскированы.
    $secretSettings=[pscustomobject]@{password='hunter2'}
    try{throw ("сбой uuid 11111111-2222-3333-4444-555555555555 token=abcdef pass hunter2 key "+('A'*80)+"`r`nвторая строка "+('я'*400))}catch{$startError=Format-TransportStartError $_ $secretSettings}
    Assert ($startError.Length -le 300 -and $startError -notmatch "[\r\n]") 'error= одна строка до 300 символов'
    Assert ($startError.Contains('сбой') -and $startError.Contains('<uuid>') -and -not $startError.Contains('11111111') -and -not $startError.Contains('hunter2') -and -not $startError.Contains('abcdef') -and -not $startError.Contains('AAAAAAAAAAAAAAAAAAAA')) 'error= маскирует uuid, пароль, токен и ключ'
    $diag=New-TransportDiagnostic $null 'sing-box' 'engine-start-failed';$diag|Add-Member -Force error 'Физический интерфейс недоступен'
    Assert ((Format-TransportDiagnostic $diag).EndsWith(' error=Физический интерфейс недоступен')) 'error= попадает в строку журнала'
    # Резервный режим bind=none: только после 3 подряд неудач и vpn off; снимается при появлении интерфейса.
    $none=[pscustomobject]@{available=$false;interface=$null}
    $st=@{failures=0;none=$false}
    $m1=(Resolve-TransportBind $st $none $true).mode;$m2=(Resolve-TransportBind $st $none $true).mode;$m3=(Resolve-TransportBind $st $none $true).mode
    Assert ($m1 -eq 'fail' -and $m2 -eq 'fail' -and $m3 -eq 'none') 'bind=none на 3-й неудаче при vpn off'
    $st=@{failures=0;none=$false}
    foreach($i in 1..6){$r=Resolve-TransportBind $st $none $false}
    Assert ($r.mode -eq 'fail' -and -not $st.none) 'vpn не off: резервный режим запрещён'
    $st=@{failures=0;none=$false};[void](Resolve-TransportBind $st $none $true);[void](Resolve-TransportBind $st $none $true)
    $r=Resolve-TransportBind $st $none $true
    Assert ($r.mode -eq 'none' -and $r.event -eq 'bind=none reason=no-physical-interface' -and $st.none) 'вход в bind=none пишет строку журнала'
    Assert ((Resolve-TransportBind $st $none $true).event -eq $null) 'повтор в bind=none не дублирует строку'
    $r=Resolve-TransportBind $st ([pscustomobject]@{available=$true;interface='Wi-Fi'}) $true
    Assert ($r.mode -eq 'physical' -and $r.event -eq 'bind=physical restored' -and -not $st.none -and $st.failures -eq 0) 'интерфейс появился: bind=physical restored'
    $st=@{failures=0;none=$false};[void](Resolve-TransportBind $st $none $true);[void](Resolve-TransportBind $st ([pscustomobject]@{interface='Wi-Fi'}) $true)
    Assert ((Resolve-TransportBind $st $none $true).mode -eq 'fail') 'найденный интерфейс сбрасывает серию неудач'
    $voff=Join-Path $work 'vpnoff';[void][IO.Directory]::CreateDirectory((Join-Path $voff 'status'))
    Assert (-not (Test-TransportVpnOff $voff)) 'нет vpn.json: резервный режим запрещён'
    Write-TransportJson (Join-Path $voff 'status/vpn.json') @{state='on'};Assert (-not (Test-TransportVpnOff $voff)) 'vpn on'
    Write-TransportJson (Join-Path $voff 'status/vpn.json') @{state='off'};Assert (Test-TransportVpnOff $voff) 'vpn off'
    Write-TransportLog $voff 'bind-mode' ([pscustomobject]@{message='bind=none reason=no-physical-interface'})
    Assert ((Get-Content -Raw (Join-Path $voff 'logs/transport.log')) -match 'bind-mode bind=none reason=no-physical-interface') 'журнал: bind=none reason=...'
    $rows[0]|Add-Member -Force latencyMs 20;$rows[1]|Add-Member -Force latencyMs 10
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
        Assert ($defaults.Options.bindPhysical -and $defaults.Options.apiPort -eq 29090) 'значения запуска по умолчанию'
        Assert ($defaults.Options.switchStallSeconds -eq 8 -and $defaults.Options.switchStallConns -eq 2) 'пороги подозрения на зависание по умолчанию'
        Assert (-not $defaults.Options.ContainsKey('rankProbeBytes') -and -not $defaults.Options.ContainsKey('activeIntervalSec')) 'нет планировщика и рейтинга в опциях'
        $custom=Read-TransportJson (Join-Path $work 'config.json');$custom.transport|Add-Member switch ([pscustomobject]@{stallSeconds=11;stallConns=3})
        Write-TransportJson (Join-Path $work 'config.json') $custom
        $configured=Read-TransportSettings $work
        Assert ($configured.Options.switchStallSeconds -eq 11 -and $configured.Options.switchStallConns -eq 3) 'настройки transport.switch читаются'
        foreach($invalid in @(0,-1,1.5,$true,'8',3601)){
            $custom.transport.switch.stallSeconds=$invalid;Write-TransportJson (Join-Path $work 'config.json') $custom
            $rejected=$false;try{Read-TransportSettings $work|Out-Null}catch{$rejected=$true};Assert $rejected 'неверный stallSeconds отклонён'
        }
        $custom.transport.switch.stallSeconds=8
        foreach($invalid in @(0,-1,1.5,$true,'2',1025)){
            $custom.transport.switch.stallConns=$invalid;Write-TransportJson (Join-Path $work 'config.json') $custom
            $rejected=$false;try{Read-TransportSettings $work|Out-Null}catch{$rejected=$true};Assert $rejected 'неверный stallConns отклонён'
        }
        # Retained schema keys are accepted but never become runtime scheduling options.
        foreach($key in @('activeProbeBytes','rankProbeBytes','activeIntervalSec','meteredActiveIntervalSec','allLivenessIntervalSec','meteredAllLivenessIntervalSec','rankIntervalSec','rankConcurrency','topOnMetered','switchFactor')){
            $custom.transport|Add-Member -Force $key 'ignored-invalid-old-value'
        }
        $custom.transport.PSObject.Properties.Remove('switch');Write-TransportJson (Join-Path $work 'config.json') $custom
        $legacy=Read-TransportSettings $work
        Assert (-not $legacy.Options.ContainsKey('activeProbeBytes') -and -not $legacy.Options.ContainsKey('switchFactor') -and $legacy.Options.switchStallConns -eq 2) 'старые ключи молча игнорируются'
        $schema=Read-TransportJson (Join-Path $PSScriptRoot 'config.schema.json')
        foreach($key in @('activeProbeBytes','rankProbeBytes','activeIntervalSec','meteredActiveIntervalSec','allLivenessIntervalSec','meteredAllLivenessIntervalSec','rankIntervalSec','rankConcurrency','topOnMetered','switchFactor')){
            Assert ($schema.properties.$key.deprecated -eq $true -and $schema.properties.$key.description -eq 'не используется: переключение по событиям') ('схема сохраняет устаревший '+$key)
        }
        $personalConfig=Read-TransportJson (Join-Path $work 'config.json')
        $personalConfig|Add-Member wizard ([pscustomobject]@{serverRoute=$personal})
        Write-TransportJson (Join-Path $work 'config.json') $personalConfig
        $restored=Read-TransportSettings $work
        Assert ($restored.Transport.serverRoute.used -eq 'hop' -and $restored.Transport.serverRoute.hop.keyFile -eq $hopKey) 'runtime restores old wizard route as local overlay'
        Assert (-not (Read-TransportJson (Join-Path $work 'config.json')).transport.serverRoute) 'loading old route does not modify persisted settings'
        $personalConfig.transport|Add-Member probeTimeoutSec 12
        Write-TransportJson (Join-Path $work 'config.json') $personalConfig
        Assert ((Read-TransportSettings $work).Options.probeTimeoutSec -eq 12) 'bootstrap probe timeout is valid'
        $revision=Get-TransportRevision $work
        Assert ((Get-TransportRevision ($work+'/./')) -ceq $revision) 'revision ignores Home spelling and trailing slash'
        if($env:OS -eq 'Windows_NT'){
            Assert ((Get-TransportRevision $work.ToUpperInvariant().Replace('\','/')) -ceq $revision) 'Windows revision ignores Home case and separators'
        }
        $personalConfig|Add-Member account ([pscustomobject]@{enabled=$true})
        Write-TransportJson (Join-Path $work 'config.json') $personalConfig
        Assert ((Get-TransportRevision $work) -ceq $revision) 'unrelated C# section writes do not invalidate transport revision'
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
    # Snapshot с уже полученными байтами и большой паузой: реальные Receive-TransportProbe правила.
    $freq=[long][Diagnostics.Stopwatch]::Frequency
    $gapSink=[pscustomobject]@{Started=([Diagnostics.Stopwatch]::GetTimestamp()-10*$freq);bytes=65536;freq=$freq}
    $gapSink|Add-Member ScriptMethod Snapshot {[long[]]@($this.bytes,($this.Started+$this.freq),($this.Started+8*$this.freq),16384,(7*$this.freq))}
    $gapProbe=[pscustomobject]@{sink=$gapSink;copy=[Threading.Tasks.Task]::FromResult(0);state=(New-TransportProbeState 65536 5 45)}
    Assert ((Receive-TransportProbe $gapProbe) -and $gapProbe.state.state -eq 'ok' -and $gapProbe.state.maxGapMs -eq 7000 -and $gapProbe.state.latencyMs -eq 1000) 'полная проба с паузой успешна; задержка и пауза измерены'
    $gapSink.bytes=32768;$gapProbe.state=New-TransportProbeState 65536 5 45
    Assert ((Receive-TransportProbe $gapProbe) -and $gapProbe.state.state -eq 'frozen') 'неполный snapshot с паузой frozen'
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
    $cs=[pscustomobject]@{Root=$work;Options=$options;Transport=$ct;Profile=$p;Channel=(Copy-TransportObject $channel)}
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
    # Lifecycle now belongs to the elevated NativeJob: task registration is absent.
    Assert (-not (Test-Path function:Register-VpnRollbackTask)) 'нет 5-минутной задачи отката'
    $vpnSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Vpn.Tun.ps1'))
    Assert ($vpnSource -notmatch 'Register-ScheduledTask|Start-ScheduledTask|AddMinutes\(5\)') 'новые VPN не создают задачи'
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
        $source=[IO.File]::ReadAllBytes($scriptFile.FullName);$bom=($source.Length -ge 3 -and $source[0] -eq 239 -and $source[1] -eq 187 -and $source[2] -eq 191)
        Assert ($bom -or [Text.Encoding]::UTF8.GetString($source) -notmatch '[^\x00-\x7F]') ('UTF-8 BOM для Unicode либо чистый ASCII '+$scriptFile.Name)
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
