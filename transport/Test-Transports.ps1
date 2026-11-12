#requires -Version 5.1
<#
Параллельная проверка путей до сервера. Каждый путь ведёт к SSH сервера (127.0.0.1:22 на сервере),
по нему скачивается поток случайных байт. Фаза 1 — все пути одновременно, несколько секунд и мегабайт
на путь: ТСПУ часто пропускает первые килобайты и потом «замораживает», поэтому ход пишется по секундам.
Фаза 2 — скорость каждого живого пути по очереди, без разделения канала.
Ничего постоянного не меняет: временный sing-box и SSH-пробросы закрываются в finally.
#>
param(
    [string[]]$Relays=@(),   # простые ретрансляторы: host:port -> сервер:443 без расшифровки
    [string[]]$Hops=@(),               # SSH-алиасы промежуточных серверов (~/.ssh/config)
    [string[]]$Entries=@(),            # SSH-алиасы узлов с install-entry.sh: параметры берутся из /opt/rd-entry/client.json
    [int]$ProbeBytes=2000000,                   # путь жив, если докачал столько без остановки
    [int]$ProbeSeconds=25,
    [int]$StallSeconds=5,                       # после первого байта нет новых байт столько секунд — путь заморожен
    [int]$AliveBytes=524288,                    # в общем канале путь жив, если набрал столько и не встал
    [int]$SpeedBytes=6000000,                   # потолок трафика на путь в фазе скорости (на мобильном уменьшать)
    [int]$SpeedSeconds=10,
    [string[]]$Only=@(),                        # проверить только эти пути (маски, например 'ws-*')
    [string]$OutFile='',
    [Alias('Home')][string]$TransportHome=(Join-Path $env:LOCALAPPDATA 'RemoteAgents')
)
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$home_=$TransportHome
$settings=(Read-TransportJson (Join-Path $home_ 'config.json')).transport
if(-not $settings.profilePath -or -not $settings.channelPath -or -not $settings.singBoxPath){throw 'Нет transport.profilePath, channelPath или singBoxPath в config.json: сначала пройдите шаг «Связь» мастера'}
$singbox=[string]$settings.singBoxPath
$profPath=[string]$settings.profilePath
$prof=[IO.File]::ReadAllText($profPath)|ConvertFrom-Json
$server=$prof.serverAddress
$work=Join-Path $env:TEMP ('rd-transports-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($work);Protect-TransportPath $work

function Q([string]$v){Quote-Transport $v}
$sshBase=@(Get-TransportSshArguments $prof (Get-TransportServerPort $prof))
$fwdBase=$sshBase
$key=$prof.keyPath
$wifi=$null
try{$r=Find-NetRoute -RemoteIPAddress $server -ErrorAction Stop|Select-Object -First 1;$def=Get-NetRoute -DestinationPrefix '0.0.0.0/0'|Sort-Object {$_.RouteMetric+(Get-NetIPInterface -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4).InterfaceMetric}|Where-Object {(Get-NetAdapter -InterfaceIndex $_.InterfaceIndex).InterfaceDescription -notmatch 'TUN|Tunnel|TAP|Wintun|OpenVPN|Tailscale|Hyper-V'}|Select-Object -First 1;$wifi=(Get-NetIPAddress -InterfaceIndex $def.InterfaceIndex -AddressFamily IPv4|Select-Object -First 1).IPAddress}catch{}

# Пути через sing-box: исходящие берутся из действующего канала, ретрансляторы и прыжки добавляются.
$channel=Read-TransportJson ([string]$settings.channelPath)
$vless=$channel.outbounds|Where-Object {$_.type -eq 'vless'}|Select-Object -First 1
function Copy-Out($o){$o|ConvertTo-Json -Depth 20|ConvertFrom-Json}
$out=@();$paths=[ordered]@{};$port=25000
$v=Copy-Out $vless;$v.tag='vless-direct';$v.server=$server;$v.server_port=443;if($v.PSObject.Properties['detour']){$v.PSObject.Properties.Remove('detour')};$out+=$v;$paths['vless-direct']=@{kind='singbox';port=++$port}
foreach($relay in $Relays){$h,$p=$relay.Split(':');$t=Copy-Out $v;$t.tag="vless-relay-$h";$t.server=$h;$t.server_port=[int]$p;$out+=$t;$paths[$t.tag]=@{kind='singbox';port=++$port}}
foreach($hop in $Hops){
    $g=@{};foreach($line in (& $prof.sshExecutable -n -G $hop)){if($line -match '^(hostname|user|identityfile|port) (.+)$' -and -not $g.ContainsKey($Matches[1])){$g[$Matches[1]]=$Matches[2]}}
    $hk=$g.identityfile -replace '^~',$env:USERPROFILE
    $known=Join-Path $env:USERPROFILE '.ssh/known_hosts';$hostName=$g.hostname
    if([int]$g.port -ne 22){$hostName='['+$hostName+']:'+$g.port}
    $sshHop=[pscustomobject]@{type='ssh';tag="hop-$hop";server=$g.hostname;server_port=[int]$g.port;user=$g.user;private_key_path=$hk;host_key=@(Get-TransportHostKeys $prof.sshExecutable $hostName $known)}
    Set-TransportHostKeyAlgorithms $sshHop;$out+=$sshHop
    $t=Copy-Out $v;$t.tag="vless-sshhop-$hop";$t|Add-Member detour "hop-$hop";$out+=$t;$paths[$t.tag]=@{kind='singbox';port=++$port}
}
foreach($entry in $Entries){
    $cj=& ssh.exe -n -o BatchMode=yes -o ConnectTimeout=10 $entry 'cat /opt/rd-entry/client.json' 2>$null
    if(-not $cj){Write-Output "Узел ${entry}: нет client.json, пропущен";continue}
    $e=($cj -join '')|ConvertFrom-Json;$x=$e.secrets;$h=$e.server;$t=@{enabled=$true;server_name=$e.sni;insecure=[bool]$e.insecure}
    $list=@(
        [pscustomobject]@{type='hysteria2';tag="hy2-$entry";server=$h;server_port=$e.ports.hy2;password=$x.hy2;tls=($t+@{alpn=@('h3')})},
        [pscustomobject]@{type='hysteria2';tag="hy2obfs-$entry";server=$h;server_port=$e.ports.hy2_obfs;password=$x.hy2;obfs=@{type='salamander';password=$x.hy2_obfs};tls=($t+@{alpn=@('h3')})},
        [pscustomobject]@{type='tuic';tag="tuic-$entry";server=$h;server_port=$e.ports.tuic;uuid=$x.tuic_uuid;password=$x.tuic;congestion_control='bbr';tls=($t+@{alpn=@('h3')})},
        [pscustomobject]@{type='trojan';tag="trojan-$entry";server=$h;server_port=$e.ports.trojan;password=$x.trojan;tls=$t},
        [pscustomobject]@{type='vless';tag="reality-$entry";server=$h;server_port=$e.ports.reality;uuid=$x.vless_uuid;flow='xtls-rprx-vision';tls=@{enabled=$true;server_name=$e.cover;utls=@{enabled=$true;fingerprint='chrome'};reality=@{enabled=$true;public_key=$x.reality_public;short_id=$x.short_id}}},
        [pscustomobject]@{type='shadowsocks';tag="shadowtls-$entry";method='2022-blake3-aes-128-gcm';password=$x.ss;detour="stls-$entry"}
    )
    if($x.ws_path){
        $ws=@{type='ws';path=$x.ws_path;max_early_data=2048;early_data_header_name='Sec-WebSocket-Protocol'}
        $dom=if($e.domain){$e.domain}else{$e.sni}
        $list+=[pscustomobject]@{type='vless';tag="ws-direct-$entry";server=$h;server_port=443;uuid=$x.ws_uuid;tls=@{enabled=$true;server_name=$dom;insecure=$true;alpn=@('http/1.1');utls=@{enabled=$true;fingerprint='chrome'}};transport=($ws+@{headers=@{Host=$dom}})}
        if($e.domain -and (Resolve-DnsName $e.domain -Type A -ErrorAction SilentlyContinue)){
            $list+=[pscustomobject]@{type='vless';tag="ws-cdn-$entry";server=$e.domain;server_port=443;uuid=$x.ws_uuid;tls=@{enabled=$true;server_name=$e.domain;alpn=@('http/1.1');utls=@{enabled=$true;fingerprint='chrome'}};transport=($ws+@{headers=@{Host=$e.domain}})}
        } elseif($e.domain){Write-Output "Узел ${entry}: $($e.domain) не резолвится, путь через CDN пропущен"}
    }
    $out+=[pscustomobject]@{type='shadowtls';tag="stls-$entry";server=$h;server_port=$e.ports.shadowtls;version=3;password=$x.shadowtls;tls=@{enabled=$true;server_name=$e.cover;utls=@{enabled=$true;fingerprint='chrome'}}}
    foreach($o in $list){$out+=$o;$paths[$o.tag]=@{kind='singbox';port=++$port}}
}
$sd=$channel.outbounds|Where-Object {$_.type -eq 'ssh' -and $_.server -eq $server}|Select-Object -First 1
if(-not $sd){$sd=[pscustomobject]@{type='ssh';tag='';server=$server;server_port=22;user=$prof.login;private_key_path=$key}}
$sd=Copy-Out $sd;if(-not $sd.host_key){$sd|Add-Member -Force host_key @(Get-TransportHostKeys $prof.sshExecutable $server $prof.knownHostsPath)};Set-TransportHostKeyAlgorithms $sd;$sd.tag='singbox-ssh-direct';$out+=$sd;$paths['singbox-ssh-direct']=@{kind='singbox';port=++$port}
$paths['openssh-direct']=@{kind='openssh';port=++$port;extra=@(@('-o','ProxyCommand=none')+@(if($wifi){'-b',$wifi}))}
foreach($hop in $Hops){$proxy=(@($prof.sshExecutable,'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-W','%h:%p',$hop)|ForEach-Object {Q $_}) -join ' ';$paths["openssh-jump-$hop"]=@{kind='openssh';port=++$port;extra=@();proxy=('ProxyCommand='+$proxy)}}
if($Only){foreach($k in @($paths.Keys)){if(-not ($Only|Where-Object{$k -like $_})){$paths.Remove($k)}}}

$procs=New-Object Collections.ArrayList
function Start-Bg($exe,[string[]]$a,$stdout=$null){
    $child=Start-TransportProcess $exe $a -Probe;[void]$procs.Add($child)
    $p=$child.Process;$sink=if($stdout){[IO.File]::Create($stdout)}else{[IO.Stream]::Null}
    $copy=$p.StandardOutput.BaseStream.CopyToAsync($sink)
    [pscustomobject]@{Child=$child;P=$p;Sink=$sink;Copy=$copy;File=$stdout;Final=0}
}
function Stop-Bg($b){Stop-TransportProcess $b.Child;try{[void]$b.Copy.Wait(1000)}catch{};try{$b.Final=$b.Sink.Length}catch{};$b.Sink.Dispose()}
function Get-Len($b){if($b -is [string]){if(Test-Path -LiteralPath $b){return (Get-Item -LiteralPath $b).Length};return 0};try{$b.Sink.Length}catch{$b.Final}}
function Start-Download($name,$bytes){
    $f=Join-Path $work "$name.bin"
    Start-Bg $prof.sshExecutable (@(Get-TransportSshArguments $prof ([int]$paths[$name].port))+@('127.0.0.1',"head -c $bytes /dev/urandom")) $f
}

$results=[ordered]@{}
try {
    $inb=@();$rules=@()
    foreach($k in @($paths.Keys)){if($paths[$k].kind -eq 'singbox'){$inb+=[pscustomobject]@{type='direct';tag="in-$k";listen='127.0.0.1';listen_port=$paths[$k].port;network='tcp';override_address='127.0.0.1';override_port=22};$rules+=[pscustomobject]@{inbound=@("in-$k");outbound=$k}}}
    $sbLog=Join-Path $work 'sing-box.log'
    $cfg=[pscustomobject]@{log=@{disabled=$true};inbounds=$inb;outbounds=$out;route=[pscustomobject]@{rules=$rules;final='vless-direct';auto_detect_interface=$true}}
    $cfgFile=Join-Path $work 'probe.json';Write-TransportJson $cfgFile $cfg -Private;Test-TransportConfigFile $singbox $cfgFile
    $null=Start-Bg $singbox @('run','-c',$cfgFile)
    foreach($k in @($paths.Keys)){if($paths[$k].kind -eq 'openssh'){$base=@($fwdBase);if($paths[$k].proxy){$base=@($base|ForEach-Object {if($_ -eq 'ProxyCommand=none'){$paths[$k].proxy}else{$_}})};$null=Start-Bg $prof.sshExecutable (@($base)+$paths[$k].extra+@('-N','-L',"127.0.0.1:$($paths[$k].port):127.0.0.1:22",$server))}}
    Start-Sleep -Seconds 5

    Write-Output ("Фаза 1: все {0} путей одновременно, до {1:N1} МБ за {2} с на путь" -f $paths.Count,($ProbeBytes/1MB),$ProbeSeconds)
    $dl=@{};$trace=@{};$last=@{};$lastAt=@{};$okAt=@{};$frozen=@{}
    foreach($k in @($paths.Keys)){$dl[$k]=Start-Download $k $ProbeBytes;$trace[$k]=New-Object Collections.ArrayList;$last[$k]=0;$lastAt[$k]=$null}
    $sw=[Diagnostics.Stopwatch]::StartNew();$tick=0
    while($sw.Elapsed.TotalSeconds -lt $ProbeSeconds -and ($okAt.Count+$frozen.Count) -lt $paths.Count){
        Start-Sleep -Milliseconds 250;$now=$sw.Elapsed.TotalSeconds
        foreach($k in @($paths.Keys)){
            if($okAt.ContainsKey($k) -or $frozen.ContainsKey($k)){continue}
            $n=Get-Len $dl[$k]
            if($n -gt $last[$k]){$last[$k]=$n;$lastAt[$k]=$now}
            if($n -ge $ProbeBytes){$okAt[$k]=$now}elseif($null -ne $lastAt[$k] -and $now-$lastAt[$k] -ge $StallSeconds){$frozen[$k]=$n}
        }
        if([int]$now -gt $tick){$tick=[int]$now;if($tick -in 1,3,6,10,15,20){foreach($k in @($paths.Keys)){[void]$trace[$k].Add(('{0}с:{1}' -f $tick,[int]((Get-Len $dl[$k])/1KB)))}}}
    }
    foreach($k in @($paths.Keys)){
        $got=Get-Len $dl[$k];Stop-Bg $dl[$k];$e='Путь не прошёл SSH-пробу'
        $stillFlowing=($null -ne $lastAt[$k]) -and ($sw.Elapsed.TotalSeconds-$lastAt[$k] -lt $StallSeconds)
        $state=if($okAt.ContainsKey($k)){'ok'}elseif($frozen.ContainsKey($k)){'frozen'}elseif($got -ge $AliveBytes -and $stillFlowing){'ok'}elseif($got -gt 0 -and $stillFlowing){'slow'}elseif($got -gt 0){'frozen'}else{'fail'}
        if($state -in @('ok','slow')){$e=$null}
        $results[$k]=[pscustomobject][ordered]@{path=$k;alive=($state -in 'ok','slow');state=$state;probeSeconds=if($okAt.ContainsKey($k)){[math]::Round($okAt[$k],1)}else{$null};probeBytes=$got;trace=($trace[$k] -join ' ');error=$e;kbps=$null}
    }
    foreach($r in $results.Values){
        $label=switch($r.state){'ok'{if($r.probeSeconds){"OK: {0:N1} МБ за {1} с" -f ($ProbeBytes/1MB),$r.probeSeconds}else{"OK: {0:N0} КБ, поток идёт" -f ($r.probeBytes/1KB)}}'frozen'{"ЗАМЁРЗ на {0:N0} КБ" -f ($(if($frozen.ContainsKey($r.path)){$frozen[$r.path]}else{$r.probeBytes})/1KB)}'slow'{"медленно: {0:N0} КБ, но идёт" -f ($r.probeBytes/1KB)}default{"НЕТ {0}" -f $r.error}}
        Write-Output ("  {0,-24} {1,-28} [{2} КБ]" -f $r.path,$label,$r.trace)
    }

    Write-Output ("Фаза 2: скорость живых путей по очереди, по {0} с" -f $SpeedSeconds)
    foreach($r in @($results.Values|Where-Object {$_.alive})){
        $probe=Start-TransportProbe $prof ([pscustomobject]@{tag=$r.path;port=$paths[$r.path].port}) $SpeedBytes @{stallSeconds=$StallSeconds;probeTimeoutSec=$SpeedSeconds} 'diagnostic'
        try{
            while(-not (Receive-TransportProbe $probe)){Start-Sleep -Milliseconds 100}
            $r.kbps=$probe.state.kbps
        }finally{Stop-TransportProbe $probe}
        $value='не измерена';if($null -ne $r.kbps){$value=('{0:N0} КБ/с' -f $r.kbps)}
        Write-Output ("  {0,-26} {1}" -f $r.path,$value)
    }
    $best=$results.Values|Where-Object {$_.alive}|Sort-Object kbps -Descending|Select-Object -First 1
    Write-Output ("Лучший сейчас: {0}" -f $(if($best){"$($best.path) ($($best.kbps) КБ/с)"}else{'нет живых путей'}))
    $report=[ordered]@{at=(Get-Date).ToString('o');localIp=$wifi;results=@($results.Values);best=if($best){$best.path}else{$null}}
    if(-not $OutFile){$OutFile=Join-Path $home_ 'transport-test.json'};[IO.File]::WriteAllText($OutFile,($report|ConvertTo-Json -Depth 5))
    Write-Output "Отчёт: $OutFile"
}
finally{foreach($p in $procs){Stop-TransportProcess $p};Start-Sleep -Milliseconds 500;Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
