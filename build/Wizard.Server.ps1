#requires -Version 5.1
# setup-vps-ssh.ps1 creates the OpenSSH key and profile; the wizard supplies a one-use in-memory askpass.
function Write-WizardProgress([string]$Text) {
    if($script:WizardProgressFile){[IO.File]::AppendAllText($script:WizardProgressFile,((@{text=$Text}|ConvertTo-Json -Compress)+"`n"),(New-Object Text.UTF8Encoding($false)))}
}
# Messages and detection for a server that accepts TCP but never answers SSH (typically a provider filter).
$script:WizardNoBannerPattern='banner exchange|kex_exchange_identification|Connection closed|Connection reset|timed out'
$script:WizardNoBannerText='Сервер не ответил по SSH: похоже, провайдер блокирует прямое подключение. Включите любой VPN в режиме TUN (OpenVPN, WireGuard…) и нажмите «Повторить» либо укажите в списке «Как подключаться» локальный прокси (например, Happ в режиме «Смешанный») или промежуточный SSH-сервер. Режим «смешанный» (только прокси) ssh сам не проводит: для него нужен маршрут «Локальный прокси»'
$script:WizardRoute=$null;$script:WizardNoBanner=$false;$script:WizardReached=$false
function Get-WizardHopKeys([string]$Chosen) {
    # The hop key is the chosen file, otherwise the user's standard OpenSSH keys. Only paths are used; contents are never read.
    if($Chosen){if($Chosen.EndsWith('.pub',[StringComparison]::OrdinalIgnoreCase)){$Chosen=$Chosen.Substring(0,$Chosen.Length-4)};return @($Chosen)}
    $userHome=if($env:USERPROFILE){$env:USERPROFILE}else{$HOME}
    @('id_ed25519','id_ecdsa','id_rsa')|ForEach-Object {Join-Path (Join-Path $userHome '.ssh') $_}|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf}
}
function New-WizardRoutes($Request,$Profile) {
    # Routes in order: direct, local proxy (SOCKS5/HTTP, via this exe's --proxy-connect), SSH hop (pass-through; the target login keeps the target's own key).
    # Saved route data (Save-WizardRoute) reuses the transport hops[] field names: name, ssh, hostKey.
    $routes=@(@{kind='direct';title='напрямую';options=@()})
    $px=$Request.proxy
    if($px -and $px.host){
        $port=0;if(([string]$px.type -notin @('socks','http')) -or -not ([string]$px.host -match '\A[a-zA-Z0-9][a-zA-Z0-9.:-]{0,252}\z') -or -not [int]::TryParse([string]$px.port,[ref]$port) -or $port -lt 1 -or $port -gt 65535){throw 'Укажите корректный адрес и порт прокси'}
        $cmd=(Quote-Disk ([string]$Request.askpassExecutable))+' --proxy-connect '+$px.type+' '+$px.host+' '+$port+' %h %p'
        $routes+=@{kind='proxy';title=('через локальный прокси '+$px.host+':'+$port);options=@('-o',('ProxyCommand='+$cmd))}
    }
    $hop=$Request.hop
    if($hop -and $hop.ssh){
        $m=[regex]::Match([string]$hop.ssh,'\A(?:([a-z_][a-z0-9_-]{0,31})@)?([a-zA-Z0-9][a-zA-Z0-9.-]{0,252})(?::(\d{1,5}))?\z')
        if(-not $m.Success){throw 'Укажите промежуточный сервер как логин@адрес[:порт]'}
        $known=(Join-Path (Split-Path $Profile.knownHostsPath -Parent) 'known_hosts-hop').Replace('\','/')
        if($Request.strictHostKey){
            if([string]$hop.hostKey -cnotmatch '\A(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+\z'){throw 'Ключ хоста промежуточного сервера отсутствует или повреждён'}
            $hopPort=if($m.Groups[3].Success){[int]$m.Groups[3].Value}else{22};$hopHost=$m.Groups[2].Value
            if($hopPort -ne 22){$hopHost='['+$hopHost+']:'+$hopPort}
            Write-DiskUtf8 $known ($hopHost+' '+$hop.hostKey+"`n")
        }
        $keys=@(Get-WizardHopKeys ([string]$hop.keyFile));if(-not $keys.Count -and -not $hop.passwordPipe){$keys=@('')}
        # Key routes first (BatchMode), then one password route. The password never appears here: the inner ssh asks this exe (askpass)
        # for it through the one-use in-memory pipe, whose random name is set only for that inner ssh (cmd `set`), so the target's own prompts keep their own pipe.
        $pipe=[string]$hop.passwordPipe;if($pipe -and ($pipe -notmatch '\ARemoteAgents\.Password\.[0-9a-f]{32}\z' -or ([string]$Request.askpassExecutable).Contains('"'))){throw 'Некорректный канал пароля промежуточного сервера'}
        $variants=@($keys|ForEach-Object {@{key=$_;password=$false}});if($pipe){$variants+=@{key='';password=$true}}
        foreach($v in $variants){
            # -q: a hop-side failure stays silent, so only the target's own answer reads as "reached".
            $t=@((Quote-Disk $Profile.sshExecutable),'-q','-F',(Quote-Disk $Profile.configPath))
            if($v.key){$t+=@('-i',(Quote-Disk $v.key),'-o','IdentitiesOnly=yes')}
            if($v.password){$t+=@('-o','BatchMode=no','-o','NumberOfPasswordPrompts=1','-o','PreferredAuthentications=password,keyboard-interactive','-o','KbdInteractiveAuthentication=yes','-o','PubkeyAuthentication=no')}else{$t+=@('-o','BatchMode=yes')}
            $hopStrict=if($Request.strictHostKey){'StrictHostKeyChecking=yes'}else{'StrictHostKeyChecking=accept-new'}
            $t+=@('-o','ConnectTimeout=8','-o',$hopStrict,'-o',('UserKnownHostsFile="'+$known+'"'),'-o','GlobalKnownHostsFile=none','-o','ForwardAgent=no')
            if($m.Groups[1].Success){$t+=@('-l',$m.Groups[1].Value)};if($m.Groups[3].Success){$t+=@('-p',$m.Groups[3].Value)}
            $t+=@('-W','%h:%p',$m.Groups[2].Value)
            $line=$t -join ' '
            if($v.password){$line='set "SSH_ASKPASS='+[string]$Request.askpassExecutable+'"&& set "SSH_ASKPASS_REQUIRE=force"&& set "DISPLAY=remoteagents:0"&& set "REMOTEAGENTS_PASSWORD_PIPE='+$pipe+'"&& '+$line}
            $routes+=@{kind='hop';title=('через промежуточный сервер '+$hop.ssh+$(if($v.password){' (пароль)'}else{''}));key=$v.key;options=@('-o',('ProxyCommand='+$line))}
        }
    }
    ,$routes
}
function Select-WizardRoute($Profile,[string]$Worker,$Routes) {
    # With only the direct route nothing is probed. Otherwise each route gets a short probe (8 s) and the first that reaches SSH wins.
    $script:WizardRoute=$Routes[0];$script:WizardNoBanner=$false;$script:WizardReached=$false
    if($Routes.Count -lt 2){return}
    foreach($r in $Routes){
        $script:WizardRoute=$r;$why='';$ok=$false
        Write-WizardProgress ('Проверяю: '+$r.title+'…')
        try{[void](Invoke-WizardLogin $Profile $Worker 'true' -Timeout 20);$ok=$true}catch{$e=[string]$_.Exception.Message;if($e -like '*Сервер отклонил вход*'){$ok=$true}else{$why=if($e -like '*баннер*'){'сервер не ответил по SSH'}else{'нет связи'}}}
        if($ok){Write-WizardProgress ('Проверяю: '+$r.title+'… ✓');$script:WizardReached=$true;return}
        Write-WizardProgress ('Проверяю: '+$r.title+'… ✗ '+$why)
    }
    $script:WizardNoBanner=$true;throw 'Сервер не ответил по SSH ни одним из способов (напрямую, через прокси, через промежуточный сервер). Проверьте прокси и промежуточный сервер или включите любой VPN в режиме TUN (OpenVPN, WireGuard…) и нажмите «Повторить». Режим «смешанный» (только прокси) ssh сам не проводит: для него нужен маршрут «Локальный прокси»'
}
function Save-WizardRoute([string]$Root,$Request,$Profile) {
    # Non-secret fields only (the key is a path). hop uses the transport hops[] names: name, ssh, hostKey.
    $r=$script:WizardRoute;$route=[ordered]@{used=[string]$r.kind}
    if($Request.proxy -and $Request.proxy.host){$route.proxy=[pscustomobject]@{type=[string]$Request.proxy.type;host=[string]$Request.proxy.host;port=[int]$Request.proxy.port}}
    if($Request.hop -and $Request.hop.ssh){
        $h=[ordered]@{name=$(if($Request.hop.name){[string]$Request.hop.name}else{'hop'});ssh=[string]$Request.hop.ssh}
        if($r.kind -eq 'hop' -and $r.key){$h.keyFile=[string]$r.key}elseif($Request.hop.keyFile){$h.keyFile=[string]$Request.hop.keyFile}
        $kh=Join-Path (Split-Path $Profile.knownHostsPath -Parent) 'known_hosts-hop'
        if(Test-Path -LiteralPath $kh){$line=@([IO.File]::ReadAllLines($kh)|Where-Object {$_ -and -not $_.StartsWith('#')})|Select-Object -First 1;if($line){$f=$line -split '\s+';if($f.Count -ge 3){$h.hostKey=$f[1]+' '+$f[2]}}}
        $route.hop=[pscustomobject]$h
    }
    $value=[pscustomobject]$route
    Update-LauncherConfig $Root {param($c) Set-ConfigDefault $c wizard ([pscustomobject]@{});$c.wizard|Add-Member -Force serverRoute $value}
}
function Invoke-WizardLogin($Profile,[string]$User,[string]$Command,[string]$InputText='', $Credential=$null,[int]$Timeout=20) {
    $args=@('-F',$Profile.configPath,'-T','-l',$User,'-i',$Profile.keyPath,'-o','IdentitiesOnly=yes','-o','ConnectTimeout=8','-o','ConnectionAttempts=1','-o',('UserKnownHostsFile="'+$Profile.knownHostsPath.Replace('\','/')+'"'),'-o','GlobalKnownHostsFile=none','-o','ForwardAgent=no','-o','ClearAllForwardings=yes')
    # The chosen route (direct / local proxy / SSH hop) applies to this step's SSH calls only; it is never written into the saved profile.
    if($script:WizardRoute){$args+=@($script:WizardRoute.options)}
    $strict=if($Profile.strictHostKey){'StrictHostKeyChecking=yes'}else{'StrictHostKeyChecking=accept-new'}
    if(-not $Credential){
        try{return Invoke-DiskProcess $Profile.sshExecutable ($args+@('-o','BatchMode=yes','-o',$strict,$Profile.serverAddress,$Command)) $InputText -TimeoutSeconds $Timeout}
        catch{$m=[string]$_.Exception.Message;if($m -like '*SSH-баннера*'){$script:WizardNoBanner=$true}elseif($m -like '*отклонил вход*'){$script:WizardReached=$true};throw}
    }
    $si=New-Object Diagnostics.ProcessStartInfo
    $si.FileName=$Profile.sshExecutable;$si.Arguments=(($args+@('-o','BatchMode=no','-o','StrictHostKeyChecking=accept-new','-o','NumberOfPasswordPrompts=1','-o','PreferredAuthentications=password,keyboard-interactive','-o','KbdInteractiveAuthentication=yes','-o','PubkeyAuthentication=no',$Profile.serverAddress,$Command))|ForEach-Object {Quote-Disk $_}) -join ' '
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    $si.EnvironmentVariables['SSH_ASKPASS']=[string]$Credential.askpassExecutable
    $si.EnvironmentVariables['SSH_ASKPASS_REQUIRE']='force';$si.EnvironmentVariables['DISPLAY']='remoteagents:0'
    $si.EnvironmentVariables['REMOTEAGENTS_PASSWORD_PIPE']=[string]$Credential.passwordPipe
    $p=New-Object Diagnostics.Process;$p.StartInfo=$si
    try {
        [void]$p.Start();$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
        $bytes=[Text.Encoding]::UTF8.GetBytes((Convert-TransportLF $InputText));$task=$p.StandardInput.BaseStream.WriteAsync($bytes,0,$bytes.Length)
        if(-not $task.Wait(5000)){throw 'Таймаут отправки SSH'};$p.StandardInput.Close()
        if(-not $p.WaitForExit(30000)){throw 'SSH не отвечает (таймаут 30 с)'}
        # OpenSSH reports authentication/connection failures as 255; other codes come from the remote helper.
        if($p.ExitCode -eq 255 -and ($err.GetAwaiter().GetResult() -match $script:WizardNoBannerPattern) -and ($err.GetAwaiter().GetResult() -notmatch 'Permission denied')){$script:WizardNoBanner=$true;throw $script:WizardNoBannerText}
        if($p.ExitCode -eq 255){throw 'Вход по паролю не выполнен. Проверьте пароль; если вход по паролю для этого логина запрещён, администратор должен разрешить ключ рабочего пользователя. Изменённый ключ сервера требует проверки known_hosts'}
        if($p.ExitCode -ne 0){
            $detail=(Protect-TransportText ((Convert-TransportLF $err.GetAwaiter().GetResult()).Trim())) -split "`n"|Where-Object {$_}|Select-Object -Last 3
            throw ('Вход выполнен, но настройка рабочего пользователя на сервере не удалась (код '+$p.ExitCode+'): '+$(if($detail){($detail -join '; ')}else{'нет вывода'})+'. Нужны права root/sudo, useradd и systemd на сервере')
        }
        return Convert-TransportLF $out.GetAwaiter().GetResult()
    }finally{if($p.Id -and -not $p.HasExited){$p.Kill()};$p.Dispose()}
}
function Get-WizardKeyCandidates([string]$Root,[string]$Own,[string]$Chosen) {
    # Order: the chosen file, this user's standard OpenSSH keys, then keys of other RemoteAgents profiles.
    $userHome=if($env:USERPROFILE){$env:USERPROFILE}else{$HOME};$list=@();if($Chosen){$list+=$Chosen}
    $list+=@('id_ed25519','id_ecdsa','id_rsa')|ForEach-Object {Join-Path (Join-Path $userHome '.ssh') $_}
    $profiles=Join-Path $Root 'ssh-profiles'
    if(Test-Path -LiteralPath $profiles){$list+=@(Get-ChildItem -LiteralPath $profiles -Recurse -File -Filter 'id_ed25519'|Sort-Object FullName|ForEach-Object {$_.FullName})}
    $seen=@{};$skip=[IO.Path]::GetFullPath($Own)
    foreach($key in $list){$full=[IO.Path]::GetFullPath($key);if($full -eq $skip -or $seen.ContainsKey($full) -or -not (Test-Path -LiteralPath $full -PathType Leaf)){continue};$seen[$full]=1;$full}
}
function Connect-WizardExistingKey([string]$Root,$Profile,[string]$User,[string]$Command,[string]$Payload,[string]$Chosen) {
    # Only key paths are passed to ssh; key contents are never read, shown or logged here.
    if($Chosen -and $Chosen.EndsWith('.pub',[StringComparison]::OrdinalIgnoreCase)){$Chosen=$Chosen.Substring(0,$Chosen.Length-4)}
    if($Chosen -and -not (Test-Path -LiteralPath $Chosen -PathType Leaf)){Write-WizardProgress ('Файл ключа не найден: '+$Chosen+' ✗')}
    foreach($key in @(Get-WizardKeyCandidates $Root $Profile.keyPath $Chosen)){
        Write-WizardProgress ('Пробую ключ '+$key+'…')
        $q=$Profile.PSObject.Copy();$q.keyPath=$key;$e=''
        try{[void](Invoke-WizardLogin $q $User $Command $Payload -Timeout 15);Write-WizardProgress ('Пробую ключ '+$key+'… ✓ ключ этого компьютера добавлен на сервер');return $true}catch{$e=[string]$_.Exception.Message}
        $why='не подошёл'
        if($e -notmatch 'код выхода 255'){$why=if($e -match 'код выхода'){'вход выполнен, но настройка рабочего пользователя не удалась'}else{'сервер не ответил вовремя'}}
        else{try{$keygen=@(Get-Command ssh-keygen -CommandType Application -ErrorAction Stop)[0].Source;[void](Invoke-DiskProcess $keygen @('-y','-P','','-f',$key) -TimeoutSeconds 10)}catch{$why='защищён паролем (или не в формате OpenSSH), пропускаю'}}
        Write-WizardProgress ('Пробую ключ '+$key+'… ✗ '+$why)
    }
    return $false
}
function Connect-WizardServer([string]$Root,[string]$Bundle,$Request) {
    $address=[string]$Request.address;$user=[string]$Request.login;if(-not $user){$user='root'}
    if($address -notmatch '\A[a-zA-Z0-9][a-zA-Z0-9.:-]{0,252}\z' -or $user -notmatch '\A[a-z_][a-z0-9_-]{0,31}\z'){throw 'Укажите адрес сервера и корректный логин SSH'}
    $old=Find-InstallProfile $Root;$previous=$null
    if($old -and (Test-Path $old)){$previous=Read-TransportJson $old}
    if($previous -and $previous.serverAddress -ceq $address -and $previous.login -ceq $user){
        try{[void](Invoke-WizardSsh $Root 'true' '' 10);Update-LauncherConfig $Root {param($c) if(-not $c.transport.profilePath -and -not $c.wizard.pendingProfile){Set-ConfigDefault $c transport ([pscustomobject]@{});$c.transport|Add-Member -Force profilePath $old}};return $old}catch{}
    }
    $id=(Get-TransportFingerprint $address $user).Substring(0,20)
    $dir=Join-Path $Root ('ssh-profiles/'+$id+'/project-connections/control')
    [void][IO.Directory]::CreateDirectory($dir);Protect-TransportPath $dir
    $file=Join-Path $dir 'ssh-transport.json'
    $p=[pscustomobject]@{sshExecutable=@(Get-Command ssh -CommandType Application -ErrorAction Stop)[0].Source;serverAddress=$address;login=$user;keyPath=(Join-Path $dir 'id_ed25519');knownHostsPath=(Join-Path $dir 'known_hosts');configPath=(Join-Path $dir 'ssh.conf')}
    if($env:OS -eq 'Windows_NT'){$p.sshExecutable=@(Get-Command ssh.exe -CommandType Application -ErrorAction Stop)[0].Source}
    Write-DiskUtf8 $p.configPath "Host *`n    Port 22`n    ConnectTimeout 5`n"
    if(-not (Test-Path $p.keyPath)){
        Write-WizardProgress 'Создаю ключ этого компьютера…'
        $keygen=@(Get-Command ssh-keygen -CommandType Application -ErrorAction Stop)[0].Source
        [void](Invoke-DiskProcess $keygen @('-q','-t','ed25519','-N','','-f',$p.keyPath));Protect-TransportPath $p.keyPath
    }
    $worker=if($user -ceq 'root'){'remoteagents'}else{$user}
    Select-WizardRoute $p $worker (New-WizardRoutes $Request $p)
    # A successful previous root bootstrap is resumed directly as the worker, without a password.
    Write-WizardProgress ('Подключаюсь к серверу '+$address+' по ключу…')
    $ready=$false;try{[void](Invoke-WizardLogin $p $worker 'true');$ready=$true}catch{}
    if(-not $ready){
        $key=(Convert-TransportLF ([IO.File]::ReadAllText($p.keyPath+'.pub'))).Trim()
        if($key -notmatch '\Assh-ed25519 [A-Za-z0-9+/=]+(?: [^\r\n]*)?\z'){throw 'Некорректный открытый ключ'}
        $script=Convert-TransportLF ([IO.File]::ReadAllText((Join-Path $Bundle 'build/server-ssh-user.sh')))
        $payload=$worker+"`n"+$key+"`n"+$script
        # read public parameters first, then execute the same idempotent server helper.
        $command='IFS= read -r ra_user; IFS= read -r ra_key; export ra_user ra_key; bash -s'
        $done=$false;try{[void](Invoke-WizardLogin $p $user $command $payload);$done=$true}catch{}
        # Any private key that already opens this login installs this computer's own key once; then only it is used.
        if(-not $done){$done=Connect-WizardExistingKey $Root $p $user $command $payload ([string]$Request.keyFile)}
        if(-not $done){
            if(-not $Request.passwordPipe){if($script:WizardNoBanner -and -not $script:WizardReached){throw $script:WizardNoBannerText};throw 'Ни один ключ не подошёл. Выберите файл ключа, которым вы входите на сервер, или введите пароль (если вход по паролю на сервере разрешён)'}
            Write-WizardProgress ('Вхожу как '+$user+' по паролю и настраиваю ключ рабочего пользователя…')
            [void](Invoke-WizardLogin $p $user $command $payload $Request)
        }
        [void](Invoke-WizardLogin $p $worker 'true')
    }
    $p.login=$worker
    $p|Add-Member arguments @('-F',$p.configPath,'-l',$worker,'-i',$p.keyPath,'-o','IdentitiesOnly=yes','-o',('UserKnownHostsFile="'+$p.knownHostsPath.Replace('\','/')+'"'),'-o','GlobalKnownHostsFile=none','-o','StrictHostKeyChecking=yes','-o','BatchMode=yes','-T',$address)
    Write-TransportJson $file $p -Private
    # The profile above holds no route: bridge/disk connections (section «Связь») choose their own transport.
    Save-WizardRoute $Root $Request $p
    $changed=$previous -and ($previous.serverAddress -cne $address -or $previous.login -cne $worker)
    $diskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'
    $diskInstalled=(Test-Path (Join-Path $diskHome 'state/config.xml')) -or (Test-Path (Join-Path $diskHome 'profile.txt'))
    Update-LauncherConfig $Root {param($c)
        if($changed){
            Set-ConfigDefault $c wizard ([pscustomobject]@{})
            if(-not $c.wizard.diskPreviousProfile -and $diskInstalled){$c.wizard|Add-Member -Force diskPreviousProfile $old}
            $c.wizard|Add-Member -Force configured $false
            $c.wizard.PSObject.Properties.Remove('localCatalog')
            foreach($flag in @('skipDisk','skipHappier','skipLan','diskKeepPrevious')){$c.wizard.PSObject.Properties.Remove($flag)}
            # Preserve other product settings, but never reuse another server's nodes or keys.
            $c.wizard|Add-Member -Force pendingProfile $file
        }else{Set-ConfigDefault $c transport ([pscustomobject]@{});$c.transport|Add-Member -Force profilePath $file}
    }
    if($changed){
        foreach($name in @('happier-account.json')){$state=Join-Path $Root ('state/'+$name);if(Test-Path $state){Move-Item $state ($state+'.previous-'+[guid]::NewGuid().ToString('N'))}}
    }
    return $file
}

function Initialize-WizardTransport([string]$Root,[string]$Bundle,$Transport) {
    $config=Read-TransportJson (Join-Path $Root 'config.json')
    $profile=Find-InstallProfile $Root;$p=Read-TransportJson $profile
    if(-not $Transport.profilePath){$Transport|Add-Member -Force profilePath $profile}
    if(-not $Transport.channelPath){
        $file=Join-Path $Root ('state/wizard-channel-'+(Get-TransportFingerprint $p.serverAddress $p.login).Substring(0,16)+'.json')
        # The server exports its VLESS channel when it has one.
        Send-WizardHelpers $Root $Bundle
        $hasVless=Invoke-WizardSsh $Root 'test -r /etc/sing-box/config.json && echo yes || echo no'
        if($hasVless.Trim() -eq 'yes'){
            $request=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{server=$p.serverAddress}|ConvertTo-Json -Compress)))
            $channel=ConvertFrom-Json (Convert-TransportLF (Invoke-WizardSsh $Root ('bash "$HOME/.local/share/remote-disk/server-disk.sh" channel-config '+$request)))
        }else{
            $ports=ConvertFrom-Json (Convert-TransportLF (Invoke-WizardSsh $Root 'cat "$HOME/.local/share/remote-disk/ports.json" 2>/dev/null || echo "{}"'))
            if([int]$ports.listen -lt 1 -or [int]$ports.listen -gt 65535){
                $op=(Get-WizardOperation $Root $Bundle 'status' @('disk')).disk
                if($op.state -eq 'running'){$script:WizardPendingDisk=$op;throw 'Сервер диска ещё устанавливается'}
                throw 'Нет порта сервера Disk. Включите установку недостающего на шаге «Сервер» и повторите'
            }
            $channel=@{inbounds=@(@{tag='sync';override_port=[int]$ports.listen});outbounds=@()}
        }
        Write-TransportJson $file $channel -Private
        $Transport|Add-Member -Force channelPath $file
    }
    if(-not $Transport.singBoxPath -or -not (Test-Path $Transport.singBoxPath)){
        Write-WizardProgress 'Подготавливаю программу связи (загрузка с проверкой SHA-256)…'
        . (Join-Path $Bundle 'disk/Disk.Binary.ps1')
        Install-DiskBinary 'https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-windows-amd64.zip' '99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df' 'transport-bin' 'sing-box.exe' $Root
        $Transport|Add-Member -Force singBoxPath (Join-Path $Root 'transport-bin/sing-box.exe')
    }
}
