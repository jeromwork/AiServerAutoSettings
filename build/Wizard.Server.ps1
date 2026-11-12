#requires -Version 5.1
# setup-vps-ssh.ps1 creates the OpenSSH key and profile; the wizard supplies a one-use in-memory askpass.
function Write-WizardProgress([string]$Text) {
    if(-not $script:WizardProgressFile){return}
    $mutex=New-Object Threading.Mutex($false,('Global\RemoteAgentsProgress-'+(Get-TransportFingerprint 'progress' ([IO.Path]::GetFullPath($script:WizardProgressFile).ToLowerInvariant()))))
    $locked=$false
    try{
        try{$locked=$mutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){throw 'Журнал прогресса занят'}
        [void][IO.Directory]::CreateDirectory((Split-Path $script:WizardProgressFile -Parent))
        [IO.File]::AppendAllText($script:WizardProgressFile,((@{text=$Text}|ConvertTo-Json -Compress)+"`n"),(New-Object Text.UTF8Encoding($false)))
    }finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
# Detailed journal for «Скопировать журнал»: lines starting with «·» go only to the window journal, not to the section row.
# Masked: UUIDs, long tokens without slashes, URL passwords and route commands (the route title is logged separately);
# paths, other options, addresses and ports stay readable.
function Protect-WizardTrace([string]$Text) {
    $Text -replace '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}','<uuid>' -replace '[A-Za-z0-9+_=-]{32,}','<secret>' -replace '://[^/@\s]+@','://<auth>@' -replace 'ProxyCommand[= ][^"\r\n]*','<маршрут>'
}
function Write-WizardTrace([string]$Exe,[string]$Arguments,[string]$Code,[long]$Ms,[string]$Err) {
    if(-not $script:WizardProgressFile){return}
    $lines=@('· '+[IO.Path]::GetFileName($Exe)+' '+(Protect-WizardTrace $Arguments)+' → код '+$Code+', '+$Ms+' мс')
    foreach($line in @((Convert-TransportLF $Err) -split "`n"|Where-Object {$_.Trim()}|Select-Object -Last 60)){$lines+=('·   '+(Protect-WizardTrace $line))}
    Write-WizardProgress ($lines -join "`n")
}
# Why a direct SSH failed: no TCP at all, TCP without the SSH banner (a provider filter), or a banner (then it is SSH itself).
function Test-WizardTcpBanner([string]$Address,[int]$Port) {
    $c=New-Object Net.Sockets.TcpClient;$w=[Diagnostics.Stopwatch]::StartNew();$target='TCP '+$Address+':'+$Port+': '
    try{
        if(-not $c.ConnectAsync($Address,$Port).Wait(8000)){return $target+'соединения нет за 8 с (адрес недоступен или порт закрыт в этой сети)'}
        $ms=$w.ElapsedMilliseconds;$s=$c.GetStream();$s.ReadTimeout=8000;$buf=New-Object byte[] 255
        try{$n=$s.Read($buf,0,$buf.Length)}catch{return $target+'соединение есть ('+$ms+' мс), но SSH-баннер не пришёл за 8 с — сеть пропускает соединение и глушит SSH'}
        if($n -le 0){return $target+'соединение есть ('+$ms+' мс), но его сразу закрыли'}
        $target+'соединение '+$ms+' мс, баннер «'+([Text.Encoding]::ASCII.GetString($buf,0,$n).Trim())+'»'
    }catch{$target+$_.Exception.GetBaseException().Message}finally{$c.Close()}
}
function Write-WizardEnvironment([string]$SshExecutable) {
    if(-not $script:WizardProgressFile){return}
    $ssh=try{[Diagnostics.FileVersionInfo]::GetVersionInfo($SshExecutable).ProductVersion}catch{'?'}
    $nets=@([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()|Where-Object {$_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback'}|ForEach-Object {
        $g=@($_.GetIPProperties().GatewayAddresses|ForEach-Object {[string]$_.Address}) -join ','
        $_.Name+' ('+$_.Description+')'+$(if($g){' шлюз '+$g}else{''})})
    Write-WizardProgress ('· Windows '+[Environment]::OSVersion.Version+', PowerShell '+$PSVersionTable.PSVersion+', ssh '+$SshExecutable+' '+$ssh+"`n·   сети: "+($nets -join '; '))
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
    if($Request.proxy -and $Request.proxy.host){
        $opts=@(New-TransportRouteOptions ([pscustomobject]@{used='proxy';proxy=$Request.proxy}) $Profile ([string]$Request.askpassExecutable) -AcceptNew:(-not $Request.strictHostKey))
        $routes+=@{kind='proxy';title=('через локальный прокси '+$Request.proxy.host+':'+$Request.proxy.port);options=$opts}
    }
    $hop=$Request.hop
    if($hop -and $hop.ssh){
            if($Request.strictHostKey -or $hop.hostKey){
                if([string]$hop.hostKey -cnotmatch '\A(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+\z'){throw 'Некорректный ключ промежуточного сервера'}
                $known=if($hop.knownHostsPath){[string]$hop.knownHostsPath}else{Join-Path (Split-Path $Profile.knownHostsPath -Parent) 'known_hosts-hop'}
                $resolved=Get-TransportHopArguments $hop $known
                $hostName=($resolved.target -split '@')[-1];$at=[array]::IndexOf(@($resolved.options),'-p')
                if($at -ge 0 -and $resolved.options[$at+1] -ne '22'){$hostName='['+$hostName+']:'+$resolved.options[$at+1]}
                [IO.File]::WriteAllText($known,($hostName+' '+$hop.hostKey+"`n"),(New-Object Text.UTF8Encoding($false)))
            }
        $keys=@(Get-WizardHopKeys ([string]$hop.keyFile))
        $variants=@($keys|ForEach-Object {@{key=$_;password=$false}})
        if($hop.passwordPipe -or $hop.routePasswordFile){$variants+=@{key='';password=$true}}
        if(-not $variants.Count){throw 'Нужен ключ для промежуточного сервера: выберите файл ключа на шаге «Сервер»'}
        foreach($v in $variants){
            $h=[pscustomobject]@{ssh=[string]$hop.ssh;keyFile=$v.key}
            if($hop.hostKey){$h|Add-Member hostKey $hop.hostKey}
            if($hop.knownHostsPath){$h|Add-Member knownHostsPath $hop.knownHostsPath}
            if($v.password){
                if($hop.routePasswordFile){$h|Add-Member routePasswordFile ([string]$hop.routePasswordFile)}else{$h|Add-Member passwordPipe ([string]$hop.passwordPipe)}
            }
            $opts=@(New-TransportRouteOptions ([pscustomobject]@{used='hop';hop=$h}) $Profile ([string]$Request.askpassExecutable) -AcceptNew:(-not $Request.strictHostKey))
            $routes+=@{kind='hop';title=('через промежуточный сервер '+$hop.ssh+$(if($v.password){' (пароль)'}else{''}));key=$v.key;password=$v.password;options=$opts}
        }
    }
    ,$routes
}
# Route probes run at once, each in its own ssh process: a blocked route costs one timeout in total, not one per route.
# The limit stays generous (a hop through a DPI filter sometimes needs 15-20 s); tests lower it.
$script:WizardProbeTimeout=30;$script:WizardProbeGrace=3
function Start-WizardProbe($Profile,[string]$Worker,$Route) {
    # 'true' as the worker, as Invoke-WizardLogin does. A password hop has its own ProxyCommand environment; the relay pipe serves one askpass at a time.
    $si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=$Profile.sshExecutable
    $strict=if($Profile.strictHostKey){'StrictHostKeyChecking=yes'}else{'StrictHostKeyChecking=accept-new'}
    $si.Arguments=((@(Get-WizardLoginArguments $Profile $Worker)+@($Route.options)+@('-o','BatchMode=yes','-o',$strict,$Profile.serverAddress,'true'))|ForEach-Object {Quote-Disk ([string]$_)}) -join ' '
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    $p=New-Object Diagnostics.Process;$p.StartInfo=$si
    try{[void]$p.Start();$p.StandardInput.Close()}catch{$p.Dispose();return [pscustomobject]@{Route=$Route;Process=$null;Err=$null;State='fail';Why='нет связи'}}
    [void]$p.StandardOutput.ReadToEndAsync()
    [pscustomobject]@{Route=$Route;Process=$p;Err=$p.StandardError.ReadToEndAsync();State='pending';Why=''}
}
function Receive-WizardProbe($Probe) {
    if($Probe.State -ne 'pending' -or -not $Probe.Process.HasExited){return}
    [void]$Probe.Process.WaitForExit();$code=$Probe.Process.ExitCode;$err='';try{if($Probe.Err.Wait(2000)){$err=[string]$Probe.Err.Result}}catch{}
    # As Invoke-DiskProcess: success or a key rejection by the server ("Сервер отклонил вход") means the route reaches SSH.
    if($code -eq 0 -or ($code -eq 255 -and $err -match 'Permission denied')){$Probe.State='ok';return}
    $Probe.State='fail'
    if($err -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed'){$Probe.Why='Ключ хоста не совпал с конфигом или known_hosts';return}
    if($code -eq 255 -and $err -match $script:WizardNoBannerPattern){$Probe.Why='сервер не ответил по SSH'}else{$Probe.Why='нет связи'}
}
function Select-WizardRoute($Profile,[string]$Worker,$Routes) {
    # With only the direct route nothing is probed. Otherwise all routes are probed in parallel; one progress line per route, then ✓/✗ as each answers.
    # Several working routes: list order wins (direct > proxy > hop); a later one is taken once no earlier one is pending, or WizardProbeGrace s after the first success.
    $script:WizardRoute=$Routes[0];$script:WizardNoBanner=$false;$script:WizardReached=$false
    if($Routes.Count -lt 2){return}
    $probes=@();$chosen=$null
    try{
        foreach($r in $Routes){Write-WizardProgress ('Проверяю: '+$r.title+'…');$q=Start-WizardProbe $Profile $Worker $r;$probes+=$q;if($q.State -eq 'fail'){Write-WizardProgress ('Проверяю: '+$r.title+'… ✗ '+$q.Why)}}
        $deadline=[DateTime]::UtcNow.AddSeconds($script:WizardProbeTimeout);$firstOk=$null
        while($true){
            foreach($q in $probes){
                if($q.State -ne 'pending'){continue};Receive-WizardProbe $q
                if($q.State -eq 'ok'){Write-WizardProgress ('Проверяю: '+$q.Route.title+'… ✓');if(-not $firstOk){$firstOk=[DateTime]::UtcNow}}
                elseif($q.State -eq 'fail'){Write-WizardProgress ('Проверяю: '+$q.Route.title+'… ✗ '+$q.Why)}
            }
            $now=[DateTime]::UtcNow;$expired=$now -ge $deadline;$best=$null;$earlier=$false
            foreach($q in $probes){if($q.State -eq 'ok'){$best=$q;break};if($q.State -eq 'pending'){$earlier=$true}}
            if($best -and (-not $earlier -or $expired -or ($now-$firstOk).TotalSeconds -ge $script:WizardProbeGrace)){$chosen=$best;break}
            if($expired -or -not @($probes|Where-Object {$_.State -eq 'pending'}).Count){break}
            Start-Sleep -Milliseconds 100
        }
        foreach($q in $probes){if($q.State -eq 'pending'){Write-WizardProgress ('Проверяю: '+$q.Route.title+$(if($chosen){'… не дождался: выбран другой способ'}else{'… ✗ нет ответа за '+$script:WizardProbeTimeout+' с'}))}}
    }finally{foreach($q in $probes){if($q.Process){Stop-TransportProcess ([pscustomobject]@{Process=$q.Process})}}}
    if($chosen){$script:WizardRoute=$chosen.Route;$script:WizardReached=$true;return}
    if($Profile.strictHostKey -and @($probes|Where-Object {$_.Why -like 'Ключ хоста*'}).Count){throw 'Ключ хоста не совпал с конфигом или known_hosts. Попросите администратора проверить ключ сервера'}
    $script:WizardNoBanner=$true;throw 'Сервер не ответил по SSH ни одним из способов (напрямую, через прокси, через промежуточный сервер). Проверьте прокси и промежуточный сервер или включите любой VPN в режиме TUN (OpenVPN, WireGuard…) и нажмите «Повторить». Режим «смешанный» (только прокси) ssh сам не проводит: для него нужен маршрут «Локальный прокси»'
}
function Save-WizardRoute([string]$Root,$Request,$Profile) {
    # Non-secret fields only (the key is a path). hop uses the transport hops[] names: name, ssh, hostKey.
    $r=$script:WizardRoute;$route=[ordered]@{used=[string]$r.kind}
    if($Request.proxy -and $Request.proxy.host){$route.proxy=[pscustomobject]@{type=[string]$Request.proxy.type;host=[string]$Request.proxy.host;port=[int]$Request.proxy.port}}
    if($Request.hop -and $Request.hop.ssh){
        $h=[ordered]@{name=$(if($Request.hop.name){[string]$Request.hop.name}else{'hop'});ssh=[string]$Request.hop.ssh}
        if($r.kind -eq 'hop' -and $r.key){$h.keyFile=[string]$r.key}elseif(-not $r.password -and $Request.hop.keyFile){$h.keyFile=[string]$Request.hop.keyFile}
        $kh=Join-Path (Split-Path $Profile.knownHostsPath -Parent) 'known_hosts-hop'
        if($Request.hop.knownHostsPath){$kh=[string]$Request.hop.knownHostsPath;$h.knownHostsPath=$kh}
        if($r.kind -eq 'hop' -and (Test-Path -LiteralPath $kh)){
            $resolved=Get-TransportHopArguments $Request.hop $kh
            $hostName=($resolved.target -split '@')[-1];$at=[array]::IndexOf(@($resolved.options),'-p')
            if($at -ge 0 -and $resolved.options[$at+1] -ne '22'){$hostName='['+$hostName+']:'+$resolved.options[$at+1]}
            $h.hostKey=@(Get-TransportHostKeys $Profile.sshExecutable $hostName $kh)[0]
        }
        $route.hop=[pscustomobject]$h
    }
    # Both control scripts already read -F configPath. Persist the proved route
    # there too, so bridge preparation and reverse SSH use the same hop/proxy.
    $sshConfig="Host *`n    Port "+(Get-TransportServerPort $Profile)+"`n    ConnectTimeout 5`n"
    foreach($option in @($r.options)){
        if([string]$option -match '\A(ProxyCommand|HostName|HostKeyAlias)=(.+)\z'){$sshConfig+='    '+$Matches[1]+' '+$Matches[2]+"`n"}
    }
    Write-DiskUtf8 $Profile.configPath $sshConfig
    $value=[pscustomobject]$route
    Update-LauncherConfig $Root {param($c) Set-ConfigDefault $c wizard ([pscustomobject]@{});$c.wizard|Add-Member -Force serverRoute $value}
}
function Get-WizardLoginArguments($Profile,[string]$User) {
    @('-F',$Profile.configPath,'-T','-l',$User,'-i',$Profile.keyPath,'-o','IdentitiesOnly=yes','-o','ConnectTimeout=8','-o','ConnectionAttempts=1','-o',('UserKnownHostsFile="'+$Profile.knownHostsPath.Replace('\','/')+'"'),'-o','GlobalKnownHostsFile=none','-o','ForwardAgent=no','-o','ClearAllForwardings=yes')
}
function Invoke-WizardLogin($Profile,[string]$User,[string]$Command,[string]$InputText='', $Credential=$null,[int]$Timeout=45) {
    # Via an SSH hop a login is usually 3-5 s but spikes to ~20 s were measured; short limits failed working routes.
    $args=@(Get-WizardLoginArguments $Profile $User)
    # Route options precede the destination; the profile itself stays independent of the route.
    if($script:WizardRoute){$args+=@($script:WizardRoute.options)}
    $strict=if($Profile.strictHostKey){'StrictHostKeyChecking=yes'}else{'StrictHostKeyChecking=accept-new'}
    if(-not $Credential){
        # -v while the journal is traced: the window journal then shows each step of the SSH handshake.
        $verbose=@(if($script:WizardProgressFile){'-v'})
        try{return Invoke-DiskProcess $Profile.sshExecutable ($verbose+$args+@('-o','BatchMode=yes','-o',$strict,$Profile.serverAddress,$Command)) $InputText -TimeoutSeconds $Timeout}
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
        try{[void](Invoke-WizardLogin $q $User $Command $Payload -Timeout 45);Write-WizardProgress ('Пробую ключ '+$key+'… ✓ ключ этого компьютера добавлен на сервер');return $true}catch{$e=[string]$_.Exception.Message}
        $why='не подошёл'
        if($e -notmatch 'код выхода 255'){$why=if($e -match 'код выхода'){'вход выполнен, но настройка рабочего пользователя не удалась'}else{'сервер не ответил вовремя'}}
        else{try{$keygen=@(Get-Command ssh-keygen -CommandType Application -ErrorAction Stop)[0].Source;[void](Invoke-DiskProcess $keygen @('-y','-P','','-f',$key) -TimeoutSeconds 10)}catch{$why='защищён паролем (или не в формате OpenSSH), пропускаю'}}
        Write-WizardProgress ('Пробую ключ '+$key+'… ✗ '+$why)
    }
    return $false
}
function Connect-WizardServer([string]$Root,[string]$Bundle,$Request) {
    $imported=Connect-WizardProfileServer $Root $Request;if($imported){return $imported}
    $address=[string]$Request.address;$user=[string]$Request.login;if(-not $user){$user='root'}
    if($address -notmatch '\A[a-zA-Z0-9][a-zA-Z0-9.:-]{0,252}\z' -or $user -notmatch '\A[a-z_][a-z0-9_-]{0,31}\z'){throw 'Укажите адрес сервера и корректный логин SSH'}
    $old=Find-InstallProfile $Root;$previous=$null
    if($old -and (Test-Path $old)){$previous=Read-TransportJson $old}
    if($previous -and $previous.serverAddress -ceq $address -and $previous.login -ceq $user){
        try{[void](Invoke-WizardSsh $Root 'true' '' 10);Update-LauncherConfig $Root {param($c) if(-not $c.transport.profilePath -and -not $c.wizard.pendingProfile){Set-ConfigDefault $c transport ([pscustomobject]@{});$c.transport|Add-Member -Force profilePath $old}};return $old}catch{}
    }
    $id=(Get-TransportFingerprint $address $user).Substring(0,20)
    $dir=Join-Path $Root ('ssh-profiles/'+$id+'/project-connections/'+(Get-WizardHostId $Root))
    [void][IO.Directory]::CreateDirectory($dir);Protect-TransportPath $dir
    $file=Join-Path $dir 'ssh-transport.json'
    $p=[pscustomobject]@{sshExecutable=@(Get-Command ssh -CommandType Application -ErrorAction Stop)[0].Source;serverAddress=$address;login=$user;keyPath=(Join-Path $dir 'id_ed25519');knownHostsPath=(Join-Path $dir 'known_hosts');configPath=(Join-Path $dir 'ssh.conf')}
    if($env:OS -eq 'Windows_NT'){$p.sshExecutable=@(Get-Command ssh.exe -CommandType Application -ErrorAction Stop)[0].Source}
    # Config fields server.port / server.hostKeys (docs/CONFIG.md) also on the root-password path of a clean VPS.
    $port=22;if($Request.port){$port=[int]$Request.port;if($port -lt 1 -or $port -gt 65535){throw 'Некорректный порт сервера'}}
    Write-DiskUtf8 $p.configPath ("Host *`n    Port "+$port+"`n    ConnectTimeout 5`n")
    $pins=@();$target=if($port -eq 22){$address}else{'['+$address+']:'+$port}
    foreach($key in @($Request.hostKeys|Where-Object {$_})){
        if([string]$key -cnotmatch '\A(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+\z'){throw 'Некорректный ключ хоста в конфиге'}
        $pins+=($target+' '+$key);if($port -ne 22){$pins+=($address+' '+$key)}
    }
    if($pins.Count){Write-DiskUtf8 $p.knownHostsPath (($pins -join "`n")+"`n");$p|Add-Member -Force strictHostKey $true}
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
    $p|Add-Member arguments (@('-F',$p.configPath)+$(if($port -ne 22){@('-p',[string]$port)}else{@()})+@('-l',$worker,'-i',$p.keyPath,'-o','IdentitiesOnly=yes','-o',('UserKnownHostsFile="'+$p.knownHostsPath.Replace('\','/')+'"'),'-o','GlobalKnownHostsFile=none','-o','StrictHostKeyChecking=yes','-o','BatchMode=yes','-T',$address))
    Write-TransportJson $file $p -Private
    # The personal route stays in config.json; it also supplies the local transport overlay.
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
    $overlay=Get-TransportRouteOverlay $config.wizard.serverRoute $Root
    if($overlay){$Transport|Add-Member -Force serverRoute $overlay}else{$Transport.PSObject.Properties.Remove('serverRoute')}
    if(-not $Transport.profilePath){$Transport|Add-Member -Force profilePath $profile}
    if(-not $Transport.channelPath){
        $file=Join-Path $Root ('state/wizard-channel-'+(Get-TransportFingerprint $p.serverAddress $p.login).Substring(0,16)+'.json')
        # The server exports its VLESS channel when it has one.
        Send-WizardHelpers $Root $Bundle
        $hasVless=Invoke-WizardSsh $Root 'test -r "${REMOTE_DISK_CHANNEL_SOURCE:-/etc/sing-box/config.json}" && echo yes || echo no'
        if($hasVless.Trim() -eq 'yes'){
            $request=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{server=$p.serverAddress}|ConvertTo-Json -Compress)))
            $channel=ConvertFrom-Json (Convert-TransportLF (Invoke-WizardSsh $Root ('bash "$HOME/.local/share/remote-disk/server-disk.sh" channel-config '+$request)))
        }else{
            $ports=ConvertFrom-Json (Convert-TransportLF (Invoke-WizardSsh $Root 'cat "$HOME/.local/share/remote-disk/ports.json" 2>/dev/null || echo "{}"'))
            $inbounds=@()
            if([int]$ports.listen -ge 1 -and [int]$ports.listen -le 65535){$inbounds+=@{tag='sync';override_port=[int]$ports.listen}}
            $channel=@{inbounds=$inbounds;outbounds=@()}
        }
        Write-TransportJson $file $channel -Private
        $Transport|Add-Member -Force channelPath $file
    }
    Ensure-WizardTransportBinary $Root $Bundle $Transport
}
function Ensure-WizardTransportBinary([string]$Root,[string]$Bundle,$Transport) {
    if($Transport.singBoxPath -and (Test-Path -LiteralPath ([string]$Transport.singBoxPath) -PathType Leaf)){return}
    $stable=Join-Path $Root 'transport-bin/sing-box.exe'
    # The EXE's initial bundle carries the pinned sing-box (build/bundle-binaries.json): VPN-first must work before
    # any SSH and without GitHub. It is copied out of the bundle once, because bundle folders are pruned by updates.
    $embedded=Join-Path $Bundle 'transport/sing-box.exe';$pins=Join-Path $Bundle 'build/bundle-binaries.json'
    if(-not (Test-Path -LiteralPath $stable -PathType Leaf) -and (Test-Path -LiteralPath $embedded -PathType Leaf) -and (Test-Path -LiteralPath $pins -PathType Leaf)){
        $expected=[string]@((Read-TransportJson $pins).binaries|Where-Object {$_.target -eq 'transport/sing-box.exe'})[0].memberSha256
        if($expected -and (Get-FileHash -LiteralPath $embedded -Algorithm SHA256).Hash -ieq $expected){
            [void][IO.Directory]::CreateDirectory((Split-Path $stable -Parent))
            $temp=$stable+'.'+[guid]::NewGuid().ToString('N')+'.tmp';Copy-Item -LiteralPath $embedded -Destination $temp
            Move-Item -LiteralPath $temp -Destination $stable -Force
        }else{Write-SetupLog $Root 'transport.binary.embedded.mismatch'}
    }
    if(Test-Path -LiteralPath $stable -PathType Leaf){$Transport|Add-Member -Force singBoxPath $stable;return}
    Write-WizardProgress 'Подготавливаю программу связи (загрузка с проверкой SHA-256)…'
    try{
        . (Join-Path $Bundle 'disk/Disk.Binary.ps1')
        Install-DiskBinary 'https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-windows-amd64.zip' '99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df' 'transport-bin' 'sing-box.exe' $Root
    }catch{throw 'Нет программы связи sing-box: в этой сборке EXE её нет, а загрузка с github.com не прошла. Скачайте полную сборку RemoteAgents.exe (с sing-box внутри) или откройте доступ к github.com и нажмите «Повторить»'}
    $Transport|Add-Member -Force singBoxPath $stable
}
