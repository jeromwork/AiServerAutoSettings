#requires -Version 5.1
function Initialize-WizardSettingsProfile([string]$Root,$Request) {
    $data=$Request.data;if(-not $data){$data=Read-TransportJson ([string]$Request.path)}
    if($data.schema -ne 1 -or [string]$data.serverAddress -notmatch '\A[a-zA-Z0-9][a-zA-Z0-9.:-]{0,252}\z' -or [string]$data.workerUser -notmatch '\A[a-z_][a-z0-9_-]{0,31}\z'){throw 'Неверный профиль сервера'}
    $port=[int]$data.serverPort;if($port -lt 1 -or $port -gt 65535){throw 'Некорректный порт сервера'}
    $id=(Get-TransportFingerprint ([string]$data.serverAddress+':'+$port) ([string]$data.workerUser)).Substring(0,20)
    $hostId=[string]$Request.hostId;if(-not $hostId){$hostId=Get-WizardHostId $Root}
    if($hostId -cnotmatch '\A[a-z0-9][a-z0-9_-]{0,63}\z'){throw 'Неверный hostId компьютера'}
    $dir=Join-Path $Root ('ssh-profiles/'+$id+'/project-connections/'+$hostId)
    [void][IO.Directory]::CreateDirectory($dir);Protect-TransportPath $dir
    $p=[pscustomobject]@{sshExecutable=@(Get-Command ssh -CommandType Application -ErrorAction Stop)[0].Source;serverAddress=[string]$data.serverAddress;login=[string]$data.workerUser;keyPath=(Join-Path $dir 'id_ed25519');knownHostsPath=(Join-Path $dir 'known_hosts');configPath=(Join-Path $dir 'ssh.conf');strictHostKey=$true}
    $file=Join-Path $dir 'ssh-transport.json'
    Write-DiskUtf8 $p.configPath ("Host *`n    Port "+$port+"`n    ConnectTimeout 5`n")
    $hostName=if($port -eq 22){$p.serverAddress}else{'['+$p.serverAddress+']:'+$port}
    $pins=@();foreach($key in @($data.hostKeys)){
        if([string]$key -cnotmatch '\A(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+\z'){throw 'Некорректный ключ хоста в конфиге'}
        $pins+=($hostName+' '+$key);if($port -ne 22){$pins+=($p.serverAddress+' '+$key)}
    }
    if(-not $pins.Count){if(-not $Request.allowTrustOnFirstUse){throw 'Обновление не содержит ключей хоста'};$p.strictHostKey=$false}
    Write-DiskUtf8 $p.knownHostsPath (($pins -join "`n")+"`n")
    $p.keyPath=[string]$Request.keyPath
    if(-not $p.keyPath -or -not (Test-Path -LiteralPath $p.keyPath -PathType Leaf)){throw 'Материализуйте ключ server-key перед применением конфига'}
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'secrets'));Protect-TransportPath (Join-Path $Root 'secrets')
    $p|Add-Member -Force arguments @('-p',[string]$port)
    Write-TransportJson $file $p -Private
    return @{data=$data;profile=$p;file=$file}
}
function Connect-WizardSnapshot([string]$Root,$Request) {
    $prepared=Initialize-WizardSettingsProfile $Root $Request
    $data=$prepared.data;$p=$prepared.profile;$file=$prepared.file;$dir=Split-Path $file -Parent;$port=[int]$data.serverPort
    $ok=$false;$lastReason='Нет связи ни одним из маршрутов конфига';$chosenRequest=$null
    try{
        $all=@();$routeIndex=0
        foreach($route in @($data.routes)){
            $routeIndex++
            $r=[pscustomobject]@{askpassExecutable=[string]$Request.askpassExecutable;strictHostKey=[bool]$p.strictHostKey}
            if($route.kind -eq 'proxy'){$r|Add-Member proxy $route.proxy}
            elseif($route.kind -eq 'hop'){
                $hop=$route.hop.PSObject.Copy()
                if(-not $hop.hostKey){throw 'Нет ключа промежуточного сервера'}
                $hop|Add-Member -Force knownHostsPath (Join-Path $dir ('known_hosts-hop-'+$routeIndex))
                if($hop.privateKey){$hopKey=Join-Path $Root ('secrets/config-hop-'+$routeIndex);Write-DiskUtf8 $hopKey ([string]$hop.privateKey);Protect-TransportPath $hopKey;$hop|Add-Member -Force keyFile $hopKey}
                if($hop.password){
                    $m=[regex]::Match([string]$hop.ssh,'\A([a-z_][a-z0-9_-]{0,31})@([a-zA-Z0-9][a-zA-Z0-9.-]{0,252})(?::(\d{1,5}))?\z')
                    if(-not $m.Success){throw 'В конфиге нужен явный логин промежуточного сервера'}
                    $hopSettings=Join-Path $Root ('secrets/config-hop-'+$routeIndex+'.json')
                    Write-TransportJson $hopSettings @{askpassExecutable=[string]$Request.askpassExecutable;sshExecutable=$p.sshExecutable;configPath=$p.configPath;knownHostsPath=[string]$hop.knownHostsPath;host=$m.Groups[2].Value;port=$(if($m.Groups[3].Success){[int]$m.Groups[3].Value}else{22});user=$m.Groups[1].Value;password=[string]$hop.password} -Private
                    $hop|Add-Member -Force routePasswordFile $hopSettings
                }
                $r|Add-Member hop $hop
            }elseif($route.kind -ne 'direct'){throw 'Неизвестный маршрут конфига'}
            $variants=New-WizardRoutes $r $p;$variants=@($variants|Where-Object {$_.kind -eq $route.kind})
            foreach($variant in $variants){
                $config=Read-TransportJson (Join-Path $Root 'config.json')
                if($variant.kind -eq 'direct' -and $config.transport.bootstrap -and (Test-StatusFresh $Root vpn)){
                    $settings=Read-TransportSettings $Root;$address=(Get-VpnOptions $settings).probeAddress
                    $variant.options=@('-o',('HostName='+$address),'-o',('HostKeyAlias='+$p.serverAddress))
                }
                $variant.request=$r;$all+=$variant
            }
        }
        while($all.Count){
                if($Request.deferProof){$script:WizardRoute=$all[0]}
                else{Select-WizardRoute $p $p.login $all}
                $variant=$script:WizardRoute;$r=$variant.request
                $all=@($all|Where-Object {-not [object]::ReferenceEquals($_,$variant)})
                Write-WizardProgress ('Подключаюсь: '+$variant.title)
                # Resuming a lost reply is safe: first check this computer's own key.
                try{[void](Invoke-WizardLogin $p $p.login 'true');$ok=$true}catch{
                    if($_.Exception.Message -like '*Ключ хоста*'){throw}
                }
                if(-not $ok -and $Request.deferProof){$ok=$true}
                if($ok){$chosenRequest=$r;break}
        }
        if(-not $ok){throw $lastReason}
        if(-not $p.strictHostKey){
            $target=if($port -eq 22){$p.serverAddress}else{'['+$p.serverAddress+']:'+$port}
            $verified=@(Get-TransportHostKeys $p.sshExecutable $target $p.knownHostsPath)
            if(-not $verified.Count){throw 'Первый SSH-вход не закрепил ключ хоста'}
            $lines=@();foreach($pin in $verified){$lines+=($target+' '+$pin);if($port -ne 22){$lines+=($p.serverAddress+' '+$pin)}}
            Write-DiskUtf8 $p.knownHostsPath (($lines -join "`n")+"`n");$p.strictHostKey=$true
        }
        $proxyOption=@($script:WizardRoute.options|Where-Object {$_ -like 'ProxyCommand=*'})
        if($proxyOption.Count){$p|Add-Member routeProxyCommand ($proxyOption[0].Substring(13))}
        $p|Add-Member -Force arguments (@('-F',$p.configPath,'-p',[string]$port,'-l',$p.login,'-i',$p.keyPath,'-o','IdentitiesOnly=yes','-o',('UserKnownHostsFile="'+$p.knownHostsPath.Replace('\','/')+'"'),'-o','GlobalKnownHostsFile=none','-o','StrictHostKeyChecking=yes','-o','BatchMode=yes','-o','ForwardAgent=no')+@($script:WizardRoute.options)+@('-T',$p.serverAddress))
        Write-TransportJson $file $p -Private
        Save-WizardRoute $Root $chosenRequest $p
        Update-LauncherConfig $Root {param($c) Set-ConfigDefault $c transport ([pscustomobject]@{});$c.transport|Add-Member -Force profilePath $file}
        return @{ok=$true;profile=$file;summary='Вход ключом конфига проверен'}
    }finally{$script:WizardRoute=$null}
}
function Connect-WizardProfileAccount([string]$Root,[string]$Bundle,$Request) {
    $rows=@((Invoke-WizardStep $Root $Bundle 'AccountList' ([pscustomobject]@{})).accounts)
    if($Request.account){$rows=@($rows|Where-Object {$_.account -ceq [string]$Request.account})}
    if($rows.Count -ne 1){throw 'На сервере несколько аккаунтов Happier или нет аккаунта. Администратору: задайте happier.account в конфиге'}
    $row=$rows[0]
    if($Request.mode -eq 'same'){
        $body=@{action='inspect';account=[string]$row.account}|ConvertTo-Json -Compress
        $status=ConvertFrom-Json (Convert-TransportLF (Invoke-WizardSsh $Root 'export PATH="$HOME/.local/share/remoteagents-accounts/node:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"; node "$HOME/.local/share/remoteagents-accounts/server-account.mjs"' $body))
        if(-not $status.ok){throw 'Happier на сервере не подтвердил работу выбранного аккаунта'}
        # Same workstation: the existing server daemon and its subscriptions are reused.
        # No recovery secret exists on the server and none needs to travel to the PC.
        $row|Add-Member -Force ok $true;$row|Add-Member -Force updatedUtc ([DateTime]::UtcNow.ToString('o'))
        Write-TransportJson (Join-Path $Root 'state/happier-account.json') $row
        Update-LauncherConfig $Root {param($c) $c|Add-Member -Force happier ([pscustomobject]@{label=[string]$row.label;serverUrl=[string]$row.serverUrl;webappUrl=[string]$row.webappUrl})}
        return @{ok=$true;summary='Существующий аккаунт Happier проверен'}
    }
    if([string]$Request.mode -notlike 'new:*'){throw 'Некорректный выбор Happier'}
    return Invoke-WizardAccount $Root $Bundle ([pscustomobject]@{label=([string]$Request.mode).Substring(4);serverUrl=[string]$row.serverUrl;webappUrl=[string]$row.webappUrl;expectedAccount=''}) $true
}

function Start-WizardBootstrap([string]$Root,[string]$Bundle,$Request) {
    $config=Read-TransportJson (Join-Path $Root 'config.json');$initial=$config.profile.vpn.bootstrap
    if(Test-WizardNetworkManaged $Root){return @{ok=$true;skipped=$true;vpn='unchanged';summary='Начальный VPN пропущен: сохранена действующая конфигурация'}}
    if(-not $initial){return @{ok=$true;vpn='off';summary='Начальный VPN не задан'}}
    try{
        $conflict=Get-WizardBootstrapVpnConflict $Root $Bundle
        if($conflict.conflict){return @{ok=$false;vpn='conflict';summary='Работает другой VPN; отключите его перед начальной настройкой';found=[string]$conflict.processHints}}
        $t=Copy-TransportObject $config.transport
        if(-not $t){$t=[pscustomobject]@{}}
        if(-not $t.profilePath){
            $s=$config.profile.server
            $data=[pscustomobject]@{schema=1;serverAddress=$s.address;serverPort=$(if($s.port){[int]$s.port}else{22});workerUser=$s.login;hostKeys=@($s.hostKeys)}
            $key=[string]$s.keyFile;if(-not $key){$key=[string]$s.keyPath};if(-not $key){$key=Join-Path $Root 'secrets/server-key'}
            $prepared=Initialize-WizardSettingsProfile $Root ([pscustomobject]@{data=$data;keyPath=$key;allowTrustOnFirstUse=$true})
            $t|Add-Member -Force profilePath $prepared.file
        }
        if($initial.catalog){
            Assert-WizardCatalog $initial.catalog
            foreach($g in @('entries','hops','relays','cdn')){$t|Add-Member -Force $g @($initial.catalog.$g|Where-Object {$null -ne $_})}
        }
        $channel=Join-Path $Root 'secrets/channel.json'
        if(-not (Test-Path $channel)){throw 'Материализуйте vpn.bootstrap.channel перед Bootstrap'}
        $t|Add-Member -Force channelPath $channel
        if(-not $t.singBoxPath){$t|Add-Member -Force singBoxPath (Join-Path $Root 'transport-bin/sing-box.exe')}
        if(-not (Test-Path $t.singBoxPath)){throw 'Для Bootstrap нужна локальная программа sing-box'}
        $t|Add-Member -Force bootstrap $true;$t|Add-Member -Force openSsh $false
        Update-LauncherConfig $Root {param($c)
            $c|Add-Member -Force transport $t
            Set-ConfigDefault $c vpn ([pscustomobject]@{enabled=$false})
            foreach($field in @('checkUrl','dnsServer')){if($c.profile.vpn.$field){$c.vpn|Add-Member -Force $field $c.profile.vpn.$field}}
        }
        $tag=Select-WizardBootstrapInternetPath $Root
        Update-LauncherConfig $Root {param($c) $c.vpn|Add-Member -Force bootstrapTag $tag}
        Set-VpnEnabled $Root $true
        Start-WizardBootstrapTun $Root $Bundle ([int]$Request.parentPid)
        $state=Wait-WizardBootstrapTun $Root
        if($state -ne 'on'){Set-VpnEnabled $Root $false}
        return @{ok=($state -eq 'on');vpn=$state;summary=$(if($state -eq 'on'){'Начальный VPN проверен до SSH'}else{'Начальный VPN не подтверждён; доступны обычные SSH-маршруты'})}
    }catch{
        Write-SetupLog $Root 'bootstrap.vpn.unavailable'
        Set-VpnEnabled $Root $false
        return @{ok=$false;vpn='unavailable';summary='Начальный VPN не поднят; проверьте локальную программу и данные конфига, затем повторите'}
    }
}
function Get-WizardBootstrapVpnConflict([string]$Root,[string]$Bundle) {
    ConvertFrom-Json (& (Join-Path $Bundle 'transport/Test-VpnConflict.ps1') -Home $Root|Out-String)
}
function Start-WizardBootstrapTun([string]$Root,[string]$Bundle,[int]$ParentPid=0) {
    Invoke-InstallChild $Bundle 'transport/Vpn.Tun.ps1' @('-Home',$Root,'-Enable','-ParentPid',[string]$ParentPid) -TimeoutSeconds 420
}
function Wait-WizardBootstrapTun([string]$Root) {
    for($n=0;$n -lt 60;$n++){
        $file=Join-Path $Root 'status/vpn.json'
        if(Test-Path $file){$status=Read-TransportJson $file;if($status.state -in @('error','conflict','rolled-back')){return [string]$status.state};if((Test-StatusFresh $Root vpn) -and $status.state -eq 'on'){return 'on'}}
        Start-Sleep -Seconds 1
    }
    return 'unconfirmed'
}
function Select-WizardBootstrapInternetPath([string]$Root) {
    $settings=Read-TransportSettings $Root;$paths=Get-TransportCandidates $settings $Root
    foreach($candidate in @($paths.Candidates)){
        if(-not (Test-TransportInternetPath $candidate.tag $paths.Outbounds)){continue}
        if(Test-WizardBootstrapInternetPath $Root $settings $paths $candidate.tag){return [string]$candidate.tag}
    }
    throw 'Нет пути с проверенным HTTPS для начального VPN'
}
function Test-WizardBootstrapInternetPath([string]$Root,$Settings,$Paths,[string]$Tag) {
    $socket=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$socket.Start();$port=$socket.LocalEndpoint.Port;$socket.Stop()
    $net=Get-TransportNetwork;$exclude=@();$cfg=New-VpnTunConfig $Settings $Paths $Tag $exclude $net.interface
    # Preflight uses only a loopback HTTP proxy. No network routes before TUN/watchdog.
    $cfg.inbounds=@(@{type='http';tag='bootstrap-check';listen='127.0.0.1';listen_port=$port})
    $file=Join-Path $Root 'state/bootstrap-internet-check.json';$child=$null
    try {
        Write-TransportJson $file $cfg -Private;Test-TransportConfigFile $Settings.Options.singBoxPath $file
        $child=Start-TransportProcess $Settings.Options.singBoxPath @('run','-c',$file)
        Start-Sleep -Milliseconds 500
        $uri=[Uri](Get-VpnOptions $Settings).checkUrl
        $req=[Net.HttpWebRequest]::Create($uri);$req.Proxy=New-Object Net.WebProxy('http://127.0.0.1:'+$port);$req.Timeout=10000;$req.AllowAutoRedirect=$false
        $response=$req.GetResponse();try{return ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300)}finally{$response.Dispose()}
    }catch{return $false}finally{Stop-TransportProcess $child}
}
function Connect-WizardProfileServer([string]$Root,$Request) {
    $config=Read-TransportJson (Join-Path $Root 'config.json');$server=$config.profile.server
    $key=[string]$server.keyFile;if(-not $key){$key=[string]$server.keyPath};if(-not $key){$key=Join-Path $Root 'secrets/server-key'}
    if(-not $server){return $null}
    if(-not (Test-Path -LiteralPath $key -PathType Leaf)){
        if($server.key){throw 'Материализуйте ключ server-key перед Server; новый ключ вместо выданного не создаётся'}
        return $null
    }
    $routes=@($server.routes|Where-Object {$null -ne $_});if(-not $routes.Count){$routes=@([pscustomobject]@{kind='direct'})}
    $data=[pscustomobject]@{schema=1;serverAddress=[string]$server.address;serverPort=$(if($server.port){[int]$server.port}else{22});workerUser=[string]$server.login;hostKeys=@($server.hostKeys);routes=$routes}
    $request=[pscustomobject]@{data=$data;keyPath=$key;allowTrustOnFirstUse=$true;askpassExecutable=[string]$Request.askpassExecutable}
    # Keep the issued key: adding another key would defeat config revoke.
    return (Connect-WizardSnapshot $Root $request).profile
}
