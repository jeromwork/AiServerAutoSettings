#requires -Version 5.1
# Server network sections: Internet exit (proxy-out) and local networks (LAN).
# Root actions come only from this wizard, in this order: the existing key already logs in as root ->
# a root key accepted by the server -> the root/sudo password typed once in the window (memory only)
# -> an exact command for the administrator. The working user never receives sudo or root keys.
$script:WizardNetMarker='---remoteagents-stdin---'
$script:WizardNetBegin='---remoteagents-begin---'
$script:WizardNetDir='.local/share/remoteagents-net/server'
# Root-owned copies installed by the server scripts themselves (rollback timers use them too).
if(-not $script:WizardNetBin){$script:WizardNetBin='/usr/local/lib/remoteagents'}
function Read-WizardRelay([string]$Name) {
    # One line from the window's in-memory relay (current Windows user only); never stored.
    if(-not $Name.StartsWith('RemoteAgents.Password.')){throw 'Неверный канал пароля'}
    $pipe=New-Object IO.Pipes.NamedPipeClientStream('.',$Name,[IO.Pipes.PipeDirection]::In)
    try{$pipe.Connect(5000);$reader=New-Object IO.StreamReader($pipe,(New-Object Text.UTF8Encoding($false)));$line=$reader.ReadLine();if($null -eq $line){throw 'Пароль не получен'};return $line}finally{$pipe.Dispose()}
}
function Get-WizardNetArgs($Profile,[string]$User,[string]$Root='') {
    $route=@();if($Root){$route=@(Get-TransportSavedRouteOptions $Root $Profile)}
    $route+@('-F',$Profile.configPath,'-T','-l',$User,'-i',$Profile.keyPath,'-o','IdentitiesOnly=yes','-o','ConnectTimeout=5','-o','ConnectionAttempts=1','-o',('UserKnownHostsFile="'+$Profile.knownHostsPath.Replace('\','/')+'"'),'-o','GlobalKnownHostsFile=none','-o','StrictHostKeyChecking=yes','-o','ForwardAgent=no','-o','ClearAllForwardings=yes')
}
function Get-WizardAdminMode([string]$Root,$Request) {
    $p=Read-TransportJson (Find-InstallProfile $Root)
    if(([string]$p.login).Trim() -ceq 'root'){return 'profile'}
    # Same key, root account: only works where the owner has authorized it for root.
    try{[void](Invoke-DiskProcess $p.sshExecutable ((Get-WizardNetArgs $p 'root' $Root)+@('-o','BatchMode=yes',$p.serverAddress,'true')) '' -TimeoutSeconds 20);return 'rootkey'}catch{}
    if($Request.passwordPipe){return 'password'}
    return 'command'
}
function Invoke-WizardAdmin([string]$Root,$Request,[string]$Mode,[string]$Script,[int]$Timeout=300) {
    # The whole root job is stdin: scripts, profile and secrets never touch argv or the worker's files.
    # A tiny reader skips everything before the begin marker, so with NOPASSWD sudo the unused
    # password line is discarded instead of being executed.
    $reader='IFS= read -r l || exit 9; while [ "$l" != "'+$script:WizardNetBegin+'" ]; do IFS= read -r l || exit 9; done; exec bash -s'
    $body=$script:WizardNetBegin+"`n"+(Convert-TransportLF $Script)
    $p=Read-TransportJson (Find-InstallProfile $Root)
    switch($Mode){
        'profile' {return Invoke-DiskProcess $p.sshExecutable ((Get-WizardNetArgs $p ([string]$p.login) $Root)+@('-o','BatchMode=yes',$p.serverAddress,('bash -c '+(ConvertTo-WizardShell $reader)))) $body -TimeoutSeconds $Timeout}
        'rootkey' {return Invoke-DiskProcess $p.sshExecutable ((Get-WizardNetArgs $p 'root' $Root)+@('-o','BatchMode=yes',$p.serverAddress,('bash -c '+(ConvertTo-WizardShell $reader)))) $body -TimeoutSeconds $Timeout}
        'password' {
            $user=[string]$Request.adminLogin;if(-not $user){$user='root'}
            if($user -notmatch '\A[a-z_][a-z0-9_-]{0,31}\z'){throw 'Некорректный логин администратора'}
            $command='bash -c '+(ConvertTo-WizardShell $reader)
            if($user -cne 'root'){$body=(Read-WizardRelay ([string]$Request.passwordPipe))+"`n"+$body;$command="sudo -S -k -p '' "+$command}
            return Invoke-WizardAskpass $p $user $command $body $Request $Timeout $Root
        }
    }
    throw 'Нет прав root: введите пароль или передайте команду администратору'
}
function Invoke-WizardAskpass($Profile,[string]$User,[string]$Command,[string]$InputText,$Request,[int]$Timeout,[string]$Root='') {
    $si=New-Object Diagnostics.ProcessStartInfo
    $si.FileName=$Profile.sshExecutable;$si.Arguments=(((Get-WizardNetArgs $Profile $User $Root)+@('-o','BatchMode=no','-o','NumberOfPasswordPrompts=1','-o','PreferredAuthentications=password,keyboard-interactive','-o','PubkeyAuthentication=no',$Profile.serverAddress,$Command))|ForEach-Object {Quote-Disk $_}) -join ' '
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    $si.EnvironmentVariables['SSH_ASKPASS']=[string]$Request.askpassExecutable
    $si.EnvironmentVariables['SSH_ASKPASS_REQUIRE']='force';$si.EnvironmentVariables['DISPLAY']='remoteagents:0'
    $si.EnvironmentVariables['REMOTEAGENTS_PASSWORD_PIPE']=[string]$Request.passwordPipe
    $p=New-Object Diagnostics.Process;$p.StartInfo=$si
    try{
        [void]$p.Start();$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
        $bytes=[Text.Encoding]::UTF8.GetBytes($InputText);$task=$p.StandardInput.BaseStream.WriteAsync($bytes,0,$bytes.Length)
        if(-not $task.Wait([Math]::Max(15,$Timeout)*1000)){throw 'Таймаут отправки SSH'};$p.StandardInput.Close();[Array]::Clear($bytes,0,$bytes.Length)
        if(-not $p.WaitForExit($Timeout*1000)){throw 'Сервер не ответил вовремя; откат сработает автоматически'}
        if($p.ExitCode -eq 255){throw 'Вход администратора не выполнен: проверьте логин и пароль'}
        if($p.ExitCode -ne 0){throw (Get-WizardNetError $err.GetAwaiter().GetResult() $p.ExitCode)}
        return Convert-TransportLF $out.GetAwaiter().GetResult()
    }finally{if($p.Id -and -not $p.HasExited){$p.Kill()};$p.Dispose()}
}
function Get-WizardNetError([string]$Text,[int]$Code) {
    # Server scripts print only constant messages ("Ошибка: ..."); nothing else is shown.
    $line=@((Convert-TransportLF $Text) -split "`n"|Where-Object {$_ -like 'Ошибка: *'})|Select-Object -Last 1
    if($line){return (Protect-TransportText $line.Substring(8))}
    if($Code -eq 1 -or $Code -eq 9){return 'Нет прав root/sudo или неверный пароль (код '+$Code+')'}
    return 'Команда на сервере не выполнена (код '+$Code+')'
}
function ConvertTo-WizardShell([string]$Value) {return "'"+$Value.Replace("'","'\''")+"'"}
function Get-WizardNetFiles([string]$Bundle,[string[]]$Names) {
    # Root-owned temporary copy for this one job; the trap removes it.
    $text='set -eu; umask 077; d=$(mktemp -d); trap ''rm -rf "$d"'' EXIT'+"`n"
    foreach($name in $Names){
        $bytes=[Text.Encoding]::UTF8.GetBytes((Convert-TransportLF ([IO.File]::ReadAllText((Join-Path $Bundle ('server/'+$name))))))
        $text+='printf %s '+[Convert]::ToBase64String($bytes)+' | base64 -d > "$d/'+$name+'"'+"`n"
    }
    return $text
}
function Get-WizardHeredoc([string]$Text) {
    $end='RA_END_'+[guid]::NewGuid().ToString('N')
    return " <<'"+$end+"'`n"+$script:WizardNetMarker+"`n"+$Text+"`n"+$end+"`n"
}
function Send-WizardNetScripts([string]$Root,[string]$Bundle) {
    # Only for the administrator command: the administrator reviews and runs it themselves.
    $upload='set -eu; umask 077; mkdir -p "$HOME/'+$script:WizardNetDir+'"'+"`n";$temp=[guid]::NewGuid().ToString('N')
    foreach($name in @('lan-vpn.sh','lan_vpn.py','lan-config.schema.json','proxy-out.sh','proxy_out.py')){
        $bytes=[Text.Encoding]::UTF8.GetBytes((Convert-TransportLF ([IO.File]::ReadAllText((Join-Path $Bundle ('server/'+$name))))))
        $upload+='test ! -L "$HOME/'+$script:WizardNetDir+'/'+$name+'"; printf %s '+[Convert]::ToBase64String($bytes)+' | base64 -d > "$HOME/'+$script:WizardNetDir+'/.'+$temp+'"; mv -f "$HOME/'+$script:WizardNetDir+'/.'+$temp+'" "$HOME/'+$script:WizardNetDir+'/'+$name+'"'+"`n"
    }
    [void](Invoke-WizardSsh $Root 'bash -s' $upload)
    return '~'+(Read-TransportJson (Find-InstallProfile $Root)).login+'/'+$script:WizardNetDir
}
function Assert-WizardCheckUrl([string]$Url) {
    $uri=$null
    if(-not [Uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $Url -match '[\s''"\\`$]'){throw 'Укажите свой HTTPS-адрес проверки IP (ответ — только IP)'}
    return $Url
}
function Get-WizardProxySecret([string]$Root) {
    $file=Join-Path $Root 'secrets/proxy-out.json'
    if(-not (Test-Path -LiteralPath $file)){return [pscustomobject]@{username='';password=''}}
    return Read-TransportJson $file
}
function Set-WizardProxy([string]$Root,[string]$Bundle,$Request) {
    $type=[string]$Request.type;if($type -notin @('socks','http')){throw 'Выберите тип прокси: SOCKS5 или HTTP'}
    $server=([string]$Request.server).Trim();$port=0
    if($server -notmatch '\A[A-Za-z0-9][A-Za-z0-9.:-]{0,252}\z'){throw 'Укажите адрес прокси'}
    if(-not [int]::TryParse([string]$Request.port,[ref]$port) -or $port -lt 1 -or $port -gt 65535){throw 'Порт прокси: число 1–65535'}
    $url=Assert-WizardCheckUrl ([string]$Request.ipCheckUrl)
    $secret=Get-WizardProxySecret $Root;$auth=[bool]([string]$secret.username)
    Update-LauncherConfig $Root {param($c) Set-ConfigDefault $c proxy ([pscustomobject]@{});$c.proxy|Add-Member -Force type $type;$c.proxy|Add-Member -Force server $server;$c.proxy|Add-Member -Force port $port;$c.proxy|Add-Member -Force ipCheckUrl $url;$c.proxy|Add-Member -Force confirmed $false}
    $arguments='apply --type '+$type+' --server '+$server+' --port '+$port+' --ip-check-url '+(ConvertTo-WizardShell $url)
    $mode=[string]$Request.mode;if(-not $mode){$mode=Get-WizardAdminMode $Root $Request}
    if($mode -eq 'command'){
        $dir=Send-WizardNetScripts $Root $Bundle
        $command='sudo bash '+$dir+'/proxy-out.sh '+$arguments+$(if($auth){' --ask-credentials'}else{''})+"`n"+'# затем в НОВОМ SSH-соединении в течение 5 минут: sudo bash '+$dir+'/proxy-out.sh confirm --ssh-checked'
        return @{ok=$false;mode=$mode;command=$command;summary='Нужен администратор сервера: скопируйте команду. Без confirm через 5 минут вернётся прежний выход'}
    }
    Write-WizardProgress 'Проверяю новый прокси и применяю его на сервере (автооткат 5 минут)…'
    $json=@{username=[string]$secret.username;password=[string]$secret.password}|ConvertTo-Json -Compress
    $script=(Get-WizardNetFiles $Bundle @('lan_vpn.py','proxy_out.py','proxy-out.sh'))+'python3 -I "$d/proxy_out.py" '+$arguments+' --credentials-stdin'+(Get-WizardHeredoc $json)
    [void](Invoke-WizardAdmin $Root $Request $mode $script 180)
    # Confirm runs over a NEW SSH connection: it proves the server is still reachable.
    Write-WizardProgress 'Проверяю новое SSH-соединение и подтверждаю…'
    [void](Invoke-WizardAdmin $Root $Request $mode ('exec '+$script:WizardNetBin+'/proxy-out/proxy-out.sh confirm --ssh-checked') 120)
    Update-LauncherConfig $Root {param($c) $c.proxy|Add-Member -Force confirmed $true;Set-ConfigDefault $c wizard ([pscustomobject]@{});$c.wizard.PSObject.Properties.Remove('skipProxy')}
    return @{ok=$true;mode=$mode;summary='Подключён ✓: сервер выходит в интернет через этот прокси (проверено)'}
}
function Get-WizardLanName([string]$Name,[string]$File) {
    if($Name){if($Name -cnotmatch '\A[a-z][a-z0-9]{0,6}\z'){throw 'Имя сети: 1–7 строчных латинских букв/цифр, первая — буква'};return $Name}
    return 'l'+(Get-TransportFingerprint 'lan' ([IO.Path]::GetFileNameWithoutExtension($File))).Substring(0,6)
}
function Add-WizardLan([string]$Root,[string]$Bundle,$Request) {
    $kind=[string]$Request.kind;if(-not $kind){$kind='openvpn'}
    if($kind -ne 'openvpn'){throw 'Пока поддерживается только OpenVPN'}
    $file=[string]$Request.file;$payload=Get-WizardLanPayload $file
    $name=Get-WizardLanName ([string]$Request.name) $file
    $needsAuth=$payload -match '(?m)^\s*(?:--)?auth-user-pass\s*$'
    $url=Assert-WizardCheckUrl ([string]$Request.ipCheckUrl)
    $hostAddress=([string]$Request.host).Trim();$port=[string]$Request.port
    if($hostAddress -notmatch '\A\d{1,3}(\.\d{1,3}){3}\z'){throw 'Укажите IPv4 компьютера в этой сети для проверки'}
    if($port -and $port -notmatch '\A\d{1,5}\z'){throw 'Порт проверки: число'}
    $mode=[string]$Request.mode;if(-not $mode){$mode=Get-WizardAdminMode $Root $Request}
    if($mode -eq 'command'){
        $r=Send-WizardLan $Root $Bundle $file $name
        $dir=Send-WizardNetScripts $Root $Bundle
        $p=Read-TransportJson (Find-InstallProfile $Root)
        $command='sudo bash '+$dir+'/lan-vpn.sh add '+$name+' ~'+$p.login+'/.config/remoteagents/lan/'+$name+'/profile.ovpn --ip-check-url '+(ConvertTo-WizardShell $url)+$(if($needsAuth){' --ask-auth'}else{''})+"`n"+'# затем в НОВОМ SSH-соединении в течение 5 минут: sudo bash '+$dir+'/lan-vpn.sh test '+$name+' '+$hostAddress+' '+$port+' && sudo bash '+$dir+'/lan-vpn.sh confirm '+$name+' --ssh-checked'
        Save-WizardLanEntry $Root $name $kind $file $hostAddress $port
        return @{ok=$false;mode=$mode;name=$name;command=$command;summary='Профиль на сервере. Включает администратор: скопируйте команду'}
    }
    $auth=$null
    if($needsAuth){
        if(-not $Request.secretPipe){throw 'Профиль требует логин и пароль этой сети: заполните поля'}
        $auth=Read-WizardRelay ([string]$Request.secretPipe)
        if(-not ($auth|ConvertFrom-Json).username){throw 'Профиль требует логин и пароль этой сети: заполните поля'}
    }
    Write-WizardProgress 'Подключаю локальную сеть на сервере (автооткат 5 минут)…'
    $script=(Get-WizardNetFiles $Bundle @('lan-vpn.sh','lan_vpn.py','lan-config.schema.json'))
    $bytes=[Text.Encoding]::UTF8.GetBytes($payload);$script+='printf %s '+[Convert]::ToBase64String($bytes)+' | base64 -d > "$d/profile.ovpn"'+"`n"
    $script+='python3 -I "$d/lan_vpn.py" add '+$name+' "$d/profile.ovpn" --ip-check-url '+(ConvertTo-WizardShell $url)
    if($auth){$script+=' --auth-stdin'+(Get-WizardHeredoc $auth)}else{$script+=' </dev/null'+"`n"}
    [void](Invoke-WizardAdmin $Root $Request $mode $script 300)
    Write-WizardProgress 'Проверяю компьютер в сети и новое SSH-соединение, подтверждаю…'
    $bin=$script:WizardNetBin+'/lan/lan-vpn.sh'
    [void](Invoke-WizardAdmin $Root $Request $mode ($bin+' test '+$name+' '+$hostAddress+' '+$port+' && exec '+$bin+' confirm '+$name+' --ssh-checked') 120)
    Save-WizardLanEntry $Root $name $kind $file $hostAddress $port
    return @{ok=$true;mode=$mode;name=$name;summary=('Сеть «'+$name+'» подключена ✓ (компьютер в сети отвечает, интернет — через прокси)')}
}
function Save-WizardLanEntry([string]$Root,[string]$Name,[string]$Kind,[string]$File,[string]$HostAddress,[string]$Port) {
    Update-LauncherConfig $Root {param($c)
        Set-ConfigDefault $c lan ([pscustomobject]@{})
        $rows=@(@($c.lan.connections)|Where-Object {$_ -and $_.name -cne $Name})
        $rows+=@([pscustomobject]@{name=$Name;kind=$Kind;file=[IO.Path]::GetFileName($File);host=$HostAddress;port=$Port})
        $c.lan|Add-Member -Force connections $rows
    }
}
function Remove-WizardLan([string]$Root,[string]$Bundle,$Request) {
    $name=Get-WizardLanName ([string]$Request.name) 'x'
    $mode=[string]$Request.mode;if(-not $mode){$mode=Get-WizardAdminMode $Root $Request}
    $bin=$script:WizardNetBin+'/lan/lan-vpn.sh'
    if($mode -eq 'command'){return @{ok=$false;mode=$mode;command=('sudo '+$bin+' remove '+$name);summary='Удаление выполняет администратор: скопируйте команду'}}
    Write-WizardProgress ('Отключаю и удаляю сеть «'+$name+'» на сервере…')
    [void](Invoke-WizardAdmin $Root $Request $mode ('if [ -x '+$bin+' ]; then exec '+$bin+' remove '+$name+'; fi') 180)
    Update-LauncherConfig $Root {param($c) if($c.lan){$c.lan|Add-Member -Force connections @(@($c.lan.connections)|Where-Object {$_ -and $_.name -cne $name})}}
    return @{ok=$true;mode=$mode;summary=('Сеть «'+$name+'» отключена и удалена')}
}
function Get-WizardNetStatus([string]$Root) {
    # Secret-free public status; reading it needs no root.
    $text=Invoke-WizardSsh $Root 'b=/usr/local/lib/remoteagents/lan/lan-vpn.sh; if [ -x "$b" ]; then "$b" public-status; fi; echo "#proxy"; cat /var/lib/remoteagents-status/proxy.json 2>/dev/null || true'
    $parts=(Convert-TransportLF $text) -split "#proxy`n?",2
    $server=@{};foreach($line in ($parts[0] -split "`n")){if($line.Trim()){$row=$line|ConvertFrom-Json;$server[[string]$row.name]=$row}}
    $config=Read-TransportJson (Join-Path $Root 'config.json');$rows=@()
    $names=@(@(@($config.lan.connections)|Where-Object {$_}|ForEach-Object {[string]$_.name})+@($server.Keys))|Select-Object -Unique
    foreach($name in $names){
        $s=$server[$name]
        $state=if(-not $s){'нет на сервере'}elseif($s.enabled -and $s.active -and $s.ready){'подключена ✓'}elseif($s.enabled){'ошибка: клиент не активен — '+$s.summary}else{'выключена — '+$s.summary}
        $rows+=@(@{name=$name;state=$state;ok=[bool]($s -and $s.enabled -and $s.active -and $s.ready)})
    }
    $proxy=$null;if($parts.Count -gt 1 -and $parts[1].Trim()){$proxy=$parts[1].Trim()|ConvertFrom-Json}
    return @{lans=$rows;proxy=$(if($proxy){@{state=[string]$proxy.state;ok=[bool]$proxy.ok;summary=[string]$proxy.summary}}else{@{state='unknown';ok=$false;summary='Прокси этим приложением не настраивался'}})}
}
