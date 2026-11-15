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
    $rank=@(Get-TransportRankTags $failedRows $brokenPaths.Candidates @{topOnMetered=100} $true)
    Assert (@($rank|Where-Object {$_ -in $badTags}).Count -eq 0 -and $rank.Count -eq $brokenPaths.Candidates.Count) 'failed candidates do not consume metered ranking slots'
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
    Assert (@(Get-TransportRankTags $rows @($rows|ForEach-Object {[pscustomobject]@{tag=$_.tag}}) $rankOptions $true)[0] -eq 'b') 'на лимитной сети лучший из памяти'
    Assert (@(Get-TransportRankTags $rows @($rows|ForEach-Object {[pscustomobject]@{tag=$_.tag}}) $rankOptions $null).Count -eq 1) 'неизвестная стоимость экономит трафик'
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
    Assert ($conf.conflict -and $conf.items.Count -eq 5) 'инвентаризация соседних VPN: адаптеры и full-tunnel маршруты'
    Assert (@($conf.items|Where-Object {$_.name -eq 'RemoteAgents-TUN'}).Count -eq 0) 'наш адаптер не попадает в инвентаризацию'
    Assert ((Get-VpnCoexistenceWarning $conf) -eq 'рядом работает: OpenVPN, OtherVPN, Tailscale') 'OpenVPN и Tailscale видны в предупреждении'
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
    $teredo=[pscustomobject]@{Processes=@();Adapters=@([pscustomobject]@{ifIndex=18;Name='Teredo Tunneling Pseudo-Interface';Status='Up';HardwareInterface=$false;Virtual=$true;InterfaceDescription='Teredo Tunneling Pseudo-Interface'});Routes=@([pscustomobject]@{DestinationPrefix='::/0';InterfaceIndex=18;NextHop='::';InterfaceAlias='Teredo Tunneling Pseudo-Interface'})}
    Assert (-not (Find-VpnConflicts $teredo).conflict) 'встроенный Teredo с ::/0 — не чужой VPN'
    $teredo.Adapters=@();Assert (-not (Find-VpnConflicts $teredo).conflict) 'скрытый Teredo без адаптера в снимке — не чужой VPN'
    foreach($name in @('ISATAP','6to4','IP-HTTPS')){
        $transition=[pscustomobject]@{Processes=@();Adapters=@([pscustomobject]@{ifIndex=18;Name=$name;Status='Up';HardwareInterface=$false;Virtual=$true;InterfaceDescription=$name});Routes=@([pscustomobject]@{DestinationPrefix='::/0';InterfaceIndex=18;NextHop='::';InterfaceAlias=$name})}
        Assert (-not (Find-VpnConflicts $transition).conflict) ($name+' не является соседним VPN')
    }
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
            Assert (($tun.inbounds[0].route_address -join ',') -eq '0.0.0.0/2,64.0.0.0/2,128.0.0.0/2,192.0.0.0/2,::/2,4000::/2,8000::/2,c000::/2') 'охват интернета задан четвертями /2, а не /1: длиннее чужого split-default'
            Assert (@($exclusions|Where-Object {$_ -notin $tun.inbounds[0].route_exclude_address}).Count -eq 0) 'охват /2 сохраняет все LAN/hop/server исключения'
            Assert (@($tun.outbounds|Where-Object {$_.type -in @('ssh','socks')}).Count -eq 0 -and $tun.route.final -eq 'vpn-active') 'TUN без SSH и direct fallback'
            Assert (($tun.route.rules[0].override_address -eq $settings.Profile.serverAddress) -and $tun.route.rules[0].override_port -eq (Get-TransportServerPort $settings.Profile)) 'служебная проба идёт до SSH сервера через TUN'
            if($SingBox){$file=Join-Path $work 'tun-check.json';Write-TransportJson $file $tun;Test-TransportConfigFile $SingBox $file}
        }else{
            $bad=$false;try{New-VpnTunConfig $settings $paths $candidate.tag $exclusions 'Ethernet'|Out-Null}catch{$bad=$true};Assert $bad ('SSH запрещён в TUN '+$candidate.tag)
        }
    }
    Assert ($tunConfigs.Count -eq 10) 'TUN check для всех 10 интернет-путей'
    # Модель только для теста: выбор маршрута Windows (самый длинный префикс, затем метрика) и построение маршрутов
    # sing-tun (route_address минус route_exclude_address, остаток склеивается в минимальные префиксы, как IPSet).
    function ConvertTo-TestBits([string]$Cidr){
        $parts=$Cidr.Split('/');$ip=[Net.IPAddress]::Parse($parts[0]);$length=[int]$parts[1]
        $bits=-join @($ip.GetAddressBytes()|ForEach-Object {[Convert]::ToString([int]$_,2).PadLeft(8,'0')})
        [pscustomobject]@{Family=$ip.AddressFamily.ToString();Bits=$bits.Substring(0,$length)}
    }
    function ConvertFrom-TestBits([string]$Bits,[string]$Family){
        $total=32;if($Family -eq 'InterNetworkV6'){$total=128}
        $padded=$Bits.PadRight($total,'0');$bytes=New-Object byte[] ([int]($total/8))
        for($i=0;$i -lt $bytes.Length;$i++){$bytes[$i]=[Convert]::ToByte($padded.Substring($i*8,8),2)}
        ([Net.IPAddress]$bytes).ToString()+'/'+$Bits.Length
    }
    function Get-TestFreeBits([string]$Node,[string[]]$Excluded){
        foreach($e in $Excluded){if($Node.StartsWith($e,[StringComparison]::Ordinal)){return @()}}
        $inside=@($Excluded|Where-Object {$_.StartsWith($Node,[StringComparison]::Ordinal)})
        if(-not $inside.Count){return @($Node)}
        $left=$Node+'0';$right=$Node+'1'
        return @(Get-TestFreeBits $left @($inside|Where-Object {$_.StartsWith($left,[StringComparison]::Ordinal)}))+@(Get-TestFreeBits $right @($inside|Where-Object {$_.StartsWith($right,[StringComparison]::Ordinal)}))
    }
    function Merge-TestBits([string[]]$Bits){
        $set=New-Object 'Collections.Generic.HashSet[string]';foreach($b in $Bits){[void]$set.Add($b)}
        do{
            $changed=$false
            foreach($b in @($set)){
                if($b.Length -gt 0 -and $b.EndsWith('0',[StringComparison]::Ordinal)){
                    $parent=$b.Substring(0,$b.Length-1);$sibling=$parent+'1'
                    if($set.Contains($b) -and $set.Contains($sibling)){[void]$set.Remove($b);[void]$set.Remove($sibling);[void]$set.Add($parent);$changed=$true}
                }
            }
        }while($changed)
        @($set)
    }
    function Get-TestTunRoutes([string[]]$RouteAddress,[string[]]$RouteExclude,[string]$Family){
        $bases=@($RouteAddress|ForEach-Object {ConvertTo-TestBits $_}|Where-Object {$_.Family -eq $Family})
        $excluded=@($RouteExclude|ForEach-Object {ConvertTo-TestBits $_}|Where-Object {$_.Family -eq $Family}|ForEach-Object {$_.Bits})
        $free=@();foreach($base in $bases){$free+=@(Get-TestFreeBits $base.Bits @($excluded|Where-Object {$_.StartsWith($base.Bits,[StringComparison]::Ordinal) -or $base.Bits.StartsWith($_,[StringComparison]::Ordinal)}))}
        @(Merge-TestBits $free)
    }
    function Get-TestBestRoute($Table,[string]$Address,[int]$OnlyInterface=0){
        $suffix='/32';if($Address.Contains(':')){$suffix='/128'}
        $dest=ConvertTo-TestBits ($Address+$suffix);$best=$null
        foreach($r in $Table){
            if($OnlyInterface -and $r.If -ne $OnlyInterface){continue}
            if($r.Family -ne $dest.Family -or -not $dest.Bits.StartsWith($r.Bits,[StringComparison]::Ordinal)){continue}
            if(-not $best -or $r.Bits.Length -gt $best.Bits.Length -or ($r.Bits.Length -eq $best.Bits.Length -and $r.Metric -lt $best.Metric)){$best=$r}
        }
        $best
    }
    function Get-TestShortest($Prefixes){($Prefixes|ForEach-Object {([string]$_).Length}|Measure-Object -Minimum).Minimum}
    # Наши маршруты после вычитания исключений строго длиннее любого чужого /1 и /0, независимо от метрики.
    $routeAddress=@($tunConfigs[0].inbounds[0].route_address);$routeExclude=@($tunConfigs[0].inbounds[0].route_exclude_address)
    $realized4=@(Get-TestTunRoutes $routeAddress $routeExclude 'InterNetwork');$realized6=@(Get-TestTunRoutes $routeAddress $routeExclude 'InterNetworkV6')
    Assert ($realized4.Count -gt 0 -and (Get-TestShortest $realized4) -ge 3) 'IPv4-маршруты TUN: самый короткий не короче /3, то есть длиннее чужого /1'
    Assert ($realized6.Count -gt 0 -and (Get-TestShortest $realized6) -ge 2) 'IPv6-маршруты TUN: самый короткий не короче /2, то есть длиннее чужого /1'
    foreach($cidr in $routeExclude){
        $excludedBits=ConvertTo-TestBits $cidr;$family=@($realized4,$realized6)[[int]($excludedBits.Family -eq 'InterNetworkV6')]
        Assert (@($family|Where-Object {$_.StartsWith($excludedBits.Bits,[StringComparison]::Ordinal) -or $excludedBits.Bits.StartsWith($_,[StringComparison]::Ordinal)}).Count -eq 0) ('исключение вне маршрутов TUN: '+$cidr)
    }
    # Охват, заданный /1 или /0, даёт те же маршруты: полагаться надо на длину префикса, а не на способ записи охвата.
    Assert ((@(Get-TestTunRoutes @('0.0.0.0/1','128.0.0.0/1') $routeExclude 'InterNetwork'|Sort-Object) -join ',') -eq (@($realized4|Sort-Object) -join ',')) 'IPv4: охват /1 и /2 после вычитания исключений совпадают'
    # Настоящие ветки Enable и Worker из Vpn.Tun.ps1: подменены только границы (ОС, UAC, планировщик, сеть, sing-box).
    $tunTokens=$null;$tunErrors=$null
    $tunAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Vpn.Tun.ps1'),[ref]$tunTokens,[ref]$tunErrors)
    Assert ($tunErrors.Count -eq 0) 'Vpn.Tun.ps1 разбирается'
    $tunBody=$tunAst.Find({param($node) $node -is [Management.Automation.Language.TryStatementAst]},$false).Extent.Text
    function ConvertTo-TestRouteTable($Routes,$Adapters){
        $table=@()
        foreach($route in @($Routes)){
            $bits=ConvertTo-TestBits $route.DestinationPrefix;$owner=@($Adapters|Where-Object {[int]$_.ifIndex -eq [int]$route.InterfaceIndex})[0].Name
            $table+=@([pscustomobject]@{Family=$bits.Family;Bits=$bits.Bits;If=[int]$route.InterfaceIndex;Metric=[int]$route.Metric;Owner=[string]$owner})
        }
        $table
    }
    # Граница ОС для Vpn.Tun.ps1 и функций маршрутов: UAC, планировщик, sing-box, сеть Windows и таблица маршрутов подменены,
    # остальное (ветки Enable/Worker/Rollback, план маршрутов, хост-маршруты, проверки) настоящее. Action 'Custom' выполняет -Body в тех же условиях.
    function Invoke-TestVpn([string]$Action,[bool]$Admin,$FakeSnapshot,$FakePlan,[int[]]$OwnProcessIds=@(),[bool]$FailRoutes=$false,$ExtraRoutes=@(),[bool]$FailRemove=$false,[scriptblock]$Body=$null){
        $oldOs=$env:OS;$oldRoot=$env:SystemRoot;$realWriteStatus=${function:Write-VpnStatus}
        $script:vpnRun=@{uac=0;uacVerb='';uacArgs='';order=@();at=$null;statuses=@();checks=0;reads=0;created=@();lookups=@();capturedArg=@();failRemove=$FailRemove}
        $script:fakeRoutes=New-Object Collections.ArrayList
        foreach($r in @($FakeSnapshot.Routes)+@($ExtraRoutes)){[void]$script:fakeRoutes.Add($r)}
        try{
            $env:OS='Windows_NT';$env:SystemRoot=$work
            $root=$work;$ParentPid=0;$child=$null;$mutex=$null;$locked=$false;$parent=$null;$failure=$false;$Session=''
            $conflict=[pscustomobject]@{conflict=$false;items=@()};$tasks=Get-VpnTaskNames $root
            $sessionFile=Join-Path $root 'state/vpn-session.json';$stopFile=Join-Path $root 'state/vpn.stop';$configFile=Join-Path $root 'state/vpn-sing-box.json'
            Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
            $runSettings=Copy-TransportObject $settings;$runSettings.Vpn.enabled=($Action -eq 'Worker')
            function Read-TransportSettings { $script:vpnRun.reads++;if($script:vpnRun.reads -ge 8){Write-TransportJson $stopFile @{stop=$true}};$runSettings }
            function Get-VpnSnapshot { $FakeSnapshot }
            function Get-VpnOwnedProcessIds { $OwnProcessIds }
            function Get-TransportCandidates { $paths }
            function Get-TransportNetwork { [pscustomobject]@{interface='Wi-Fi';ifIndex=12;gateway='192.168.1.1'} }
            function Get-VpnTransportState { [pscustomobject]@{active='hy2-edge'} }
            function Get-VpnRoutePlan { $FakePlan }
            function Protect-TransportPath { }
            function Test-TransportConfigFile { }
            function Test-VpnAdministrator { $Admin }
            function Get-VpnUserName { 'test-user' }
            function Start-Process {param($FilePath,$ArgumentList,$Verb,[switch]$PassThru,[switch]$Wait) $script:vpnRun.uac++;$script:vpnRun.uacVerb=$Verb;$script:vpnRun.uacArgs=[string]$ArgumentList;[pscustomobject]@{ExitCode=0}}
            function New-ScheduledTaskAction {param($Execute,$Argument) [pscustomobject]@{Execute=$Execute;Argument=$Argument}}
            function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel) [pscustomobject]@{UserId=$UserId;RunLevel=$RunLevel}}
            function New-ScheduledTaskSettingsSet {param([switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,[switch]$StartWhenAvailable,$ExecutionTimeLimit) @{}}
            function New-ScheduledTaskTrigger {param([switch]$Once,$At) [pscustomobject]@{At=$At}}
            function Register-ScheduledTask {param($TaskName,$Action,$Trigger,$Principal,$Settings,[switch]$Force) $script:vpnRun.order+=@('register:'+$TaskName);if($TaskName -eq $tasks.Rollback){$script:vpnRun.at=$Trigger.At}}
            function Start-ScheduledTask {param($TaskName) $script:vpnRun.order+=@('start:'+$TaskName)}
            function Stop-ScheduledTask {param($TaskName,$ErrorAction)}
            function Unregister-ScheduledTask {param($TaskName,$Confirm,$ErrorAction) $script:vpnRun.order+=@('unregister:'+$TaskName)}
            function Get-CimInstance {param($ClassName,$ErrorAction) @()}
            function Start-TransportProcess {param($Exe,$Arguments,[switch]$Probe) $script:vpnRun.order+=@('tun-start');[pscustomobject]@{Process=[pscustomobject]@{HasExited=$false;Id=4242}}}
            function Stop-TransportProcess {param($Child)}
            function Save-TransportOwner {param($Root,$Component,$Child,$Exe,$Config)}
            function Clear-VpnRoutes {param($Root,$Session)}
            function Get-NetAdapter {param([switch]$IncludeHidden,$ErrorAction) [pscustomobject]@{Name='RemoteAgents-TUN';Status='Up';ifIndex=71;InterfaceGuid='tun-guid'}}
            function Test-VpnThroughTun {param($Settings,$Adapter,$Captured) $script:vpnRun.checks++;$script:vpnRun.capturedArg=@($Captured)}
            function Start-Sleep {param($Seconds,$Milliseconds) if($Seconds){Write-TransportJson $stopFile @{stop=$true}}}
            function Get-NetRoute {param($DestinationPrefix,$InterfaceIndex,$NextHop,$PolicyStore,$ErrorAction)
                @($script:fakeRoutes|Where-Object {(-not $DestinationPrefix -or $_.DestinationPrefix -eq $DestinationPrefix) -and (-not $InterfaceIndex -or [int]$_.InterfaceIndex -eq [int]$InterfaceIndex) -and (-not $NextHop -or $_.NextHop -eq $NextHop)})
            }
            function New-NetRoute {param($DestinationPrefix,$InterfaceIndex,$NextHop,$RouteMetric,$PolicyStore,$ErrorAction)
                $script:vpnRun.order+=@('route+:'+$DestinationPrefix);if($FailRoutes){throw 'отказано в доступе'}
                $script:vpnRun.created+=@([pscustomobject]@{prefix=$DestinationPrefix;ifIndex=[int]$InterfaceIndex;nextHop=$NextHop;metric=$RouteMetric;store=$PolicyStore})
                [void]$script:fakeRoutes.Add([pscustomobject]@{DestinationPrefix=$DestinationPrefix;InterfaceIndex=[int]$InterfaceIndex;NextHop=$NextHop;RouteMetric=$RouteMetric;Metric=([int]$RouteMetric+25)})
            }
            function Remove-NetRoute {param($DestinationPrefix,$InterfaceIndex,$NextHop,$PolicyStore,$Confirm,$ErrorAction)
                $script:vpnRun.order+=@('route-:'+$DestinationPrefix);if($script:vpnRun.failRemove){throw 'отказано в доступе'}
                $left=@($script:fakeRoutes|Where-Object {-not ($_.DestinationPrefix -eq $DestinationPrefix -and [int]$_.InterfaceIndex -eq [int]$InterfaceIndex -and $_.NextHop -eq $NextHop)})
                $script:fakeRoutes.Clear();foreach($r in $left){[void]$script:fakeRoutes.Add($r)}
            }
            function Find-NetRoute {param($RemoteIPAddress,$ErrorAction)
                $w=Get-TestBestRoute (ConvertTo-TestRouteTable $script:fakeRoutes $FakeSnapshot.Adapters) $RemoteIPAddress
                $script:vpnRun.lookups+=@([pscustomobject]@{address=$RemoteIPAddress;interface=$w.If;owner=$w.Owner})
                [pscustomobject]@{DestinationPrefix='model';InterfaceIndex=$w.If}
            }
            function Write-VpnStatus {param($Root,$Ok,$Enabled,$State,$Conflict,$Summary) & $realWriteStatus $Root $Ok $Enabled $State $Conflict $Summary;$written=Read-TransportJson (Join-Path $Root 'status/vpn.json');$script:vpnRun.statuses+=@([pscustomobject]@{state=$State;ok=$Ok;summary=$written.summary;warning=$written.warning})}
            if($Action -in @('Worker','Rollback')){$Session='test-session';Write-TransportJson $sessionFile @{session=$Session}}
            if($Body){return (& $Body)}
            $bodyOutput=. ([scriptblock]::Create($tunBody)) 2>$null
            [pscustomobject]@{failure=$failure;statuses=@($script:vpnRun.statuses)}
        }finally{$env:OS=$oldOs;$env:SystemRoot=$oldRoot}
    }
    # Реальный снимок компьютера владельца (Test-VpnConflict.ps1 на сборке 00815a7): рядом работает Happ в режиме TUN
    # (happd.exe, Happ.exe, xray.exe; адаптер happ-default-tun «SocksTunnel Tunnel», ifIndex 70; маршруты 0.0.0.0/1 и
    # 128.0.0.0/1 via 0.0.0.0, 0.0.0.0/0 via 10.6.7.2), а также OpenVPN TAP-Windows6 и Tailscale. Wi-Fi, адреса
    # OpenVPN, служебные маршруты Windows (loopback, multicast, Teredo, 6to4) и метрики типовые: Metric — полная метрика
    # (маршрут + интерфейс) только для модели выбора маршрута. 203.0.113.99/32 — обход собственного сервера Happ через шлюз.
    $ownerRoutes=@(
        @{p='0.0.0.0/0';i=12;h='192.168.1.1';m=25},@{p='192.168.1.0/24';i=12;h='0.0.0.0';m=281},@{p='192.168.1.50/32';i=12;h='0.0.0.0';m=281},
        @{p='169.254.0.0/16';i=12;h='0.0.0.0';m=281},@{p='224.0.0.0/4';i=12;h='0.0.0.0';m=281},@{p='255.255.255.255/32';i=12;h='0.0.0.0';m=281},
        @{p='203.0.113.99/32';i=12;h='192.168.1.1';m=26},@{p='127.0.0.0/8';i=1;h='0.0.0.0';m=331},
        @{p='::/0';i=12;h='fe80::1';m=25},@{p='2001:db8:1::/64';i=12;h='::';m=281},@{p='2001:db8:1::50/128';i=12;h='::';m=281},@{p='fe80::/64';i=12;h='::';m=281},@{p='ff00::/8';i=12;h='::';m=256},
        @{p='0.0.0.0/1';i=70;h='0.0.0.0';m=1},@{p='128.0.0.0/1';i=70;h='0.0.0.0';m=1},@{p='0.0.0.0/0';i=70;h='10.6.7.2';m=2},@{p='10.6.7.0/30';i=70;h='0.0.0.0';m=257},
        @{p='10.8.0.0/24';i=9;h='0.0.0.0';m=281},@{p='198.51.100.0/24';i=9;h='10.8.0.1';m=282},
        @{p='100.64.0.0/10';i=15;h='0.0.0.0';m=5},@{p='fd7a:115c:a1e0::/48';i=15;h='::';m=5},
        @{p='2001::/32';i=18;h='::';m=271},@{p='2002::/16';i=19;h='::';m=281})
    $ownerSnap=[pscustomobject]@{
        Processes=@(
            [pscustomobject]@{Name='happd.exe';ProcessId=5100;ExecutablePath='C:\Program Files\Happ\happd.exe'},
            [pscustomobject]@{Name='Happ.exe';ProcessId=5200;ExecutablePath='C:\Program Files\Happ\Happ.exe'},
            [pscustomobject]@{Name='xray.exe';ProcessId=5300;ExecutablePath='C:\Program Files\Happ\xray.exe'},
            [pscustomobject]@{Name='sing-box.exe';ProcessId=5400;ExecutablePath='C:\RemoteAgents\sing-box.exe'});
        Adapters=@(
            [pscustomobject]@{ifIndex=1;Name='Loopback Pseudo-Interface 1';Status='Up';HardwareInterface=$false;Virtual=$true;InterfaceDescription='Software Loopback Interface 1'},
            [pscustomobject]@{ifIndex=12;Name='Wi-Fi';Status='Up';HardwareInterface=$true;Virtual=$false;InterfaceDescription='Intel(R) Wi-Fi 6 AX201 160MHz'},
            [pscustomobject]@{ifIndex=70;Name='happ-default-tun';Status='Up';HardwareInterface=$false;Virtual=$true;InterfaceDescription='SocksTunnel Tunnel'},
            [pscustomobject]@{ifIndex=9;Name='OpenVPN TAP-Windows6';Status='Up';HardwareInterface=$false;Virtual=$true;InterfaceDescription='TAP-Windows Adapter V9'},
            [pscustomobject]@{ifIndex=15;Name='Tailscale';Status='Up';HardwareInterface=$false;Virtual=$true;InterfaceDescription='Tailscale Tunnel'},
            [pscustomobject]@{ifIndex=18;Name='Teredo Tunneling Pseudo-Interface';Status='Up';HardwareInterface=$false;Virtual=$true;InterfaceDescription='Teredo Tunneling Pseudo-Interface'},
            [pscustomobject]@{ifIndex=19;Name='6TO4 Adapter';Status='Up';HardwareInterface=$false;Virtual=$true;InterfaceDescription='Microsoft 6to4 Adapter'});
        Routes=@($ownerRoutes|ForEach-Object {[pscustomobject]@{DestinationPrefix=$_.p;InterfaceIndex=$_.i;NextHop=$_.h;Metric=$_.m}})}
    $ownerNet=[pscustomobject]@{interface='Wi-Fi';ifIndex=12;gateway='192.168.1.1'}
    $inventory=Find-VpnConflicts $ownerSnap @(5400) ''
    Assert ($inventory.conflict -and (Get-VpnCoexistenceWarning $inventory) -eq 'рядом работает: happ-default-tun, OpenVPN TAP-Windows6, Tailscale') 'снимок владельца: Happ, OpenVPN и Tailscale названы в предупреждении'
    Assert ($inventory.processHints -eq 'happd.exe, Happ.exe, xray.exe') 'снимок владельца: наш sing-box не считается чужим процессом'
    Assert ((@($inventory.items|Where-Object {$_.kind -eq 'route' -and $_.name -eq 'happ-default-tun'}|ForEach-Object {$_.detail.Split(' ')[0]}|Sort-Object) -join ',') -eq '0.0.0.0/0,0.0.0.0/1,128.0.0.0/1') 'снимок владельца: три маршрута Happ найдены'
    $realText=${function:Invoke-TransportText}
    try{function Invoke-TransportText($Exe,$Arguments){$script:fakeHop}
        $ownerPlan=Get-VpnRoutePlan $settings $paths $ownerSnap @{'entry.example.com'=@('203.0.113.55')} -Root $work
        $mixedPlan=Get-VpnRoutePlan $settings $paths $ownerSnap @{'entry.example.com'=@('10.20.30.40','198.51.100.77','2001:db8:77::1','203.0.113.55')} -Root $work
        $legacyExclusions=@(Get-VpnExclusions $settings $paths $ownerSnap @{'entry.example.com'=@('203.0.113.55')} -Root $work)
    }finally{Set-Item function:Invoke-TransportText $realText}
    $ownerExclusions=@($ownerPlan.Exclusions)
    Assert (($legacyExclusions -join ',') -eq ($ownerExclusions -join ',')) 'Get-VpnExclusions остаётся обёрткой над планом маршрутов'
    Assert ((@($ownerPlan.Endpoints|Sort-Object) -join ',') -eq (@('203.0.113.10','203.0.113.20','203.0.113.30','203.0.113.40','203.0.113.55')|Sort-Object) -join ',') 'план: публичные узлы канала (сервер, entry, relay, hop, домен) идут в обход через физический шлюз'
    Assert ((@($mixedPlan.Endpoints|Sort-Object) -join ',') -eq (@('2001:db8:77::1','203.0.113.10','203.0.113.20','203.0.113.30','203.0.113.40','203.0.113.55')|Sort-Object) -join ',' -and '10.20.30.40/32' -in $mixedPlan.Exclusions -and '198.51.100.77/32' -in $mixedPlan.Exclusions) 'план: частный адрес и адрес внутри сети OpenVPN остаются исключёнными из TUN, но без хост-маршрута через интернет-шлюз'
    foreach($cidr in @('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16','100.64.0.0/10','10.8.0.0/24','198.51.100.0/24','10.8.0.1/32','203.0.113.10/32','203.0.113.20/32','203.0.113.30/32','203.0.113.40/32','203.0.113.55/32')){Assert ($cidr -in $ownerExclusions) ('снимок владельца: исключение '+$cidr)}
    Assert (@($ownerExclusions|Where-Object {$_ -in @('0.0.0.0/0','0.0.0.0/1','128.0.0.0/1','10.6.7.0/30','10.6.7.2/32')}).Count -eq 0) 'снимок владельца: маршруты Happ не исключаются из TUN'
    # Физический адаптер выбирается мимо Happ даже при самом низком метрике его default.
    $ownerNetwork=@{}
    foreach($variant in @('hardware-only','happ-listed-as-physical')){
        $ownerNetwork[$variant]=& {
            $listAll=($variant -eq 'happ-listed-as-physical')
            function Get-NetAdapter {param([switch]$Physical,[switch]$IncludeHidden,$ErrorAction) @($ownerSnap.Adapters|Where-Object {$listAll -or $_.HardwareInterface})}
            function Get-NetRoute {param($DestinationPrefix,$ErrorAction) @($ownerSnap.Routes|Where-Object {$_.DestinationPrefix -eq $DestinationPrefix}|ForEach-Object {[pscustomobject]@{InterfaceIndex=$_.InterfaceIndex;NextHop=$_.NextHop;RouteMetric=0}})}
            function Get-NetIPInterface {param($InterfaceIndex,$AddressFamily,$ErrorAction) [pscustomobject]@{InterfaceMetric=@{12=25;70=2}[[int]$InterfaceIndex]}}
            function Get-NetConnectionProfile {param($InterfaceIndex,$ErrorAction) [pscustomobject]@{Name='HomeWiFi'}}
            function Get-NetNeighbor {param($InterfaceIndex,$IPAddress,$ErrorAction) [pscustomobject]@{State='Reachable';LinkLayerAddress='AA-BB-CC-DD-EE-FF'}}
            function Get-NetIPAddress {param($InterfaceIndex,$AddressFamily,$ErrorAction) [pscustomobject]@{IPAddress='192.168.1.50';AddressState='Preferred'}}
            Get-TransportNetwork
        }
        Assert ($ownerNetwork[$variant].available -and $ownerNetwork[$variant].interface -eq 'Wi-Fi' -and $ownerNetwork[$variant].ifIndex -eq 12 -and $ownerNetwork[$variant].gateway -eq '192.168.1.1') ('снимок владельца: сокеты и хост-маршруты привязываются к Wi-Fi и его шлюзу, а не к happ-default-tun ('+$variant+')')
    }
    # Все собственные сокеты TUN привязаны к физическому адаптеру: сервер и hop идут мимо TUN и мимо Happ.
    foreach($candidate in @($paths.Candidates|Where-Object {$_.tunCapable})){
        $ownerTun=New-VpnTunConfig $settings $paths $candidate.tag $ownerExclusions $ownerNetwork['hardware-only'].interface
        $sockets=@($ownerTun.outbounds|Where-Object {$_.type -ne 'selector' -and -not $_.detour})
        Assert ($sockets.Count -gt 0 -and @($sockets|Where-Object {$_.bind_interface -ne 'Wi-Fi'}).Count -eq 0) ('снимок владельца: сокеты '+$candidate.tag+' привязаны к физическому Wi-Fi')
        Assert (@($ownerTun.dns.servers|Where-Object {$_.bind_interface -and $_.bind_interface -ne 'Wi-Fi'}).Count -eq 0 -and ($ownerTun.dns.servers|Where-Object {$_.tag -eq 'bootstrap'}).bind_interface -eq 'Wi-Fi') ('снимок владельца: bootstrap DNS '+$candidate.tag+' привязан к Wi-Fi')
    }
    $ownerTun=New-VpnTunConfig $settings $paths 'hy2-edge' $ownerExclusions 'Wi-Fi'
    Assert (@($ownerExclusions|Where-Object {$_ -notin $ownerTun.inbounds[0].route_exclude_address}).Count -eq 0) 'снимок владельца: все исключения переданы в route_exclude_address'
    # Таблица маршрутов: снимок владельца + наши маршруты (ifIndex 71, метрика 0) + служебные маршруты нашего интерфейса.
    $ownerRealized4=@(Get-TestTunRoutes $ownerTun.inbounds[0].route_address $ownerTun.inbounds[0].route_exclude_address 'InterNetwork')
    $ownerRealized6=@(Get-TestTunRoutes $ownerTun.inbounds[0].route_address $ownerTun.inbounds[0].route_exclude_address 'InterNetworkV6')
    Assert ((Get-TestShortest $ownerRealized4) -ge 3 -and (Get-TestShortest $ownerRealized6) -ge 2) 'снимок владельца: наши префиксы длиннее /1 Happ (IPv4 от /3, IPv6 от /2)'
    $ownerTable=@(ConvertTo-TestRouteTable $ownerSnap.Routes $ownerSnap.Adapters)
    $ownerOwn=@()
    foreach($bits in $ownerRealized4){$ownerOwn+=@([pscustomobject]@{Family='InterNetwork';Bits=$bits;If=71;Metric=0;Owner='RemoteAgents-TUN'})}
    foreach($bits in $ownerRealized6){$ownerOwn+=@([pscustomobject]@{Family='InterNetworkV6';Bits=$bits;If=71;Metric=0;Owner='RemoteAgents-TUN'})}
    foreach($cidr in @('172.31.255.0/30','172.31.255.1/32','172.31.255.3/32','224.0.0.0/4','255.255.255.255/32','fdfe:7261::/126','fdfe:7261::1/128','fe80::/64','ff00::/8')){$bits=ConvertTo-TestBits $cidr;$ownerOwn+=@([pscustomobject]@{Family=$bits.Family;Bits=$bits.Bits;If=71;Metric=256;Owner='RemoteAgents-TUN'})}
    $ownerTable+=$ownerOwn
    foreach($address in @('8.8.8.8','1.1.1.1','93.184.216.34','142.250.74.46','151.101.1.69','198.18.0.1','2606:4700:4700::1111','2001:4860:4860::8888')){
        Assert ((Get-TestBestRoute $ownerTable $address).If -eq 71) ('снимок владельца: интернет '+$address+' уходит в наш TUN, а не в Happ')
    }
    foreach($case in @(@('192.168.1.1',12),@('10.8.0.1',9),@('198.51.100.17',9),@('100.100.100.100',15),@('fd7a:115c:a1e0::1',15))){
        Assert ((Get-TestBestRoute $ownerTable $case[0]).If -eq $case[1]) ('снимок владельца: '+$case[0]+' остаётся на своём интерфейсе '+$case[1]+', наш TUN не перехватывает')
    }
    foreach($address in @('203.0.113.10','203.0.113.20','203.0.113.30','203.0.113.40','203.0.113.55')){
        $viaTable=Get-TestBestRoute $ownerTable $address;$bound=Get-TestBestRoute $ownerTable $address -OnlyInterface 12
        Assert ($viaTable.If -eq 70 -and $viaTable.Owner -eq 'happ-default-tun') ('снимок владельца: '+$address+' не наш маршрут; без привязки сокета он ушёл бы в Happ')
        Assert ($bound.If -eq 12 -and $bound.Bits.Length -eq 0) ('снимок владельца: сокет '+$address+', привязанный к Wi-Fi, идёт по default физического адаптера мимо TUN и Happ')
    }
    # Настоящая проверка победителя маршрутов (Assert-VpnInternetRoutes) на модели снимка: проходит, а чужой более длинный префикс её ломает.
    foreach($foreignLonger in @($false,$true)){
        $script:simTable=@($ownerTable)
        if($foreignLonger){foreach($cidr in @('32.0.0.0/4','64.0.0.0/4')){$bits=ConvertTo-TestBits $cidr;$script:simTable+=@([pscustomobject]@{Family=$bits.Family;Bits=$bits.Bits;If=70;Metric=1;Owner='happ-default-tun'})}}
        $verdict=& {
            function Get-NetRoute {param($InterfaceIndex,$ErrorAction) foreach($r in @($ownerOwn)){[pscustomobject]@{InterfaceIndex=71;DestinationPrefix=(ConvertFrom-TestBits $r.Bits $r.Family)}}}
            function Find-NetRoute {param($RemoteIPAddress,$ErrorAction) $w=Get-TestBestRoute $script:simTable $RemoteIPAddress;[pscustomobject]@{DestinationPrefix='model';InterfaceIndex=$w.If}}
            $threw=$false;try{Assert-VpnInternetRoutes $settings ([pscustomobject]@{ifIndex=71})}catch{$threw=$true};$threw
        }
        Assert ($verdict -eq $foreignLonger) ('снимок владельца: проверка победителя маршрутов '+$(if($foreignLonger){'ловит чужой более длинный префикс'}else{'проходит рядом с Happ'}))
    }
    # Enable доходит до UAC, элевированный Enable ставит автооткат до запуска worker, worker доходит до on: предупреждение в статусе.
    $ownerWarning='рядом работает: happ-default-tun, OpenVPN TAP-Windows6, Tailscale'
    $ownerTasks=Get-VpnTaskNames $work
    $stateFile=Join-Path $work 'state/vpn-bypass-routes.json'
    $run=Invoke-TestVpn 'Enable' $false $ownerSnap $ownerPlan @(5400)
    $uacStatus=Read-TransportJson (Join-Path $work 'status/vpn.json')
    Assert ($script:vpnRun.uac -eq 1 -and $script:vpnRun.uacVerb -eq 'RunAs' -and $script:vpnRun.uacArgs.Contains('-Broker') -and -not $run.failure) 'снимок владельца: Happ рядом не блокирует Enable, UAC остаётся явным'
    Assert ($uacStatus.state -eq 'awaiting-uac' -and $uacStatus.warning -eq $ownerWarning -and $uacStatus.summary.Contains($ownerWarning) -and $uacStatus.conflict.conflict) 'снимок владельца: предупреждение рядом с состоянием UAC'
    $run=Invoke-TestVpn 'Enable' $true $ownerSnap $ownerPlan @(5400)
    $startStatus=Read-TransportJson (Join-Path $work 'status/vpn.json')
    Assert (-not $run.failure -and ($script:vpnRun.order -join ',') -eq ('register:'+$ownerTasks.Rollback+',register:'+$ownerTasks.Worker+',start:'+$ownerTasks.Worker)) 'снимок владельца: автооткат зарегистрирован до запуска worker'
    Assert (($script:vpnRun.at-(Get-Date)).TotalSeconds -gt 290 -and ($script:vpnRun.at-(Get-Date)).TotalSeconds -le 300) 'снимок владельца: автооткат через пять минут'
    Assert ($startStatus.state -eq 'starting' -and $startStatus.enabled -and $startStatus.warning -eq $ownerWarning -and (Get-VpnOptions (Read-TransportSettings $work)).enabled) 'снимок владельца: запуск идёт с предупреждением и сохранённым намерением'
    Set-VpnEnabled $work $false
    # Worker рядом с Happ: остаток убитого прежнего worker чистится, хост-маршруты к узлам канала ставятся до запуска TUN,
    # проверка победителя идёт до снятия автоотката, при остановке остаются только чужие маршруты.
    $staleRoute=[pscustomobject]@{DestinationPrefix='203.0.113.77/32';InterfaceIndex=12;NextHop='192.168.1.1';RouteMetric=1;Metric=26}
    Write-TransportJson $stateFile @{session='dead-session';routes=@([pscustomobject]@{prefix='203.0.113.77/32';ifIndex=12;nextHop='192.168.1.1'})}
    $run=Invoke-TestVpn 'Worker' $true $ownerSnap $ownerPlan @(5400) -ExtraRoutes @($staleRoute)
    $order=@($script:vpnRun.order);$onStates=@($run.statuses|Where-Object {$_.state -eq 'on'})
    Assert (-not $run.failure -and $onStates.Count -ge 1 -and $onStates[0].ok -and $onStates[0].summary.Contains($ownerWarning) -and $script:vpnRun.checks -ge 1) 'снимок владельца: worker проходит проверку TUN и достигает on рядом с Happ'
    $taskOrder=@($order|Where-Object {$_ -like 'register:*' -or $_ -like 'unregister:*'})
    Assert ($taskOrder[0] -eq ('register:'+$ownerTasks.Rollback) -and $taskOrder[1] -eq ('unregister:'+$ownerTasks.Rollback)) 'снимок владельца: автооткат снимается только после проверки TUN'
    $endpointRoutes=@($script:vpnRun.created)
    Assert ($endpointRoutes.Count -eq 5 -and @($endpointRoutes|Where-Object {$_.nextHop -eq '192.168.1.1' -and $_.ifIndex -eq 12 -and $_.metric -eq 1 -and $_.store -eq 'ActiveStore' -and $_.prefix -match '^203\.0\.113\.(10|20|30|40|55)/32$'}).Count -eq 5) 'снимок владельца: хост-маршруты /32 к серверу и hop через шлюз Wi-Fi, ActiveStore'
    Assert ($order.IndexOf('route-:203.0.113.77/32') -ge 0 -and $order.IndexOf('route-:203.0.113.77/32') -lt $order.IndexOf('route+:203.0.113.10/32') -and $order.IndexOf('route+:203.0.113.10/32') -lt $order.IndexOf('tun-start')) 'снимок владельца: остаток прежнего worker убран, хост-маршруты стоят до запуска TUN'
    Assert (@($script:vpnRun.lookups|Where-Object {$_.interface -eq 12}).Count -ge 5 -and @($script:vpnRun.lookups|Where-Object {$_.interface -ne 12}).Count -eq 0) 'снимок владельца: маршрут до каждого узла канала проверен и идёт через Wi-Fi, а не через Happ'
    Assert ((@($script:fakeRoutes|Where-Object {$_.NextHop -eq '192.168.1.1' -and $_.DestinationPrefix -match '^203\.0\.113\.(10|20|30|40|55|77)/32$'}).Count -eq 0) -and -not (Test-Path -LiteralPath $stateFile) -and @($script:fakeRoutes|Where-Object {$_.DestinationPrefix -eq '203.0.113.99/32'}).Count -eq 1) 'снимок владельца: при остановке хост-маршруты убраны, чужой обход Happ не тронут'
    $finalStatus=Read-TransportJson (Join-Path $work 'status/vpn.json')
    Assert (@($finalStatus.conflict.captured).Count -eq 0 -and @($finalStatus.conflict.ignored|Where-Object {$_.prefix -eq '203.0.113.99/32' -and $_.reason -eq 'neighbor-host-bypass'}).Count -eq 1 -and @($finalStatus.conflict.ignored|Where-Object {$_.prefix -eq '2001:db8:1::/64' -and $_.reason -eq 'lan'}).Count -eq 1) 'снимок владельца: служебные маршруты Windows не тревожат, обход сервера Happ и LAN объяснены'
    $workerConfig=Read-TransportJson (Join-Path $work 'state/vpn-sing-box.json')
    Assert (($workerConfig.inbounds[0].route_address -join ',') -eq ($ownerTun.inbounds[0].route_address -join ',') -and '198.51.100.0/24' -in $workerConfig.inbounds[0].route_exclude_address -and '203.0.113.40/32' -in $workerConfig.inbounds[0].route_exclude_address) 'снимок владельца: worker строит TUN из тех же исключений'
    Assert (([IO.File]::ReadAllText((Join-Path $work 'logs/vpn.log'))).Contains('on '+$ownerWarning)) 'снимок владельца: предупреждение записано в локальный журнал'
    Set-VpnEnabled $work $false
    # Без привязки сокета (пересылка на Wi-Fi, ICS) /1 Happ забрал бы сервер: хост-маршрут возвращает его на физический шлюз,
    # а проверка победителя ловит случай, когда обход не создан или его перебивает чужой /32.
    $plainSnap=[pscustomobject]@{Processes=@();Adapters=@($ownerSnap.Adapters|Where-Object {$_.ifIndex -in @(1,12)});Routes=@($ownerSnap.Routes|Where-Object {$_.InterfaceIndex -in @(1,12)})}
    $foreignHost=[pscustomobject]@{DestinationPrefix='203.0.113.10/32';InterfaceIndex=70;NextHop='0.0.0.0';RouteMetric=1;Metric=1}
    $verdicts=@{}
    foreach($case in @(@('happ-no-bypass',$ownerSnap,$true,@()),@('happ-with-bypass',$ownerSnap,$false,@()),@('plain-no-bypass',$plainSnap,$true,@()),@('foreign-host-route',$ownerSnap,$false,@($foreignHost)))){
        $verdicts[$case[0]]=Invoke-TestVpn 'Custom' $true $case[1] $ownerPlan -FailRoutes $case[2] -ExtraRoutes $case[3] -Body {
            $sync=Sync-VpnBypassRoutes $work 'verdict' $ownerNet @($ownerPlan.Endpoints)
            $threw=$false;try{Assert-VpnEndpointRoutes $ownerNet $sync.check}catch{$threw=$true}
            Clear-VpnBypassRoutes $work 'verdict'
            [pscustomobject]@{failed=$sync.failed;added=$sync.added;threw=$threw}
        }
    }
    Assert ($verdicts['happ-no-bypass'].failed -eq 5 -and $verdicts['happ-no-bypass'].threw) 'сервер и hop без хост-маршрута уходят в Happ: проверка узлов канала это ловит'
    Assert ($verdicts['happ-with-bypass'].added -eq 5 -and -not $verdicts['happ-with-bypass'].threw) 'с хост-маршрутами сервер и hop идут через физический шлюз даже при /1 Happ'
    Assert ($verdicts['plain-no-bypass'].failed -eq 5 -and -not $verdicts['plain-no-bypass'].threw) 'без соседнего VPN сбой создания хост-маршрута не мешает: default физического адаптера и так верный'
    Assert ($verdicts['foreign-host-route'].threw) 'чужой /32 до сервера с меньшей метрикой перебивает наш обход: проверка узлов канала это ловит'
    # Worker: обход не создан, Happ перехватывает сервер — TUN не подтверждается, проверка TUN не доходит, остатков нет.
    $run=Invoke-TestVpn 'Worker' $true $ownerSnap $ownerPlan @(5400) -FailRoutes $true
    $lastStatus=Read-TransportJson (Join-Path $work 'status/vpn.json')
    Assert ($run.failure -and @($run.statuses|Where-Object {$_.state -eq 'on'}).Count -eq 0 -and $lastStatus.state -eq 'error' -and $lastStatus.warning -eq $ownerWarning -and $script:vpnRun.checks -eq 0 -and -not (Test-Path -LiteralPath $stateFile)) 'снимок владельца: сервер перехвачен Happ, обход не создан: worker не объявляет on и откатывается'
    Set-VpnEnabled $work $false
    $run=Invoke-TestVpn 'Worker' $true $plainSnap $ownerPlan @(5400) -FailRoutes $true
    Assert (-not $run.failure -and @($run.statuses|Where-Object {$_.state -eq 'on'}).Count -ge 1) 'без соседнего VPN worker доходит до on и при сбое создания хост-маршрутов'
    Set-VpnEnabled $work $false
    # Независимый автооткат удаляет и хост-маршруты; чужой сеанс и сбой удаления его не ломают.
    $rbRoute=[pscustomobject]@{DestinationPrefix='203.0.113.10/32';InterfaceIndex=12;NextHop='192.168.1.1';RouteMetric=1;Metric=26}
    $rbState=@{session='test-session';routes=@([pscustomobject]@{prefix='203.0.113.10/32';ifIndex=12;nextHop='192.168.1.1'})}
    Write-TransportJson $stateFile $rbState
    $run=Invoke-TestVpn 'Rollback' $true $ownerSnap $ownerPlan @(5400) -ExtraRoutes @($rbRoute)
    Assert (-not $run.failure -and $run.statuses[-1].state -eq 'rolled-back' -and $script:vpnRun.order -contains 'route-:203.0.113.10/32' -and -not (Test-Path -LiteralPath $stateFile) -and @($script:fakeRoutes|Where-Object {$_.DestinationPrefix -eq '203.0.113.10/32' -and $_.NextHop -eq '192.168.1.1'}).Count -eq 0) 'автооткат удаляет хост-маршруты к узлам канала'
    Write-TransportJson $stateFile @{session='other-session';routes=$rbState.routes}
    $run=Invoke-TestVpn 'Rollback' $true $ownerSnap $ownerPlan @(5400) -ExtraRoutes @($rbRoute)
    Assert ($run.statuses[-1].state -eq 'rolled-back' -and (Test-Path -LiteralPath $stateFile) -and @($script:fakeRoutes|Where-Object {$_.DestinationPrefix -eq '203.0.113.10/32' -and $_.NextHop -eq '192.168.1.1'}).Count -eq 1) 'автооткат не трогает хост-маршруты чужого сеанса'
    Remove-Item -LiteralPath $stateFile -Force
    Write-TransportJson $stateFile $rbState
    $run=Invoke-TestVpn 'Rollback' $true $ownerSnap $ownerPlan @(5400) -ExtraRoutes @($rbRoute) -FailRemove $true
    Assert ($run.failure -and (Test-Path -LiteralPath $stateFile) -and @($script:vpnRun.order|Where-Object {$_ -like 'unregister:*'}).Count -eq 0 -and $run.statuses[-1].state -eq 'error') 'сбой удаления хост-маршрута: запись и независимый автооткат сохранены'
    Remove-Item -LiteralPath $stateFile -Force
    # Sync/Clear: что создаётся, что записывается, что удаляется.
    $sync=Invoke-TestVpn 'Custom' $true $ownerSnap $ownerPlan -Body {
        $endpoints=@($ownerPlan.Endpoints)
        $first=Sync-VpnBypassRoutes $work 'sync-a' $ownerNet $endpoints
        $again=Sync-VpnBypassRoutes $work 'sync-a' $ownerNet $endpoints
        $fewer=Sync-VpnBypassRoutes $work 'sync-a' $ownerNet @($endpoints|Where-Object {$_ -ne '203.0.113.55'})
        $recorded=@((Read-TransportJson $stateFile).routes|ForEach-Object {$_.prefix}|Sort-Object)
        $other=Sync-VpnBypassRoutes $work 'sync-b' $ownerNet @('203.0.113.20')
        $afterOther=@((Read-TransportJson $stateFile).routes|ForEach-Object {$_.prefix})
        Clear-VpnBypassRoutes $work 'sync-b'
        [pscustomobject]@{first=$first;again=$again;fewer=$fewer;recorded=$recorded;other=$other;afterOther=$afterOther;left=@($script:fakeRoutes|ForEach-Object {$_.DestinationPrefix});stateGone=-not (Test-Path -LiteralPath $stateFile)}
    }
    Assert ($sync.first.added -eq 5 -and $sync.first.failed -eq 0 -and @($sync.first.check).Count -eq 5) 'Sync: пять публичных узлов — пять хост-маршрутов'
    Assert ($sync.again.added -eq 0 -and $sync.again.removed -eq 0 -and $sync.again.failed -eq 0 -and $sync.again.preexisting -eq 0) 'Sync: повтор ничего не меняет и не считает свои маршруты чужими'
    Assert ($sync.fewer.removed -eq 1 -and ($sync.recorded -join ',') -eq '203.0.113.10/32,203.0.113.20/32,203.0.113.30/32,203.0.113.40/32') 'Sync: ушедший из списка узел теряет только свой маршрут и запись'
    Assert ($sync.other.added -eq 1 -and ($sync.afterOther -join ',') -eq '203.0.113.20/32' -and ($sync.left -join ',') -notmatch '203\.0\.113\.(10|30|40|55)/32' -and $sync.stateGone) 'Sync: запись другого сеанса сначала чистится; Clear убирает последний маршрут и запись'
    $existing=[pscustomobject]@{DestinationPrefix='203.0.113.10/32';InterfaceIndex=12;NextHop='192.168.1.1';RouteMetric=5;Metric=30}
    $clear=Invoke-TestVpn 'Custom' $true $ownerSnap $ownerPlan -ExtraRoutes @($existing) -Body {
        $r=Sync-VpnBypassRoutes $work 'clear-a' $ownerNet @('203.0.113.10','203.0.113.20')
        $recordedBefore=@((Read-TransportJson $stateFile).routes|ForEach-Object {$_.prefix})
        Clear-VpnBypassRoutes $work 'not-our-session'
        $afterWrong=@($script:fakeRoutes|Where-Object {$_.DestinationPrefix -in @('203.0.113.10/32','203.0.113.20/32')}).Count
        Clear-VpnBypassRoutes $work 'clear-a'
        [pscustomobject]@{result=$r;recorded=$recordedBefore;afterWrong=$afterWrong;left=@($script:fakeRoutes|Where-Object {$_.DestinationPrefix -in @('203.0.113.10/32','203.0.113.20/32')}|ForEach-Object {$_.DestinationPrefix})}
    }
    Assert ($clear.result.added -eq 1 -and $clear.result.preexisting -eq 1 -and ($clear.recorded -join ',') -eq '203.0.113.20/32') 'Sync: чужой такой же маршрут не записывается как наш'
    Assert ($clear.afterWrong -eq 2 -and ($clear.left -join ',') -eq '203.0.113.10/32') 'Clear: чужой сеанс не трогает, свой сеанс удаляет только записанное'
    $v6=Invoke-TestVpn 'Custom' $true $ownerSnap $ownerPlan -Body {
        $withGateway=Sync-VpnBypassRoutes $work 'v6-a' $ownerNet @('2001:db8:77::1','203.0.113.10')
        $created=@($script:vpnRun.created|ForEach-Object {$_.prefix+'>'+$_.nextHop})
        Clear-VpnBypassRoutes $work 'v6-a'
        $noGateway=Sync-VpnBypassRoutes $work 'v6-b' ([pscustomobject]@{interface='Ethernet 2';ifIndex=13;gateway='192.168.2.1'}) @('2001:db8:88::1','203.0.113.11')
        Clear-VpnBypassRoutes $work 'v6-b'
        [pscustomobject]@{withGateway=$withGateway;created=$created;noGateway=$noGateway}
    }
    Assert ($v6.withGateway.added -eq 2 -and ($v6.created | Sort-Object) -contains '2001:db8:77::1/128>fe80::1' -and $v6.created -contains '203.0.113.10/32>192.168.1.1') 'Sync: IPv6-узел получает /128 через IPv6-шлюз физического адаптера'
    Assert ($v6.noGateway.added -eq 1 -and @($v6.noGateway.skipped).Count -eq 1 -and $v6.noGateway.skipped[0] -eq '2001:db8:88::1' -and @($v6.noGateway.check).Count -eq 1) 'Sync: без IPv6-шлюза IPv6-узел пропущен и не проверяется'
    # Хост-маршрут повторяет маршрут самого физического адаптера: статический роутер для подсети сохраняется, адрес в подсети адаптера обхода не требует.
    $staticRoutes=@([pscustomobject]@{DestinationPrefix='203.0.113.0/27';InterfaceIndex=12;NextHop='192.168.1.254';RouteMetric=5;Metric=30},[pscustomobject]@{DestinationPrefix='203.0.113.32/28';InterfaceIndex=12;NextHop='0.0.0.0';RouteMetric=5;Metric=30})
    $static=Invoke-TestVpn 'Custom' $true $ownerSnap $ownerPlan -ExtraRoutes $staticRoutes -Body {
        $r=Sync-VpnBypassRoutes $work 'static-a' $ownerNet @($ownerPlan.Endpoints)
        $created=@($script:vpnRun.created|ForEach-Object {$_.prefix+'>'+$_.nextHop}|Sort-Object)
        $assertOk=$true;try{Assert-VpnEndpointRoutes $ownerNet $r.check}catch{$assertOk=$false}
        Clear-VpnBypassRoutes $work 'static-a'
        [pscustomobject]@{result=$r;created=$created;assertOk=$assertOk}
    }
    Assert ($static.result.added -eq 4 -and @($static.result.check).Count -eq 5 -and (($static.created -join ',') -eq (@('203.0.113.10/32>192.168.1.254','203.0.113.20/32>192.168.1.254','203.0.113.30/32>192.168.1.254','203.0.113.55/32>192.168.1.1')|Sort-Object) -join ',') -and $static.assertOk) 'Sync: статический роутер подсети сохранён, адрес в подсети адаптера без обхода, остальные через default'
    # Смена шлюза: прежний хост-маршрут не принимается за маршрут адаптера и заменяется новым.
    $gateway=Invoke-TestVpn 'Custom' $true $ownerSnap $ownerPlan -Body {
        $old=Sync-VpnBypassRoutes $work 'gw-a' $ownerNet @('203.0.113.10')
        $left=@($script:fakeRoutes|Where-Object {-not ($_.DestinationPrefix -eq '0.0.0.0/0' -and $_.InterfaceIndex -eq 12)});$script:fakeRoutes.Clear();foreach($r in $left){[void]$script:fakeRoutes.Add($r)}
        [void]$script:fakeRoutes.Add([pscustomobject]@{DestinationPrefix='0.0.0.0/0';InterfaceIndex=12;NextHop='192.168.1.2';RouteMetric=0;Metric=25})
        $new=Sync-VpnBypassRoutes $work 'gw-a' ([pscustomobject]@{interface='Wi-Fi';ifIndex=12;gateway='192.168.1.2'}) @('203.0.113.10')
        $now=@($script:fakeRoutes|Where-Object {$_.DestinationPrefix -eq '203.0.113.10/32'}|ForEach-Object {$_.NextHop})
        Clear-VpnBypassRoutes $work 'gw-a'
        [pscustomobject]@{old=$old;new=$new;now=$now}
    }
    Assert ($gateway.old.added -eq 1 -and $gateway.new.removed -eq 1 -and $gateway.new.added -eq 1 -and ($gateway.now -join ',') -eq '192.168.1.2') 'Sync: после смены шлюза хост-маршрут заменяется на новый шлюз'
    $failRemove=Invoke-TestVpn 'Custom' $true $ownerSnap $ownerPlan -FailRemove $true -Body {
        $first=Sync-VpnBypassRoutes $work 'fail-a' $ownerNet @('203.0.113.10')
        $shrink=Sync-VpnBypassRoutes $work 'fail-a' $ownerNet @()
        $kept=@((Read-TransportJson $stateFile).routes).Count
        $thrown=$false;try{Clear-VpnBypassRoutes $work 'fail-a'}catch{$thrown=$true}
        $result=[pscustomobject]@{first=$first;shrink=$shrink;kept=$kept;thrown=$thrown;fileKept=(Test-Path -LiteralPath $stateFile)}
        Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
        $result
    }
    Assert ($failRemove.first.added -eq 1 -and $failRemove.shrink.failed -eq 1 -and $failRemove.kept -eq 1 -and $failRemove.thrown -and $failRemove.fileKept) 'сбой удаления: маршрут остаётся в записи, Clear сообщает об ошибке и сохраняет запись'
    # P1: чужой 8.0.0.0/8 длиннее нашего 8.0.0.0/7, а проверка одного адреса на половину интернета его не видит.
    $slipRoute=[pscustomobject]@{DestinationPrefix='8.0.0.0/8';InterfaceIndex=70;NextHop='0.0.0.0';Metric=1}
    $slipSnap=[pscustomobject]@{Processes=$ownerSnap.Processes;Adapters=$ownerSnap.Adapters;Routes=@($ownerSnap.Routes)+@($slipRoute)}
    $slipTable=@(ConvertTo-TestRouteTable $slipSnap.Routes $slipSnap.Adapters)+$ownerOwn
    Assert ((Get-TestBestRoute $slipTable '8.8.8.8').If -eq 70 -and (Get-TestBestRoute $slipTable '93.184.216.34').If -eq 71 -and (Get-TestBestRoute $slipTable '8.4.4.4').If -eq 70 -and (Get-TestBestRoute $slipTable '9.9.9.9').If -eq 71) 'снимок с 8.0.0.0/8: 8.x забирает Happ, остальной интернет наш'
    $script:simTable=$slipTable
    $oldCheck=& {
        function Get-NetRoute {param($InterfaceIndex,$ErrorAction) foreach($r in @($ownerOwn)){[pscustomobject]@{InterfaceIndex=71;DestinationPrefix=(ConvertFrom-TestBits $r.Bits $r.Family)}}}
        function Find-NetRoute {param($RemoteIPAddress,$ErrorAction) $w=Get-TestBestRoute $script:simTable $RemoteIPAddress;[pscustomobject]@{DestinationPrefix='model';InterfaceIndex=$w.If}}
        $threw=$false;try{Assert-VpnInternetRoutes $settings ([pscustomobject]@{ifIndex=71})}catch{$threw=$true};$threw
    }
    Assert (-not $oldCheck) 'проверка одного адреса на половину интернета пропускает 8.0.0.0/8 (поэтому нужен анализ перекрытий)'
    $found=Find-VpnCapturedRoutes $slipSnap $ownerExclusions ''
    Assert (@($found.captured).Count -eq 1 -and $found.captured[0].prefix -eq '8.0.0.0/8' -and $found.captured[0].interface -eq 'happ-default-tun' -and $found.captured[0].reason -eq 'captured' -and -not $found.truncated) 'перекрытия: 8.0.0.0/8 соседнего VPN найден'
    Assert ((Get-VpnCoexistenceWarning (Add-VpnCaptured ([pscustomobject]@{conflict=$false;items=@()}) $slipSnap $ownerExclusions '')) -eq 'мимо TUN идут: 8.0.0.0/8 (happ-default-tun)') 'перекрытия: предупреждение называет диапазон и интерфейс'
    $probeBlocked=$false;try{Assert-VpnProbeNotCaptured '8.8.8.8' $found.captured}catch{$probeBlocked=$true}
    Assert ($probeBlocked) 'адрес проверки внутри захваченного диапазона не принимается'
    Assert-VpnProbeNotCaptured '93.184.216.34' $found.captured;Assert-VpnProbeNotCaptured '198.18.0.1' $found.captured;Assert-VpnProbeNotCaptured '2606:4700:4700::1111' $found.captured
    $routeCheck=& {
        function Find-NetRoute {param($RemoteIPAddress,$ErrorAction) $w=Get-TestBestRoute $script:simTable $RemoteIPAddress;[pscustomobject]@{DestinationPrefix='model';InterfaceIndex=$w.If}}
        $captures=$false;try{Assert-VpnTunRoute '8.8.8.8' 71}catch{$captures=$true};$ours=$true;try{Assert-VpnTunRoute '93.184.216.34' 71}catch{$ours=$false};@($captures,$ours)
    }
    Assert ($routeCheck[0] -and $routeCheck[1]) 'цель проверки в 8.0.0.0/8 не проходит Assert-VpnTunRoute, цель вне диапазона проходит'
    # Test-VpnThroughTun целиком (bootstrap: без SSH; адрес-литерал вместо DNS): цель HTTPS в захваченном диапазоне отвергается до запроса.
    $probeSettings=Copy-TransportObject $settings;$probeSettings.Transport|Add-Member -Force bootstrap $true;$probeSettings.Vpn|Add-Member -Force checkUrl 'https://8.8.8.8/'
    $probeVerdicts=& {
        function Get-NetRoute {param($InterfaceIndex,$ErrorAction) foreach($r in @($ownerOwn)){[pscustomobject]@{InterfaceIndex=71;DestinationPrefix=(ConvertFrom-TestBits $r.Bits $r.Family)}}}
        function Find-NetRoute {param($RemoteIPAddress,$ErrorAction) $w=Get-TestBestRoute $script:simTable $RemoteIPAddress;[pscustomobject]@{DestinationPrefix='model';InterfaceIndex=$w.If}}
        $messages=@{}
        foreach($mode in @('captured-list','os-route-only')){
            $given=@();if($mode -eq 'captured-list'){$given=@($found.captured)}
            try{Test-VpnThroughTun $probeSettings ([pscustomobject]@{ifIndex=71}) $given;$messages[$mode]='no error'}catch{$messages[$mode]=$_.Exception.Message}
        }
        $messages
    }
    Assert ($probeVerdicts['captured-list'] -like '*забрал соседний VPN*' -and $probeVerdicts['os-route-only'] -like '*обходит TUN*') 'Test-VpnThroughTun: цель HTTPS в 8.0.0.0/8 отвергается и по списку захваченных диапазонов, и по фактическому маршруту ОС'
    $run=Invoke-TestVpn 'Worker' $true $slipSnap $ownerPlan @(5400)
    $slipOn=@($run.statuses|Where-Object {$_.state -eq 'on'});$slipStatus=Read-TransportJson (Join-Path $work 'status/vpn.json')
    Assert (-not $run.failure -and $slipOn.Count -ge 1 -and $slipOn[0].warning -eq ($ownerWarning+'; мимо TUN идут: 8.0.0.0/8 (happ-default-tun)') -and $slipOn[0].summary.EndsWith($slipOn[0].warning)) 'worker: on с предупреждением о захваченном 8.0.0.0/8, а не молчаливое «трафик идёт через выбранный путь»'
    Assert (@($script:vpnRun.capturedArg).Count -eq 1 -and $script:vpnRun.capturedArg[0].prefix -eq '8.0.0.0/8' -and @($slipStatus.conflict.captured).Count -eq 1 -and $slipStatus.conflict.captured[0].prefix -eq '8.0.0.0/8') 'worker: захваченные диапазоны переданы проверке TUN и записаны в status/vpn.json'
    Set-VpnEnabled $work $false
    # Точность анализа: что считается захватом, а что нет.
    $precision=@(
        @{p='8.0.0.0/8';want=$true},@{p='32.0.0.0/4';want=$true},@{p='2a00::/12';want=$true},
        @{p='64.0.0.0/3';want=$false},@{p='0.0.0.0/3';want=$false},@{p='64.0.0.0/2';want=$false},@{p='0.0.0.0/2';want=$false},
        @{p='10.99.0.0/16';want=$false},@{p='100.100.0.0/16';want=$false},@{p='198.51.100.0/25';want=$false},@{p='203.0.113.40/32';want=$false},
        @{p='224.0.0.0/24';want=$false},@{p='169.254.9.0/24';want=$false},@{p='fe80::/32';want=$false},@{p='fd00:1::/32';want=$false})
    $precisionSnap=[pscustomobject]@{Processes=@();Adapters=$ownerSnap.Adapters;Routes=@($precision|ForEach-Object {[pscustomobject]@{DestinationPrefix=$_.p;InterfaceIndex=70;NextHop='0.0.0.0';Metric=1}})}
    $precisionFound=Find-VpnCapturedRoutes $precisionSnap $ownerExclusions ''
    foreach($case in $precision){Assert ((@($precisionFound.captured|Where-Object {$_.prefix -eq $case.p}).Count -eq 1) -eq $case.want) ('перекрытия: '+$case.p+' '+$(if($case.want){'забирает адреса у TUN'}else{'не забирает адреса у TUN'}))}
    $ownFound=Find-VpnCapturedRoutes ([pscustomobject]@{Processes=@();Adapters=@($ownerSnap.Adapters)+@([pscustomobject]@{ifIndex=71;Name='RemoteAgents-TUN';Status='Up';HardwareInterface=$false;Virtual=$true;InterfaceDescription='Wintun'});Routes=@([pscustomobject]@{DestinationPrefix='8.0.0.0/8';InterfaceIndex=71;NextHop='0.0.0.0';Metric=0})}) $ownerExclusions 'RemoteAgents-TUN'
    Assert (@($ownFound.captured).Count -eq 0) 'перекрытия: маршруты нашего интерфейса не считаются чужими'
    $manyRoutes=@(1..30|ForEach-Object {[pscustomobject]@{DestinationPrefix=('8.'+$_+'.0.0/16');InterfaceIndex=70;NextHop='0.0.0.0';Metric=1}})
    $limited=Find-VpnCapturedRoutes ([pscustomobject]@{Processes=@();Adapters=$ownerSnap.Adapters;Routes=$manyRoutes}) $ownerExclusions '' -Limit 10
    Assert ($limited.truncated -and @($limited.captured).Count -eq 10) 'перекрытия: слишком большая таблица обрезается с пометкой, а не тормозит worker'
    $listed=[pscustomobject]@{conflict=$false;items=@();captured=@(1..4|ForEach-Object {[pscustomobject]@{prefix=('9.'+$_+'.0.0/'+(8+$_));interface=('if'+$_)}})}
    Assert ((Get-VpnCoexistenceWarning $listed) -eq 'мимо TUN идут: 9.1.0.0/9 (if1), 9.2.0.0/10 (if2), 9.3.0.0/11 (if3) и ещё 1') 'предупреждение показывает три самых широких диапазона и число остальных'
    # Worker пишет статус раз в секунду: предупреждение повторяется в журнале только при смене состояния.
    $repeatRoot=Join-Path $work 'repeat-status';$script:VpnLoggedState=$null;$script:VpnLoggedWarning=$null
    Write-VpnStatus $repeatRoot $true $true 'on' $inventory 'ok';Write-VpnStatus $repeatRoot $true $true 'on' $inventory 'ok';Write-VpnStatus $repeatRoot $false $false 'error' $inventory 'x'
    $repeatLog=@([IO.File]::ReadAllLines((Join-Path $repeatRoot 'logs/vpn.log')))
    Assert ($repeatLog.Count -eq 3 -and $repeatLog[0].EndsWith(' on '+$ownerWarning) -and $repeatLog[1].EndsWith(' on') -and $repeatLog[2].EndsWith(' error '+$ownerWarning)) 'журнал VPN не дублирует одно предупреждение каждую секунду'
    # Проверка победителя на моках: обе половины IPv4/IPv6, в том числе равный чужой /1.
    & {
        $script:routeChecks=@();$script:foreignHalf=''
        function Get-NetRoute {param($InterfaceIndex,$ErrorAction)
            foreach($prefix in @('0.0.0.0/5','128.0.0.0/3','2000::/3','8000::/2')){[pscustomobject]@{InterfaceIndex=$InterfaceIndex;DestinationPrefix=$prefix}}
        }
        function Find-NetRoute {param($RemoteIPAddress,$ErrorAction)
            $script:routeChecks+=@($RemoteIPAddress)
            [pscustomobject]@{DestinationPrefix='mock';InterfaceIndex=$(if($RemoteIPAddress -eq $script:foreignHalf){9}else{4})}
        }
        Assert-VpnInternetRoutes $settings ([pscustomobject]@{ifIndex=4})
        Assert (($script:routeChecks -join ',') -eq '0.0.0.0,128.0.0.0,2000::,8000::') 'проверены обе IPv4 и IPv6 половины'
        foreach($foreign in @('0.0.0.0','128.0.0.0','2000::','8000::')){
            $script:foreignHalf=$foreign;$bad=$false
            try{Assert-VpnInternetRoutes $settings ([pscustomobject]@{ifIndex=4})}catch{$bad=$true}
            Assert $bad ('чужой победивший маршрут обнаружен: '+$foreign)
        }
    }
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
