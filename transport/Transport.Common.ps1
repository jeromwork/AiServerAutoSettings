#requires -Version 5.1
$ErrorActionPreference='Stop'
# Построение цепочек взято из Test-Transports.ps1; разбор профиля/ssh -G — из Disk.Common.ps1.
function Get-TransportHome([string]$Path){
    $full=[IO.Path]::GetFullPath($Path);$base=[IO.Path]::GetPathRoot($full)
    if($full.Length -gt $base.Length){return $full.TrimEnd('\','/')}
    $full
}
function Convert-TransportLF([string]$Text) {$Text.Replace("`r",'').TrimStart([char]0xFEFF)}
function Read-TransportJson([string]$Path) {ConvertFrom-Json (Convert-TransportLF ([IO.File]::ReadAllText($Path)))}
function Convert-TransportUtc($Value) {
    if($Value -is [DateTimeOffset]){return $Value.UtcDateTime}
    if($Value -is [DateTime]){return $Value.ToUniversalTime()}
    [DateTime]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}
function Copy-TransportObject($Value) {ConvertFrom-Json (ConvertTo-Json -InputObject $Value -Depth 40 -Compress)}
function Get-TransportValue($Object,[string]$Name,$Default) {
    if($null -ne $Object -and $null -ne $Object.$Name){return $Object.$Name};return $Default
}
function Protect-TransportPath([string]$Path) {
    if($env:OS -eq 'Windows_NT'){
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
        if([IO.Directory]::Exists($Path)){$acl=New-Object Security.AccessControl.DirectorySecurity;$inherit=[Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'}else{$acl=New-Object Security.AccessControl.FileSecurity;$inherit=[Security.AccessControl.InheritanceFlags]::None}
        $acl.SetAccessRuleProtection($true,$false)
        $rule=New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl',$inherit,[Security.AccessControl.PropagationFlags]::None,'Allow')
        $acl.AddAccessRule($rule)
        # Только DACL: Set-Acl пишет и SACL и без SeSecurityPrivilege (не админ) падает на PS 5.1.
        if([IO.Directory]::Exists($Path)){[IO.Directory]::SetAccessControl($Path,$acl)}else{[IO.File]::SetAccessControl($Path,$acl)}
    }else{if([IO.Directory]::Exists($Path)){& chmod 700 -- $Path}else{& chmod 600 -- $Path};if($LASTEXITCODE -ne 0){throw 'Не удалось ограничить права'}}
}
function Write-TransportJson([string]$Path,$Value,[switch]$Private,[switch]$Durable) {
    $dir=[IO.Path]::GetDirectoryName($Path);[void][IO.Directory]::CreateDirectory($dir)
    $tmp=Join-Path $dir ([IO.Path]::GetRandomFileName());$backup=$tmp+'.old'
    try{
        # Файл создаётся внутри закрытого каталога, ACL задаётся до записи секрета.
        if($Private){Protect-TransportPath $dir;if([IO.File]::Exists($Path)){Protect-TransportPath $Path};[IO.File]::WriteAllText($tmp,'');Protect-TransportPath $tmp}
        $json=ConvertTo-Json -InputObject $Value -Depth 40
        if($Durable){
            $stream=New-Object IO.FileStream($tmp,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{$bytes=[Text.Encoding]::UTF8.GetBytes($json);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        }else{[IO.File]::WriteAllText($tmp,$json,(New-Object Text.UTF8Encoding($false)))}
        for($attempt=0;$attempt -lt 5;$attempt++){
            try{if([IO.File]::Exists($Path)){[IO.File]::Replace($tmp,$Path,$backup)}else{[IO.File]::Move($tmp,$Path)};break}
            catch [IO.IOException]{if($attempt -eq 4){throw};Start-Sleep -Milliseconds 20}
        }
        if($Private){Protect-TransportPath $Path}
    }finally{if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)};if([IO.File]::Exists($backup)){[IO.File]::Delete($backup)}}
}
function Protect-TransportText([string]$Text) {
    # Маскирует то, что похоже на секрет: UUID, длинные токены/ключи, пароли в URL. Адреса и порты оставляет — без них журнал бесполезен.
    if(-not $Text){return ''}
    $t=$Text -replace '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}','<uuid>'
    $t=$t -replace '[A-Za-z0-9+/_=-]{20,}','<secret>' -replace '://[^/@\s]+@','://<auth>@' -replace '[\r\n]+',' '
    if($t.Length -gt 400){$t=$t.Substring(0,400)};$t
}
function Get-TransportErrorDetail($ErrorRecord) {
    # Причина без утечки: свои сообщения скриптов (русские, без значений) пишутся как есть,
    # у чужих исключений — только тип; плюс файл и строка.
    $e=$ErrorRecord.Exception;$m=[string]$e.Message
    $text=if($m -match '[А-Яа-яЁё]' -and $m -notmatch '[A-Za-z0-9+/_=-]{12,}'){$m}else{$e.GetType().FullName}
    $text+' @'+(Split-Path -Leaf ([string]$ErrorRecord.InvocationInfo.ScriptName))+':'+$ErrorRecord.InvocationInfo.ScriptLineNumber
}
function Write-TransportLog([string]$Root,[string]$Event,$Detail='') {
    # Structured process diagnostics are sanitized with the loaded credential values before logging.
    $allowed=@('start','ready','switch','probe-ok','probe-failed','network-change','restart','api-failed','process-failed','memory-invalid','network-unavailable','stop','fatal')
    if($Event -notin $allowed){$Event='process-failed'}
    $dir=Join-Path $Root 'logs';[void][IO.Directory]::CreateDirectory($dir);$path=Join-Path $dir 'transport.log'
    if([IO.File]::Exists($path) -and (Get-Item -LiteralPath $path).Length -ge 1MB){Move-Item -LiteralPath $path -Destination ($path+'.1') -Force}
    $line=[DateTime]::UtcNow.ToString('o')+' '+$Event
    # Plain exception text is rejected; callers supply a sanitized diagnostic or safe script location.
    if($Detail -is [pscustomobject] -and $Detail.PSObject.Properties['reason']){$line+=' '+(Format-TransportDiagnostic $Detail)}
    elseif($Detail -match '^(.+) @[\w.-]+:\d+$'){$head=$Matches[1];if($head -match '^[A-Za-z0-9_.]+$' -or ($head -match '[А-Яа-яЁё]' -and $head -notmatch '[A-Za-z0-9+/_=-]{12,}')){$line+=' '+$Detail}}
    [IO.File]::AppendAllText($path,($line+"`n"),(New-Object Text.UTF8Encoding($false)))
}
function Quote-Transport([string]$Value) {'"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'}
function Get-TransportPowerShell {
    if($env:OS -eq 'Windows_NT'){return (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe')}
    (Get-Process -Id $PID).Path
}
function Start-TransportProcess([string]$Exe,[string[]]$Arguments,[switch]$Probe) {
    Initialize-TransportDiagnostics
    $si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=$Exe
    $si.Arguments=(@($Arguments|ForEach-Object {Quote-Transport (Convert-TransportLF $_)})) -join ' '
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.StandardOutputEncoding=New-Object Text.UTF8Encoding($false);$si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    $p=New-Object Diagnostics.Process;$p.StartInfo=$si
    try{
        [void]$p.Start();$p.StandardInput.Close()
        $errBuffer=New-Object RemoteAgents.TransportErrorBuffer
        $err=$p.StandardError.BaseStream.CopyToAsync($errBuffer);$out=$null
        if(-not $Probe){$out=$p.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)}
        [pscustomobject]@{Process=$p;ErrorDrain=$err;ErrorBuffer=$errBuffer;OutputDrain=$out}
    }catch{try{if(-not $p.HasExited){$p.Kill();[void]$p.WaitForExit(2000)}}catch{};$p.Dispose();$ex=New-Object Exception('Не удалось запустить дочерний процесс');$ex.Data['transportDiagnostic']=New-TransportDiagnostic $null 'process' 'start-failed';throw $ex}
}
function Stop-TransportProcess($Child) {
    if(-not $Child){return};$p=$Child.Process
    try{if(-not $p.HasExited){
        if($env:OS -eq 'Windows_NT'){& "$env:SystemRoot/System32/taskkill.exe" /PID $p.Id /T /F 2>$null | Out-Null}
        if(-not $p.HasExited){$p.Kill()};[void]$p.WaitForExit(2000)
    }}catch{}finally{$p.Dispose()}
}
function Invoke-TransportText([string]$Exe,[string[]]$Arguments) {
    $c=Start-TransportProcess $Exe $Arguments -Probe
    try{
        $task=$c.Process.StandardOutput.ReadToEndAsync()
        if(-not $c.Process.WaitForExit(15000)){throw 'Таймаут SSH'}
        if($c.Process.ExitCode -ne 0){throw 'SSH не выполнен'}
        Convert-TransportLF $task.GetAwaiter().GetResult()
    }finally{Stop-TransportProcess $c}
}
# Shared by onboarding, later wizard processes, disk bootstrap and persistent OpenSSH tunnels.
function Get-TransportHopArguments($Hop,[string]$KnownHosts='',[switch]$AcceptNew) {
    $a=@('-o','BatchMode=yes','-o','ConnectTimeout=8','-o','ForwardAgent=no')
    if($Hop.configPath){$a+=@('-F',[string]$Hop.configPath)}
    if($Hop.keyFile){$a+=@('-i',[string]$Hop.keyFile,'-o','IdentitiesOnly=yes')}
    $a+=@('-o',('StrictHostKeyChecking='+$(if($AcceptNew){'accept-new'}else{'yes'})))
    if($KnownHosts){$a+=@('-o',('UserKnownHostsFile="'+$KnownHosts.Replace('\','/')+'"'),'-o','GlobalKnownHostsFile=none')}
    $address=[string](Get-TransportValue $Hop 'ssh' $Hop.alias)
    # Wizard endpoints may contain :port; OpenSSH expects it as -p before the destination.
    $m=[regex]::Match($address,'\A(?:([a-z_][a-z0-9_-]{0,31})@)?([a-zA-Z0-9][a-zA-Z0-9.-]{0,252}):(\d{1,5})\z')
    if($m.Success){
        $port=[int]$m.Groups[3].Value;if($port -lt 1 -or $port -gt 65535){throw 'Неверный порт промежуточного сервера'}
        if($m.Groups[1].Success){$a+=@('-l',$m.Groups[1].Value)}
        $a+=@('-p',[string]$port);$address=$m.Groups[2].Value
    }
    if(-not $address -or $address -match '^[\-]|[\r\n]'){throw 'Неверный SSH-алиас'}
    # Destination is returned separately so callers can insert -G / -W before it.
    [pscustomobject]@{options=$a;target=$address}
}
function New-TransportRouteOptions($Route,$Profile,[string]$ProxyExecutable='',[switch]$AcceptNew) {
    if(-not $Route -or $Route.used -eq 'direct'){return}
    if($Profile.routeProxyCommand){return @('-o',('ProxyCommand='+[string]$Profile.routeProxyCommand))}
    switch([string]$Route.used){
        'proxy' {
            $px=$Route.proxy;$port=0
            if(([string]$px.type -notin @('socks','http')) -or -not ([string]$px.host -match '\A[a-zA-Z0-9][a-zA-Z0-9.:-]{0,252}\z') -or -not [int]::TryParse([string]$px.port,[ref]$port) -or $port -lt 1 -or $port -gt 65535){throw 'Укажите корректный адрес и порт прокси'}
            if(-not $ProxyExecutable -or -not (Test-Path -LiteralPath $ProxyExecutable -PathType Leaf)){throw 'Для локального прокси нужен RemoteAgents.exe с поддержкой --proxy-connect; восстановите программу и повторите'}
            $cmd=(Quote-Transport $ProxyExecutable)+' --proxy-connect '+$px.type+' '+$px.host+' '+$port+' %h %p'
            @('-o',('ProxyCommand='+$cmd));return
        }
        'hop' {
            $hop=$Route.hop
            if($hop.routePasswordFile){
                if(-not $ProxyExecutable -or -not (Test-Path -LiteralPath $ProxyExecutable -PathType Leaf)){throw 'Для пароля SSH-перехода нужен установленный RemoteAgents.exe'}
                $source=Join-Path $PSScriptRoot 'Route.Proxy.ps1'
                $directory=Join-Path (Split-Path $ProxyExecutable -Parent) 'transport-bin';[void][IO.Directory]::CreateDirectory($directory);Protect-TransportPath $directory
                $helper=Join-Path $directory ('Route.Proxy-'+(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.Substring(0,16)+'.ps1')
                if(-not (Test-Path $helper)){Copy-Item -LiteralPath $source -Destination $helper;Protect-TransportPath $helper}
                $cmd=(Quote-Transport (Get-TransportPowerShell))+' -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '+(Quote-Transport $helper)+' -SettingsFile '+(Quote-Transport ([string]$hop.routePasswordFile))+' -Target %h -Port %p'
                return @('-o',('ProxyCommand='+$cmd))
            }
            if(-not $hop.keyFile -and -not $hop.passwordPipe){throw 'Нужен ключ для промежуточного сервера: выберите файл ключа на шаге «Сервер»'}
            if([string]$hop.ssh -notmatch '\A(?:[a-z_][a-z0-9_-]{0,31}@)?[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}(?::\d{1,5})?\z'){throw 'Укажите промежуточный сервер как логин@адрес[:порт]'}
            $known=Join-Path (Split-Path $Profile.knownHostsPath -Parent) 'known_hosts-hop'
            if($hop.knownHostsPath){$known=[string]$hop.knownHostsPath}
            $h=Get-TransportHopArguments $hop $known -AcceptNew:$AcceptNew
            $a=@([string]$Profile.sshExecutable,'-q','-o','ProxyCommand=none','-o','ProxyJump=none');if($Profile.configPath){$a+=@('-F',[string]$Profile.configPath)}
            $a+=@($h.options)
            $pipe=[string]$hop.passwordPipe
            if($pipe){
                if($pipe -notmatch '\ARemoteAgents\.Password\.[0-9a-f]{32}\z' -or -not $ProxyExecutable -or $ProxyExecutable.Contains('"')){throw 'Некорректный канал пароля промежуточного сервера'}
                $a=$a|ForEach-Object {if($_ -eq 'BatchMode=yes'){'BatchMode=no'}else{$_}}
                $a+=@('-o','NumberOfPasswordPrompts=1','-o','PreferredAuthentications=password,keyboard-interactive','-o','KbdInteractiveAuthentication=yes','-o','PubkeyAuthentication=no')
            }
            $line=(@(($a+@('-W','%h:%p',$h.target))|ForEach-Object {if($_ -match '[\s"]'){Quote-Transport $_}else{$_}})) -join ' '
            if($pipe){$line='set "SSH_ASKPASS='+$ProxyExecutable+'"&& set "SSH_ASKPASS_REQUIRE=force"&& set "DISPLAY=remoteagents:0"&& set "REMOTEAGENTS_PASSWORD_PIPE='+$pipe+'"&& '+$line}
            @('-o',('ProxyCommand='+$line));return
        }
        default {throw 'Неизвестный сохранённый маршрут сервера; выберите маршрут на шаге «Сервер»'}
    }
}
function Get-TransportSavedRoute([string]$Root) {
    $file=Join-Path $Root 'config.json'
    if(Test-Path -LiteralPath $file){return (Read-TransportJson $file).wizard.serverRoute}
}
function Get-TransportSavedRouteOptions([string]$Root,$Profile) {
    New-TransportRouteOptions (Get-TransportSavedRoute $Root) $Profile (Join-Path $Root 'RemoteAgents.exe')
}
function Get-TransportRouteOverlay($Route,[string]$Root) {
    if(-not $Route -or $Route.used -eq 'direct'){return $null}
    $copy=Copy-TransportObject $Route
    if($copy.used -eq 'proxy'){$copy|Add-Member -Force proxyExecutable (Join-Path $Root 'RemoteAgents.exe')}
    return $copy
}
function Read-TransportSettings([string]$Root) {
    $config=Read-TransportJson (Join-Path $Root 'config.json');$t=$config.transport
    if(-not $t){throw 'Нет секции transport'}
    $profilePath=[string]$t.profilePath
    if(-not $profilePath){throw 'Нет transport.profilePath в config.json'}
    $profile=Read-TransportJson $profilePath
    foreach($f in @('sshExecutable','serverAddress','login','keyPath','knownHostsPath')){if(-not $profile.$f){throw 'Неполный SSH-профиль'}}
    if($profile.login.Trim() -ieq 'root'){throw 'Нужен SSH-профиль рабочего пользователя'}
    $channelPath=[string]$t.channelPath
    if(-not $channelPath){throw 'Нет transport.channelPath в config.json'}
    $channel=Read-TransportJson $channelPath
    $defaults=@{sshPort=2222;channelSocksPort=2223;syncPort=22001;probePortBase=26000;socksPortBase=28000;apiPort=29090;bindPhysical=$true;activeProbeBytes=65536;rankProbeBytes=262144;activeIntervalSec=120;meteredActiveIntervalSec=300;rankIntervalSec=1800;rankConcurrency=1;topOnMetered=3;stallSeconds=5;probeTimeoutSec=45;metered='auto';restartDelaySec=3;openSsh=$true;singBoxPath=(Join-Path $PSScriptRoot 'sing-box.exe')}
    $s=@{};foreach($k in $defaults.Keys){$s[$k]=Get-TransportValue $t $k $defaults[$k]}
    foreach($k in @('bindPhysical','openSsh')){if($s[$k] -isnot [bool]){throw 'Нужен логический параметр transport'}}
    foreach($k in @('sshPort','channelSocksPort','syncPort','probePortBase','socksPortBase','apiPort')){if([int]$s[$k] -lt 1 -or [int]$s[$k] -gt 65535){throw 'Неверный порт transport'}}
    foreach($k in @('activeProbeBytes','rankProbeBytes','activeIntervalSec','meteredActiveIntervalSec','rankIntervalSec','rankConcurrency','topOnMetered','stallSeconds','probeTimeoutSec','restartDelaySec')){if([double]$s[$k] -le 0){throw 'Параметры transport должны быть положительными'}}
    if([string]$s.metered -notin @('auto','true','false','True','False')){throw 'Неверный metered'}
    if(-not $t.serverRoute -and $config.wizard.serverRoute){$overlay=Get-TransportRouteOverlay $config.wizard.serverRoute $Root;if($overlay){$t|Add-Member -Force serverRoute $overlay}}
    Assert-TransportLists $t
    [pscustomobject]@{Options=$s;Transport=$t;Profile=$profile;Channel=$channel;Vpn=(Get-TransportValue $config 'vpn' ([pscustomobject]@{enabled=$false}))}
}
function Get-TransportSshArguments($Profile,[int]$Port,[switch]$UseRoute) {
    # Явные параметры профиля исключают ProxyCommand/forwarding/RemoteCommand из пользовательского config.
    $nullConfig='NUL';if($env:OS -ne 'Windows_NT'){$nullConfig='/dev/null'}
    $bootstrapProxy=if($UseRoute -and $Profile.routeProxyCommand){'ProxyCommand='+[string]$Profile.routeProxyCommand}else{'ProxyCommand=none'}
    @('-n','-T','-F',$nullConfig,'-p',[string]$Port,'-i',[string]$Profile.keyPath,'-l',[string]$Profile.login,
      '-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','GlobalKnownHostsFile=none','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile="'+$Profile.knownHostsPath.Replace('\','/')+'"'),
      '-o',('HostKeyAlias='+$Profile.serverAddress),'-o',$bootstrapProxy,'-o','ProxyJump=none','-o','ConnectTimeout=10','-o','ConnectionAttempts=1','-o','LogLevel=ERROR')
}
function Get-TransportServerPort($Profile) {
    $a=@($Profile.arguments);$at=[array]::IndexOf($a,'-p')
    if($at -ge 0 -and $at+1 -lt $a.Count){return [int]$a[$at+1]};return 22
}
function Get-TransportHostKeys([string]$Ssh,[string]$HostName,[string]$KnownHosts) {
    $keygen='ssh-keygen.exe';$resolved=Get-Command $Ssh -ErrorAction SilentlyContinue
    if($resolved -and $resolved.Source){$keygen=Join-Path ([IO.Path]::GetDirectoryName($resolved.Source)) 'ssh-keygen.exe'}
    if($env:OS -ne 'Windows_NT'){$keygen='ssh-keygen'}
    $text=Invoke-TransportText $keygen @('-F',$HostName,'-f',$KnownHosts)
    $keys=@();foreach($line in $text -split "`n"){
        # CA/revoked строки требуют иного trust-policy: не трактуем как обычный ключ.
        if($line -match '^\S+\s+((?:ssh-|ecdsa-)[^ ]+\s+[A-Za-z0-9+/=]+)'){$keys+=$Matches[1]}
    }
    if(-not $keys.Count){throw 'Нет закреплённого host key'};$keys
}
# sing-box 1.14 passes this list to SSH negotiation before checking host_key.
# Restrict negotiation to pinned key types; RSA key format stays ssh-rsa with SHA2 signatures.
function Set-TransportHostKeyAlgorithms($Outbound) {
    $algorithms=@(foreach($key in @($Outbound.host_key)){
        $type=([string]$key).Trim() -split '\s+' | Select-Object -First 1
        switch -Exact ($type){
            'ssh-rsa' {'rsa-sha2-512';'rsa-sha2-256'}
            {$_ -in @('ssh-ed25519','ecdsa-sha2-nistp256','ecdsa-sha2-nistp384','ecdsa-sha2-nistp521')} {$type}
            default {throw 'Неподдерживаемый тип закреплённого SSH host key'}
        }
    })
    $algorithms=@($algorithms|Select-Object -Unique)
    if(-not $algorithms.Count){throw 'Нет закреплённого host key'}
    if($Outbound -is [hashtable]){$Outbound.host_key_algorithms=$algorithms}else{$Outbound|Add-Member -Force host_key_algorithms $algorithms}
}
function Convert-TransportHop([string]$Text) {
    $g=@{};foreach($line in (Convert-TransportLF $Text) -split "`n"){
        if($line -match '^(hostname|user|identityfile|port) (.+)$' -and -not $g.ContainsKey($Matches[1])){$g[$Matches[1]]=$Matches[2].Trim('"')}
    }
    foreach($k in @('hostname','user','identityfile','port')){if(-not $g[$k]){throw 'Неполный SSH-алиас'}}
    $userHome=[Environment]::GetFolderPath('UserProfile');if($env:USERPROFILE){$userHome=$env:USERPROFILE}
    $key=$g.identityfile.Replace('%d',$userHome);if($key -match '^~(?=[\\/]|$)'){$key=$userHome+$key.Substring(1)}
    @{type='ssh';server=$g.hostname;server_port=[int]$g.port;user=$g.user;private_key_path=$key}
}
function Assert-TransportName([string]$Name) {if($Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$'){throw 'Имя пути: только буквы, цифры, _ и -'}}
function Get-TransportCandidates($Settings,[string]$Root) {
    $p=$Settings.Profile;$t=Copy-TransportObject $Settings.Transport;$o=$Settings.Options;$out=New-Object Collections.ArrayList;$c=New-Object Collections.ArrayList;$tunnels=New-Object Collections.ArrayList
    # Personal route is a local overlay, kept outside the public server catalog.
    $route=$t.serverRoute
    if($route -and $route.used -ne 'direct' -and -not $p.routeProxyCommand){
        $proxyExe=[string]$route.proxyExecutable;if(-not $proxyExe){$proxyExe=Join-Path $Root 'RemoteAgents.exe'}
        $routeOptions=@(New-TransportRouteOptions $route $p $proxyExe)
        if($route.used -eq 'hop'){
            if(-not $o.openSsh -and -not @($Settings.Channel.outbounds|Where-Object {$_.type -eq 'vless'}).Count){throw 'Для выбранного промежуточного сервера включите OpenSSH в настройках связи'}
            $hop=Copy-TransportObject $route.hop
            # A stable local name replaces a public homonym only inside this effective overlay.
            $hop|Add-Member -Force name 'wizard-server-route';$hop|Add-Member -Force enabled $true
            $hop|Add-Member -Force configPath ([string]$p.configPath)
            $hop|Add-Member -Force knownHostsPath (Join-Path (Split-Path $p.knownHostsPath -Parent) 'known_hosts-hop')
            $t|Add-Member -Force hops (@($t.hops|Where-Object {$_ -and $_.name -ne $hop.name})+@($hop))
        }
    }
    $vless=@($Settings.Channel.outbounds|Where-Object {$_.type -eq 'vless'}|Select-Object -First 1)
    $v=$null
    if($vless.Count){
    $v=Copy-TransportObject $vless[0];$v.tag='vless-direct';$v.server=$p.serverAddress
    if($v.PSObject.Properties['detour']){$v.PSObject.Properties.Remove('detour')}
    [void]$out.Add($v);[void]$c.Add([pscustomobject]@{tag=$v.tag;port=0})
    }
    if(-not $t.bootstrap -or ((Test-Path $p.knownHostsPath) -and (Get-Item $p.knownHostsPath).Length -gt 1)){
    $ssh=@{type='ssh';tag='singbox-ssh-direct';server=$p.serverAddress;server_port=(Get-TransportServerPort $p);user=$p.login;private_key_path=$p.keyPath}
    $saved=@($Settings.Channel.outbounds|Where-Object {$_.type -eq 'ssh' -and $_.server -eq $p.serverAddress}|Select-Object -First 1)
    if($saved.Count){$ssh=Copy-TransportObject $saved[0];$ssh.tag='singbox-ssh-direct';if($ssh.PSObject.Properties['detour']){$ssh.PSObject.Properties.Remove('detour')}}
    if(-not $ssh.host_key){$hk=@(Get-TransportHostKeys $p.sshExecutable $p.serverAddress $p.knownHostsPath);if($ssh -is [hashtable]){$ssh.host_key=$hk}else{$ssh|Add-Member -Force host_key $hk}}
    Set-TransportHostKeyAlgorithms $ssh
    [void]$out.Add($ssh);[void]$c.Add([pscustomobject]@{tag=$ssh.tag;port=0})
    }
    foreach($relay in @($t.relays)){
        if($null -eq $relay -or -not (Test-TransportEnabled $relay)){continue};Assert-TransportName $relay.name
        if(-not (Get-TransportValue $relay 'host' $relay.server) -or [int]$relay.port -lt 1 -or [int]$relay.port -gt 65535){throw 'Неполный ретранслятор'}
        if(-not $v){throw 'Для relay нужен VLESS канала сервера'}
        $r=Copy-TransportObject $v;$r.tag='vless-relay-'+$relay.name;$r.server=(Get-TransportValue $relay 'host' $relay.server);$r.server_port=[int]$relay.port
        [void]$out.Add($r);[void]$c.Add([pscustomobject]@{tag=$r.tag;port=0})
    }
    foreach($hop in @($t.hops)){
        if($null -eq $hop -or -not (Test-TransportEnabled $hop)){continue};Assert-TransportName $hop.name
        if(-not $v){continue}
        if(-not (Get-TransportValue $hop 'ssh' $hop.alias) -or (Get-TransportValue $hop 'ssh' $hop.alias) -match '^[\-]|[\r\n]'){throw 'Неверный SSH-алиас'}
        $resolved=Get-TransportHopArguments $hop ([string]$hop.knownHostsPath)
        $ha=@('-n','-G')+@($resolved.options)+@($resolved.target)
        $hopText=Invoke-TransportText $p.sshExecutable $ha;$h=Convert-TransportHop $hopText;if($hop.keyFile){$h.private_key_path=[string]$hop.keyFile};$h.tag='hop-'+$hop.name
        if($hop.knownHostsPath){
            $hostName=$h.server;if($h.server_port -ne 22){$hostName='['+$h.server+']:'+$h.server_port}
            $h.host_key=@(Get-TransportHostKeys $p.sshExecutable $hostName $hop.knownHostsPath)
        }elseif($hop.hostKey){$h.host_key=@($hop.hostKey)}else{
            $known=Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh/known_hosts'
            foreach($line in $hopText -split "`n"){if($line -match '^userknownhostsfile ("[^"]+"|\S+)'){$known=$Matches[1].Trim('"');break}}
            $userHome=[Environment]::GetFolderPath('UserProfile');$known=$known.Replace('%d',$userHome);if($known -match '^~(?=[\\/]|$)'){$known=$userHome+$known.Substring(1)}
            $hostName=$h.server;if($h.server_port -ne 22){$hostName='['+$h.server+']:'+$h.server_port}
            $h.host_key=@(Get-TransportHostKeys $p.sshExecutable $hostName $known)
        }
        Set-TransportHostKeyAlgorithms $h
        [void]$out.Add($h);$r=Copy-TransportObject $v;$r.tag='vless-sshhop-'+$hop.name;$r|Add-Member detour $h.tag
        [void]$out.Add($r);[void]$c.Add([pscustomobject]@{tag=$r.tag;port=0})
    }
    foreach($entry in @($t.entries)){
        if($null -eq $entry -or -not (Test-TransportEnabled $entry)){continue};Assert-TransportName $entry.name
        $e=Read-TransportJson (Join-Path (Get-TransportCacheRoot $Settings $Root) ('secrets/entries/'+$entry.name+'.json'));$x=$e.secrets;$name=$entry.name
        foreach($f in @('server','sni','cover','ports','secrets')){if(-not $e.$f){throw 'Неполный client.json узла'}}
        $tls=@{enabled=$true;server_name=$e.sni;insecure=[bool]$e.insecure}
        $list=@(
            @{type='hysteria2';tag="hy2-$name";server=$e.server;server_port=[int]$e.ports.hy2;password=$x.hy2;tls=($tls+@{alpn=@('h3')})},
            @{type='hysteria2';tag="hy2obfs-$name";server=$e.server;server_port=[int]$e.ports.hy2_obfs;password=$x.hy2;obfs=@{type='salamander';password=$x.hy2_obfs};tls=($tls+@{alpn=@('h3')})},
            @{type='tuic';tag="tuic-$name";server=$e.server;server_port=[int]$e.ports.tuic;uuid=$x.tuic_uuid;password=$x.tuic;congestion_control='bbr';tls=($tls+@{alpn=@('h3')})},
            @{type='trojan';tag="trojan-$name";server=$e.server;server_port=[int]$e.ports.trojan;password=$x.trojan;tls=$tls},
            @{type='vless';tag="reality-$name";server=$e.server;server_port=[int]$e.ports.reality;uuid=$x.vless_uuid;flow='xtls-rprx-vision';tls=@{enabled=$true;server_name=$e.cover;utls=@{enabled=$true;fingerprint='chrome'};reality=@{enabled=$true;public_key=$x.reality_public;short_id=$x.short_id}}},
            @{type='shadowsocks';tag="shadowtls-$name";method='2022-blake3-aes-128-gcm';password=$x.ss;detour="stls-$name"}
        )
        [void]$out.Add(@{type='shadowtls';tag="stls-$name";server=$e.server;server_port=[int]$e.ports.shadowtls;version=3;password=$x.shadowtls;tls=@{enabled=$true;server_name=$e.cover;utls=@{enabled=$true;fingerprint='chrome'}}})
        if($x.ws_path){
            $ws=@{type='ws';path=$x.ws_path;max_early_data=2048;early_data_header_name='Sec-WebSocket-Protocol'}
            $domain=$e.sni;if($e.domain){$domain=$e.domain}
            $list+=@{type='vless';tag="ws-direct-$name";server=$e.server;server_port=443;uuid=$x.ws_uuid;tls=@{enabled=$true;server_name=$domain;insecure=$true;alpn=@('http/1.1');utls=@{enabled=$true;fingerprint='chrome'}};transport=($ws+@{headers=@{Host=$domain}})}
            # DNS проверит сам sing-box при пробе; генерация конфигурации не требует сети.
            if($e.domain){$list+=@{type='vless';tag="ws-cdn-$name";server=$e.domain;server_port=443;uuid=$x.ws_uuid;tls=@{enabled=$true;server_name=$e.domain;alpn=@('http/1.1');utls=@{enabled=$true;fingerprint='chrome'}};transport=($ws+@{headers=@{Host=$e.domain}})}}
        }
        foreach($r in $list){$kind=$r.tag.Substring(0,$r.tag.Length-$name.Length-1);if($entry.kinds -and $kind -notin @($entry.kinds)){continue};[void]$out.Add($r);[void]$c.Add([pscustomobject]@{tag=$r.tag;port=0})}
    }
    foreach($cdn in @($t.cdn)){
        if($null -eq $cdn -or -not (Test-TransportEnabled $cdn)){continue}
        $e=Read-TransportJson (Join-Path (Get-TransportCacheRoot $Settings $Root) ('secrets/entries/'+$cdn.entry+'.json'));$x=$e.secrets
        if(-not $x.ws_uuid -or -not $x.ws_path){throw 'Узел не содержит WebSocket'}
        $r=@{type='vless';tag=('cdn-'+$cdn.name);server=$cdn.domain;server_port=443;uuid=$x.ws_uuid;
            tls=@{enabled=$true;server_name=$cdn.domain;alpn=@('http/1.1');utls=@{enabled=$true;fingerprint='chrome'}};
            transport=@{type='ws';path=(Get-TransportValue $cdn 'path' $x.ws_path);headers=@{Host=$cdn.domain};max_early_data=2048;early_data_header_name='Sec-WebSocket-Protocol'}}
        [void]$out.Add($r);[void]$c.Add([pscustomobject]@{tag=$r.tag;port=0})
    }
    # The saved route may be the daemon's own channel SOCKS (channel first): tunnels then go direct, never through themselves.
    $ownChannel=($route -and $route.used -eq 'proxy' -and [string]$route.proxy.host -in @('127.0.0.1','localhost') -and [int]$route.proxy.port -eq [int]$o.channelSocksPort)
    # OpenSSH из профиля + SOCKS (-D): один туннель несёт и SSH, и Syncthing через selector.
    if($o.openSsh){
        $port=[int]$o.socksPortBase
        [void]$out.Add(@{type='socks';tag='openssh-direct';server='127.0.0.1';server_port=$port;version='5'})
        [void]$c.Add([pscustomobject]@{tag='openssh-direct';port=0})
        $serverPort=Get-TransportServerPort $p
        $a=@(Get-TransportSshArguments $p $serverPort -UseRoute:(-not $ownChannel))+@('-N','-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2','-D',('127.0.0.1:'+$port))
        [void]$tunnels.Add([pscustomobject]@{tag='openssh-direct';arguments=$a;target=$p.serverAddress;bind=$true})
    }
    if($o.openSsh){
        foreach($hop in @($t.hops)){
            if($null -eq $hop -or -not (Test-TransportEnabled $hop)){continue}
            $port=[int]$o.socksPortBase+$tunnels.Count;$tag='openssh-jump-'+$hop.name
            [void]$out.Add(@{type='socks';tag=$tag;server='127.0.0.1';server_port=$port;version='5'})
            [void]$c.Add([pscustomobject]@{tag=$tag;port=0})
            $resolved=Get-TransportHopArguments $hop ([string]$hop.knownHostsPath)
            $proxy=@([string]$p.sshExecutable)+@($resolved.options)+@('-W','%h:%p',$resolved.target)
            $command=(@($proxy|ForEach-Object {Quote-Transport $_})) -join ' '
            $a=@(Get-TransportSshArguments $p (Get-TransportServerPort $p))|ForEach-Object {if($_ -like 'ProxyCommand=*'){'ProxyCommand='+$command}else{$_}}
            $a+=@('-N','-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2','-D',('127.0.0.1:'+$port))
            [void]$tunnels.Add([pscustomobject]@{tag=$tag;arguments=$a;target=$p.serverAddress;bind=$false})
        }
    }
    # A saved route through the daemon's own channel SOCKS entry must not become a daemon path: that is a loop.
    if($route -and $route.used -eq 'proxy' -and -not $ownChannel){
        if(-not $o.openSsh){throw 'Для выбранного локального прокси включите OpenSSH в настройках связи'}
        $port=[int]$o.socksPortBase+$tunnels.Count;$tag='openssh-proxy'
        [void]$out.Add(@{type='socks';tag=$tag;server='127.0.0.1';server_port=$port;version='5'})
        [void]$c.Add([pscustomobject]@{tag=$tag;port=0})
        $a=@(Get-TransportSshArguments $p (Get-TransportServerPort $p))|ForEach-Object {if($_ -eq 'ProxyCommand=none'){$routeOptions[1]}else{$_}}
        $a+=@('-N','-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2','-D',('127.0.0.1:'+$port))
        [void]$tunnels.Add([pscustomobject]@{tag=$tag;arguments=$a;target=$p.serverAddress;bind=$false})
    }
    $tags=@{};$i=0;$all=New-Object Collections.ArrayList
    foreach($r in $out){if($tags.ContainsKey($r.tag)){throw 'Повтор имени пути'};$tags[$r.tag]=$true}
    foreach($r in $c){
        $meta=Get-TransportCandidateInfo $r.tag $t
        $r|Add-Member -Force title $meta.title;$r|Add-Member -Force kind $meta.kind;$r|Add-Member -Force via $meta.via
        $r|Add-Member -Force tunCapable (Test-TransportInternetPath $r.tag @($out.ToArray()))
        $r|Add-Member -Force enabled ($r.tag -notin @($t.disabledTags));$r.port=[int]$o.probePortBase+$i;$i++
        [void]$all.Add($r)
    }
    # Отключённый узел не требует SSH или кэша секретов, но остаётся виден в трее.
    foreach($group in @('entries','relays','hops','cdn')){foreach($item in @($t.$group)){
        if($null -eq $item -or (Test-TransportEnabled $item)){continue}
        $disabled=@();switch($group){
            'entries' {$kinds=@('hy2','hy2obfs','tuic','trojan','reality','shadowtls','ws-direct','ws-cdn');if($item.kinds){$kinds=@($item.kinds)};foreach($k in $kinds){$disabled+=($k+'-'+$item.name)}}
            'relays' {$disabled+=('vless-relay-'+$item.name)}
            'hops' {$disabled+=('vless-sshhop-'+$item.name);if($o.openSsh){$disabled+=('openssh-jump-'+$item.name)}}
            'cdn' {$disabled+=('cdn-'+$item.name)}
        }
        foreach($tag in $disabled){$meta=Get-TransportCandidateInfo $tag $t;[void]$all.Add([pscustomobject]@{tag=$tag;port=0;title=$meta.title;kind=$meta.kind;via=$meta.via;enabled=$false;tunCapable=$false})}
    }}
    $enabled=@($all.ToArray()|Where-Object {$_.enabled});$enabledTags=@($enabled|ForEach-Object {$_.tag})
    # Не оставляем выключенные внешние сокеты/SSH-туннели в рабочем процессе.
    $needed=@{};foreach($tag in $enabledTags){Add-TransportDependency $tag @($out.ToArray()) $needed}
    [pscustomobject]@{Outbounds=@($out.ToArray()|Where-Object {$needed.ContainsKey($_.tag)});Candidates=$enabled;AllCandidates=@($all.ToArray());Tunnels=@($tunnels.ToArray()|Where-Object {$_.tag -in $enabledTags})}
}

function New-TransportConfig($Settings,$Paths,[string]$Secret,[string]$DefaultTag,[string]$Interface='') {
    $o=$Settings.Options;$sync=@($Settings.Channel.inbounds|Where-Object {$_.tag -eq 'sync'}|Select-Object -First 1)
    if($sync.Count -and ([int]$sync[0].override_port -lt 1 -or [int]$sync[0].override_port -gt 65535)){throw 'Неверный порт Syncthing канала'}
    $in=@();$rules=@();$ports=@{}
    $targets=New-Object Collections.ArrayList;[void]$targets.Add(@('ssh',[int]$o.sshPort,(Get-TransportServerPort $Settings.Profile)))
    if($sync.Count){[void]$targets.Add(@('sync',[int]$o.syncPort,[int]$sync[0].override_port))}
    # Channel first (config.transport.channelFirst): a loopback SOCKS entry to the server's sshd through the active path,
    # the same meaning as the 'ssh' entry; the wizard's SSH uses it as a 'proxy' route before any other route.
    if($Settings.Transport.channelFirst){
        $in+=@{type='mixed';tag='channel-socks';listen='127.0.0.1';listen_port=[int]$o.channelSocksPort}
        $rules+=@{inbound=@('channel-socks');action='route-options';override_address='127.0.0.1';override_port=(Get-TransportServerPort $Settings.Profile)}
        $rules+=@{inbound=@('channel-socks');action='route';outbound='active'}
    }
    foreach($row in $targets){
        $in+=@{type='direct';tag=$row[0];listen='127.0.0.1';listen_port=$row[1];network='tcp';override_address='127.0.0.1';override_port=$row[2]}
        $rules+=@{inbound=@($row[0]);action='route';outbound='active'}
    }
    foreach($c in $Paths.Candidates){$tag='probe-'+$c.tag;$in+=@{type='direct';tag=$tag;listen='127.0.0.1';listen_port=$c.port;network='tcp';override_address='127.0.0.1';override_port=(Get-TransportServerPort $Settings.Profile)};$rules+=@{inbound=@($tag);action='route';outbound=$c.tag}}
    foreach($port in @(@($in|ForEach-Object {$_.listen_port})+@([int]$o.apiPort)+@($Paths.Outbounds|Where-Object {$_.type -eq 'socks'}|ForEach-Object {$_.server_port}))){
        if($port -lt 1 -or $port -gt 65535 -or $ports.ContainsKey([int]$port)){throw 'Пересечение или неверный порт'};$ports[[int]$port]=$true
    }
    $tags=@($Paths.Candidates|ForEach-Object {$_.tag})+@('unavailable');if($DefaultTag -notin $tags){$DefaultTag='unavailable'}
    $outs=@();foreach($r in $Paths.Outbounds){$copy=Copy-TransportObject $r
        # bind_interface только на внешнем сокете: detour и локальный SOCKS не привязываются.
        if($o.bindPhysical -and $Interface -and -not $copy.detour -and $copy.type -ne 'socks'){$copy|Add-Member -Force bind_interface $Interface}
        $outs+=$copy
    }
    $outs+=@{type='socks';tag='unavailable';server='127.0.0.1';server_port=1;version='5'}
    $outs+=@{type='selector';tag='active';outbounds=$tags;default=$DefaultTag;interrupt_exist_connections=$false}
    @{log=@{disabled=$false;level='error';timestamp=$false};inbounds=$in;outbounds=$outs;route=@{rules=$rules;final='active';auto_detect_interface=[bool]$o.bindPhysical};experimental=@{clash_api=@{external_controller=('127.0.0.1:'+$o.apiPort);secret=$Secret}}}
}
function Get-TransportSecret([string]$Root) {
    $file=Join-Path $Root 'state/transport-secret.json'
    if(Test-Path -LiteralPath $file){Protect-TransportPath ([IO.Path]::GetDirectoryName($file));Protect-TransportPath $file;$value=Read-TransportJson $file;if($value.secret -match '^[A-Za-z0-9+/=]{40,}$'){return [string]$value.secret};throw 'Неверный секрет API'}
    $bytes=New-Object byte[] 32;$rng=[Security.Cryptography.RandomNumberGenerator]::Create();try{$rng.GetBytes($bytes)}finally{$rng.Dispose()}
    $secret=[Convert]::ToBase64String($bytes);Write-TransportJson $file @{secret=$secret} -Private;$secret
}
function Set-TransportSelector($Options,[string]$Secret,[string]$Tag) {
    # WebRequest без системного прокси: локальный API не зависит от Happ/WinHTTP.
    $req=[Net.HttpWebRequest]::Create(('http://127.0.0.1:'+$Options.apiPort+'/proxies/active'));$req.Proxy=$null;$req.Method='PUT';$req.Timeout=1500;$req.ContentType='application/json';$req.Headers['Authorization']='Bearer '+$Secret
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress @{name=$Tag}));$req.ContentLength=$bytes.Length
    try{$s=$req.GetRequestStream();try{$s.Write($bytes,0,$bytes.Length)}finally{$s.Dispose()};$response=$req.GetResponse();$response.Dispose()}catch{throw 'Локальный API transport недоступен'}
}
function New-TransportProbeState([long]$Target,[double]$Stall,[double]$Timeout) {
    [pscustomobject]@{target=$Target;stall=$Stall;timeout=$Timeout;bytes=[long]0;first=$null;last=$null;firstBytes=[long]0;state='pending';kbps=$null}
}
function Update-TransportProbeState($State,[long]$Bytes,[double]$Seconds,[bool]$Ended=$false) {
    if($State.state -ne 'pending'){return $State}
    # Даже при завершении N не принимается после уже случившейся остановки.
    if($null -ne $State.last -and $Seconds-$State.last -ge $State.stall){$State.state='frozen';return $State}
    if($Bytes -gt $State.bytes){if($null -eq $State.first){$State.first=$Seconds;$State.firstBytes=$Bytes};$State.last=$Seconds;$State.bytes=$Bytes}
    if($Bytes -ge $State.target){
        # Эффективная скорость от начала пробы: ssh.exe отдаёт поток пачками, «от первого байта» даёт сотни МБ/с.
        $State.state='ok';if($Seconds -gt 0){$State.kbps=[math]::Round($Bytes/1KB/$Seconds,2)}
    }elseif($Ended -or $Seconds -ge $State.timeout){
        if($Bytes -gt 0 -and -not $Ended){$State.state='slow'}else{$State.state='fail'}
    }
    $State
}
# Небольшой Stream нужен вместо PowerShell callback: CopyToAsync считает байты и время
# на потоке .NET без задержек цикла демона, без файла и без накопления скачанного в памяти.
function Initialize-TransportCounter {
    if('RemoteAgents.TransportCounter' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Diagnostics;
namespace RemoteAgents {
 public sealed class TransportCounter : Stream {
  readonly object gate = new object();
  long count, first, last, firstBytes, gap;
  public readonly long Started = Stopwatch.GetTimestamp();
  public long[] Snapshot() { lock(gate) return new long[]{count,first,last,firstBytes,gap}; }
  public override void Write(byte[] b,int o,int n) {
   if(n==0) return;
   long now=Stopwatch.GetTimestamp();
   lock(gate) {
    if(first==0) {first=now; firstBytes=n;} else gap=Math.Max(gap,now-last);
    count+=n; last=now;
   }
  }
  public override bool CanRead {get{return false;}}
  public override bool CanSeek {get{return false;}}
  public override bool CanWrite {get{return true;}}
  public override long Length {get{lock(gate)return count;}}
  public override long Position {get{return Length;}set{throw new NotSupportedException();}}
  public override void Flush() {}
  public override int Read(byte[] b,int o,int n){throw new NotSupportedException();}
  public override long Seek(long o,SeekOrigin s){throw new NotSupportedException();}
  public override void SetLength(long v){throw new NotSupportedException();}
 }
}
'@
}
function Start-TransportProbe($Profile,$Candidate,[long]$Bytes,$Options,[string]$Purpose) {
    Initialize-TransportCounter
    $a=@(Get-TransportSshArguments $Profile $Candidate.port)+@('127.0.0.1',('head -c '+$Bytes+' /dev/urandom'))
    $child=Start-TransportProcess $Profile.sshExecutable $a -Probe
    try{
        $sink=New-Object RemoteAgents.TransportCounter
        $copy=$child.Process.StandardOutput.BaseStream.CopyToAsync($sink)
        [pscustomobject]@{tag=$Candidate.tag;purpose=$Purpose;child=$child;sink=$sink;copy=$copy;state=(New-TransportProbeState $Bytes $Options.stallSeconds $Options.probeTimeoutSec)}
    }catch{Stop-TransportProcess $child;throw 'Не удалось начать чтение SSH'}
}
function Receive-TransportProbe($Probe) {
    # Завершённость фиксируем ДО снимка: CopyToAsync может дописать последние байты между ними.
    $completed=$Probe.copy.IsCompleted;$x=$Probe.sink.Snapshot();$freq=[double][Diagnostics.Stopwatch]::Frequency
    $elapsed=([Diagnostics.Stopwatch]::GetTimestamp()-$Probe.sink.Started)/$freq
    $s=$Probe.state;$s.bytes=$x[0]
    if($x[1] -ne 0){$s.first=($x[1]-$Probe.sink.Started)/$freq;$s.last=($x[2]-$Probe.sink.Started)/$freq;$s.firstBytes=$x[3]}
    if($x[4]/$freq -ge $s.stall -or ($null -ne $s.last -and $elapsed-$s.last -ge $s.stall -and $s.bytes -lt $s.target)){$s.state='frozen'}
    elseif($s.bytes -ge $s.target){
        $s.state='ok';$dt=($x[2]-$Probe.sink.Started)/$freq
        if($dt -gt 0){$s.kbps=[math]::Round($s.bytes/1KB/$dt,2)}
    }elseif($completed){$s.state='fail'}
    elseif($elapsed -ge $s.timeout){if($s.bytes -gt 0){$s.state='slow'}else{$s.state='fail'}}
    if($s.state -ne 'pending' -and $Probe.PSObject.Properties['child']){
        $reason='short-read';if($elapsed -ge $s.timeout){$reason='timeout'}elseif($s.state -eq 'frozen'){$reason='stalled'}elseif($s.state -eq 'ok'){$reason='ok'}
        $s|Add-Member -Force diagnostic (New-TransportDiagnostic $Probe.child $Probe.tag $reason)
    }
    $s.state -ne 'pending'
}
function Stop-TransportProbe($Probe) {
    Stop-TransportProcess $Probe.child
    try{[void]$Probe.copy.Wait(1000)}catch{}
    $Probe.sink.Dispose()
}
function Get-TransportBest($Rows,[string[]]$Allowed=@(),[switch]$Remembered) {
    @($Rows|Where-Object {($_.enabled -ne $false) -and ($_.state -eq 'ok' -or ($Remembered -and $_.state -eq 'remembered')) -and (-not $Allowed.Count -or $_.tag -in $Allowed)}|Sort-Object @{Expression={if($null -eq $_.kbps){-1}else{[double]$_.kbps}};Descending=$true},tag|Select-Object -First 1)|ForEach-Object {$_}
}
function Get-TransportRankTags($Rows,$Candidates,$Options,$Metered) {
    if($Metered -eq $false){return @($Candidates|ForEach-Object {$_.tag})}
    # Неизвестная стоимость тоже экономная; память имеет приоритет над непроверенными.
    @($Rows|Where-Object {$_.enabled -ne $false}|Sort-Object @{Expression={if($_.state -in @('ok','remembered')){0}else{1}}},@{Expression={if($null -eq $_.kbps){-1}else{[double]$_.kbps}};Descending=$true},tag|Select-Object -First ([int]$Options.topOnMetered)|ForEach-Object {$_.tag})
}
function Get-TransportFingerprint([string]$GatewayMac,[string]$ProfileName) {
    $text=(Convert-TransportLF $GatewayMac).Trim().Replace(':','').Replace('-','').ToUpperInvariant()+"`n"+(Convert-TransportLF $ProfileName).Trim()
    if(-not $GatewayMac -or -not $ProfileName){return $null}
    $sha=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Get-TransportNetwork {
    try{
        $physical=@(Get-NetAdapter -Physical -ErrorAction Stop|Where-Object {$_.Status -eq 'Up' -and ($_.Name+' '+$_.InterfaceDescription) -notmatch '(?i)tailscale|openvpn|happ|wintun|tap|tun|tunnel|hyper-v'})
        $routes=@(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop|Where-Object {$_.InterfaceIndex -in @($physical|ForEach-Object {$_.ifIndex}) -and $_.NextHop -ne '0.0.0.0'}|Sort-Object @{Expression={$_.RouteMetric+(Get-NetIPInterface -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop|Select-Object -First 1).InterfaceMetric}})
        if(-not $routes.Count){throw 'Нет физического шлюза'};$route=$routes[0];$adapter=$physical|Where-Object {$_.ifIndex -eq $route.InterfaceIndex}|Select-Object -First 1
        $profile=Get-NetConnectionProfile -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop|Select-Object -First 1
        $neighbor=Get-NetNeighbor -InterfaceIndex $route.InterfaceIndex -IPAddress $route.NextHop -ErrorAction Stop|Where-Object {$_.State -notin @('Unreachable','Incomplete') -and $_.LinkLayerAddress -notmatch '^(00[:-]){5}00$'}|Select-Object -First 1
        $ip=Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop|Where-Object {$_.AddressState -eq 'Preferred'}|Select-Object -First 1
        $id=Get-TransportFingerprint $neighbor.LinkLayerAddress $profile.Name
        [pscustomobject]@{id=$id;name=$profile.Name;interface=$adapter.Name;ip=$ip.IPAddress;available=[bool]($id -and $ip.IPAddress)}
    }catch{[pscustomobject]@{id=$null;name=$null;interface=$null;ip=$null;available=$false}}
}
function Get-TransportMetered($Options) {
    $configured=([string]$Options.metered).ToLowerInvariant();if($configured -ne 'auto'){return ($configured -eq 'true')}
    try{
        [void][Windows.Networking.Connectivity.NetworkInformation,Windows,ContentType=WindowsRuntime]
        $profile=[Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
        if($null -eq $profile){return $null};$cost=$profile.GetConnectionCost()
        switch([string]$cost.NetworkCostType){'Unrestricted'{return [bool]($cost.Roaming -or $cost.OverDataLimit -or $cost.ApproachingDataLimit)}'Fixed'{return $true}'Variable'{return $true}default{return $null}}
    }catch{return $null}
}
function Read-TransportMemory([string]$Root) {
    $file=Join-Path $Root 'state/transport-memory.json'
    if(-not (Test-Path -LiteralPath $file)){return @{version=1;networks=@{}}}
    try{
        $m=Read-TransportJson $file;if($m.version -ne 1){throw 'Версия памяти'};$n=@{}
        foreach($prop in $m.networks.PSObject.Properties){$n[$prop.Name]=$prop.Value}
        @{version=1;networks=$n}
    }catch{Write-TransportLog $Root 'memory-invalid';@{version=1;networks=@{}}}
}
function Save-TransportMemory([string]$Root,$Memory,[string]$Network,$Rows) {
    if(-not $Network){return};$Memory.networks[$Network]=@{updatedAt=[DateTime]::UtcNow.ToString('o');candidates=@($Rows)}
    Write-TransportJson (Join-Path $Root 'state/transport-memory.json') $Memory -Private
}
function Get-TransportRemembered($Memory,[string]$Network,$Candidates) {
    $saved=@();if($Network -and $Memory.networks.ContainsKey($Network)){$saved=@($Memory.networks[$Network].candidates)}
    foreach($c in $Candidates){
        $r=$saved|Where-Object {$_.tag -eq $c.tag}|Select-Object -First 1
        $state='unknown';$speed=$null;$checked=$null
        if($r){$state=$r.state;if($state -eq 'ok'){$state='remembered'};$speed=$r.kbps;$checked=$r.checkedAt}
        if($c.enabled -eq $false){$state='disabled';$speed=$null;$checked=$null}
        [pscustomobject]@{tag=$c.tag;title=$c.title;kind=$c.kind;via=$c.via;enabled=($c.enabled -ne $false);state=$state;kbps=$speed;checkedAt=$checked}
    }
}

function Test-TransportEnabled($Item) {return ((Get-TransportValue $Item 'enabled' $true) -eq $true)}
function Assert-TransportLists($Transport) {
    $names=@{}
    foreach($group in @('entries','relays','hops','cdn')){foreach($item in @($Transport.$group)){
        if($null -eq $item){continue};Assert-TransportName $item.name
        if($names.ContainsKey($item.name)){throw 'Имена узлов должны быть уникальны во всех списках'};$names[$item.name]=$true
        if((Get-TransportValue $item 'enabled' $true) -isnot [bool]){throw 'enabled должен быть boolean'}
        if($group -in @('entries','hops')){$ssh=Get-TransportValue $item 'ssh' $item.alias;if(-not $ssh -or $ssh -match '^[\-]|[\r\n]'){throw 'Неверный SSH-алиас'}}
        if($group -eq 'hops'){foreach($field in @('keyFile','knownHostsPath')){if($item.$field -and ([string]$item.$field -match '[\r\n\x00]')){throw 'Неверный локальный путь промежуточного сервера'}}}
        if($group -eq 'entries'){foreach($kind in @($item.kinds)){if($null -ne $kind -and $kind -notin @('hy2','hy2obfs','tuic','trojan','reality','shadowtls','ws-direct','ws-cdn')){throw 'Неизвестный kind'}}}
        if($group -eq 'relays'){if(-not (Get-TransportValue $item 'host' $item.server) -or [int]$item.port -lt 1 -or [int]$item.port -gt 65535){throw 'Неверный relay'}}
        if($group -eq 'cdn'){
            if($item.domain -notmatch '^(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$'){throw 'Неверный домен CDN'}
            if(-not @($Transport.entries|Where-Object {$_.name -eq $item.entry}).Count){throw 'Не найден узел CDN'}
            if($item.path -and ($item.path -notmatch '^/' -or $item.path -match '[\r\n]')){throw 'Неверный путь CDN'}
        }
    }}
    foreach($tag in @($Transport.disabledTags)){if($null -ne $tag){Assert-TransportTag $tag}}
}
function Assert-TransportTag([string]$Tag) {if($Tag -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,95}$' -or $Tag -eq 'unavailable'){throw 'Неверный tag'}}
function Get-TransportCandidateInfo([string]$Tag,$Transport) {
    $kind=$Tag;$via='сервер';$label='VLESS';$title='VLESS напрямую'
    switch -Regex ($Tag){
        '^vless-direct$' {$kind='vless';break}
        '^singbox-ssh-direct$' {$kind='ssh';$title='SSH напрямую';break}
        '^openssh-proxy$' {$kind='openssh';$via='локальный прокси';$title='OpenSSH через локальный прокси';break}
        '^openssh-direct$' {$kind='openssh';$title='OpenSSH напрямую';break}
        '^vless-relay-(.+)$' {$kind='vless-relay';$via=$Matches[1];$label='VLESS';$title=$null;break}
        '^vless-sshhop-(.+)$' {$kind='vless-sshhop';$via=$Matches[1];$label='VLESS через SSH';$title=$null;break}
        '^openssh-jump-(.+)$' {$kind='openssh';$via=$Matches[1];$label='OpenSSH';$title=$null;break}
        '^cdn-(.+)$' {$kind='ws-cdn';$name=$Matches[1];$cdn=$Transport.cdn|Where-Object {$_.name -eq $name}|Select-Object -First 1;$via=$cdn.entry;$title='VLESS-WS через домен '+$cdn.domain;break}
        '^(hy2obfs|hy2|tuic|trojan|reality|shadowtls|ws-direct|ws-cdn)-(.+)$' {
            $kind=$Matches[1];$via=$Matches[2];$title=$null
            $labels=@{hy2='Hysteria2';hy2obfs='Hysteria2 + Salamander';tuic='TUIC';trojan='Trojan';reality='Reality';shadowtls='ShadowTLS';'ws-direct'='WebSocket';'ws-cdn'='VLESS-WS через домен'};$label=$labels[$kind];break
        }
    }
    if($via -eq 'wizard-server-route' -and $Transport.serverRoute.used -eq 'hop'){$via=[string]$Transport.serverRoute.hop.name;if(-not $via){$via=[string]$Transport.serverRoute.hop.ssh}}
    if(-not $title){$title=$label+' через '+$via}
    [pscustomobject]@{kind=$kind;via=$via;title=$title}
}
function Add-TransportDependency([string]$Tag,$Outbounds,[hashtable]$Needed) {
    if($Needed.ContainsKey($Tag)){return};$Needed[$Tag]=$true
    $out=$Outbounds|Where-Object {$_.tag -eq $Tag}|Select-Object -First 1
    if(-not $out){throw 'Не найдена зависимость пути'}
    if($out.detour){Add-TransportDependency $out.detour $Outbounds $Needed}
}
function Test-TransportInternetPath([string]$Tag,$Outbounds) {
    $seen=@{}
    while($Tag){
        if($seen.ContainsKey($Tag)){return $false};$seen[$Tag]=$true
        $out=$Outbounds|Where-Object {$_.tag -eq $Tag}|Select-Object -First 1
        # SSH заканчивается на SSH-forwarding и не даёт серверный произвольный TCP/UDP egress.
        if(-not $out -or $out.type -in @('ssh','socks')){return $false};$Tag=$out.detour
    }
    return $true
}
function Read-TransportPin([string]$Root) {
    $file=Join-Path $Root 'state/transport-pin.json'
    if(-not (Test-Path -LiteralPath $file)){return [pscustomobject]@{mode='auto';tag=$null}}
    $pin=Read-TransportJson $file
    if($pin.mode -notin @('auto','pinned')){throw 'Неверный mode pin'}
    if($pin.mode -eq 'pinned'){Assert-TransportTag $pin.tag}else{$pin|Add-Member -Force tag $null}
    return $pin
}
function Get-TransportSelection($Pin,$Rows,$Candidates,[string]$Current='') {
    if($Pin.mode -eq 'pinned'){return [string]$Pin.tag}
    $best=Get-TransportBest $Rows -Remembered;if($best){return [string]$best.tag}
    if($Current -in @($Candidates|ForEach-Object {$_.tag})){return $Current}
    if(@($Candidates).Count){return [string]$Candidates[0].tag};return 'unavailable'
}
function Get-TransportRevision([string]$Root) {
    # Содержимое, а не mtime: Syncthing/атомарная замена и одинаковая длина не скрывают изменение.
    $config=Read-TransportJson (Join-Path $Root 'config.json');$files=@()
    foreach($field in @('profilePath','channelPath')){if($config.transport.$field){$files+=[string]$config.transport.$field}}
    $files=@($files|Select-Object -Unique)
    $cache=Join-Path (Get-TransportValue $config.transport 'cacheRoot' $Root) 'secrets/entries';if(Test-Path -LiteralPath $cache){$files+=@(Get-ChildItem -LiteralPath $cache -Filter '*.json'|Sort-Object Name|ForEach-Object {$_.FullName})}
    $route=$config.transport.serverRoute;if(-not $route){$route=$config.wizard.serverRoute}
    if($route.used -eq 'hop' -and $config.transport.profilePath){$p=Read-TransportJson $config.transport.profilePath;$kh=Join-Path (Split-Path $p.knownHostsPath -Parent) 'known_hosts-hop';if(Test-Path $kh){$files+=$kh}}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$text=(ConvertTo-Json -InputObject $route -Depth 20 -Compress)+(ConvertTo-Json -InputObject $config.transport -Depth 40 -Compress)+"`n"+((@($files|ForEach-Object {$_+"`n"+(Convert-TransportLF ([IO.File]::ReadAllText($_)))})) -join "`n");[Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))}finally{$sha.Dispose()}
}
function Test-TransportConfigFile([string]$Exe,[string]$File) {
    $check=Start-TransportProcess $Exe @('check','-c',$File)
    try{
        $done=$check.Process.WaitForExit(15000)
        if(-not $done -or $check.Process.ExitCode -ne 0){
            $reason='config-rejected';if(-not $done){$reason='timeout'}
            $ex=New-Object Exception('sing-box отклонил конфигурацию');$ex.Data['transportDiagnostic']=New-TransportDiagnostic $check 'sing-box-check' $reason;throw $ex
        }
    }finally{Stop-TransportProcess $check}
}

function Get-VpnOptions($Settings) {
    $v=Get-TransportValue $Settings 'Vpn' $null
    $defaults=@{enabled=$false;excludeCidrs=@();interfaceName='RemoteAgents-TUN';address=@('172.31.255.1/30','fdfe:7261::1/126');probeAddress='198.18.0.1';checkUrl='https://example.com/';dnsServer='1.1.1.1'}
    $result=@{};foreach($key in $defaults.Keys){$result[$key]=Get-TransportValue $v $key $defaults[$key]}
    if($result.enabled -isnot [bool]){throw 'vpn.enabled должен быть boolean'}
    if($result.interfaceName -notmatch '^RemoteAgents-[a-zA-Z0-9_-]{1,32}$'){throw 'Неверное имя нашего TUN'}
    $uri=$null;if(-not [Uri]::TryCreate($result.checkUrl,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https'){throw 'vpn.checkUrl должен быть HTTPS'}
    foreach($cidr in @($result.address)+@($result.excludeCidrs)){Assert-VpnCidr $cidr}
    $ip=$null;if(-not [Net.IPAddress]::TryParse($result.dnsServer,[ref]$ip)){throw 'vpn.dnsServer должен быть IP'}
    $ip=$null;if(-not [Net.IPAddress]::TryParse($result.probeAddress,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'vpn.probeAddress должен быть IPv4'}
    return $result
}
function Get-VpnSnapshot {
    # Ошибка инвентаризации не означает отсутствие конфликтов: вызывающий запрещает включение.
    [pscustomobject]@{Processes=@(Get-CimInstance Win32_Process -ErrorAction Stop);Adapters=@(Get-NetAdapter -IncludeHidden -ErrorAction Stop);Routes=@(Get-NetRoute -ErrorAction Stop)}
}
function Get-VpnOwnedProcessIds([string]$Root,$Snapshot) {
    # Нельзя доверять одному PID из state: он мог быть повторно использован чужим процессом.
    foreach($component in @('transport','vpn')){
        $file=Join-Path $Root ('state/'+$component+'-owner.json');if(-not (Test-Path -LiteralPath $file)){continue}
        try{$owner=Read-TransportJson $file;foreach($proc in @($Snapshot.Processes)){
            if([int]$proc.ProcessId -eq [int]$owner.pid -and $proc.ExecutablePath -and [IO.Path]::GetFullPath($proc.ExecutablePath) -eq [IO.Path]::GetFullPath($owner.exe) -and
               $proc.CommandLine -and ($proc.CommandLine -match ('(?:^|\s)"?'+[regex]::Escape([string]$owner.config)+'"?(?=\s|$)')) -and $proc.CreationDate -and [Math]::Abs((([DateTime]$proc.CreationDate).ToUniversalTime()-(Convert-TransportUtc $owner.startedAt)).TotalSeconds) -lt 1){[int]$proc.ProcessId}
        }}catch{}
    }
}
function Find-VpnConflicts($Snapshot,[int[]]$OwnProcessIds=@(),[string]$OwnInterface='') {
    $items=New-Object Collections.ArrayList
    $hints=@($Snapshot.Processes|Where-Object {([string]$_.Name) -match '^(?i:Happ|v2ray|xray|sing-box|clash|nekoray|hiddify|wireguard|amnezia)' -and [int]$_.ProcessId -notin $OwnProcessIds}|ForEach-Object {[string]$_.Name}) -join ', '
    foreach($adapter in @($Snapshot.Adapters)){
        $text=$adapter.Name+' '+$adapter.InterfaceDescription
        if($adapter.Status -eq 'Up' -and $adapter.Name -ne $OwnInterface -and $text -match '(?i)TUN|Wintun|WireGuard|TAP' -and $text -notmatch '(?i)OpenVPN|Tailscale'){
            [void]$items.Add([pscustomobject]@{kind='adapter';name=$adapter.Name;path='';detail=$adapter.InterfaceDescription})
        }
    }
    foreach($route in @($Snapshot.Routes)){
        if($route.DestinationPrefix -notin @('0.0.0.0/1','128.0.0.0/1','0.0.0.0/0','::/0')){continue}
        $adapter=$Snapshot.Adapters|Where-Object {$_.ifIndex -eq $route.InterfaceIndex}|Select-Object -First 1
        if($adapter -and ($adapter.Name -eq $OwnInterface -or ($adapter.Name+' '+$adapter.InterfaceDescription) -match '(?i)OpenVPN|Tailscale')){continue}
        if($route.DestinationPrefix -in @('0.0.0.0/0','::/0')){
            if(-not $adapter -or $adapter.Status -ne 'Up'){continue}
            $text=$adapter.Name+' '+$adapter.InterfaceDescription
            $virtual=($adapter.HardwareInterface -eq $false -or $adapter.Virtual -eq $true -or $text -match '(?i)TUN|Wintun|WireGuard|TAP|Happ|xray|VPN|virtual')
            if(-not $virtual){continue}
        }
        $name=[string]$route.InterfaceAlias;if($adapter){$name=$adapter.Name}
        [void]$items.Add([pscustomobject]@{kind='route';name=$name;path='';detail=($route.DestinationPrefix+' via '+$route.NextHop+' (ifIndex '+$route.InterfaceIndex+')')})
    }
    [pscustomobject]@{conflict=($items.Count -gt 0);items=@($items.ToArray());processHints=$hints}
}
function ConvertTo-VpnHostCidr([string]$Address) {
    $ip=$null;if(-not [Net.IPAddress]::TryParse($Address,[ref]$ip)){throw 'Адрес узла не является IP'}
    if($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork){return $ip.ToString()+'/32'};return $ip.ToString()+'/128'
}
function Assert-VpnCidr([string]$Cidr) {
    $parts=$Cidr.Split('/');$ip=$null;$bits=0
    if($parts.Count -ne 2 -or -not [Net.IPAddress]::TryParse($parts[0],[ref]$ip) -or -not [int]::TryParse($parts[1],[ref]$bits)){throw 'Неверный CIDR VPN'}
    $max=128;if($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork){$max=32}
    if($bits -lt 0 -or $bits -gt $max){throw 'Неверная маска VPN'}
}
function Get-VpnExclusions($Settings,$Paths,$Snapshot,[hashtable]$Resolved=@{},[string]$Root='') {
    $v=Get-VpnOptions $Settings
    $cidrs=@('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16','100.64.0.0/10','169.254.0.0/16','224.0.0.0/4','127.0.0.0/8','::1/128','fc00::/7','fe80::/10','ff00::/8')+@($v.excludeCidrs)
    # Все транспортные endpoints, включая detour и выключенные узлы с имеющимся кэшем.
    $hosts=@($Settings.Profile.serverAddress)+@($Paths.Outbounds|Where-Object {$_.server -and $_.server -notin @('127.0.0.1','::1')}|ForEach-Object {$_.server})
    foreach($relay in @($Settings.Transport.relays)){if($relay){$hosts+=Get-TransportValue $relay 'host' $relay.server}}
    foreach($cdn in @($Settings.Transport.cdn)){if($cdn){$hosts+=$cdn.domain}}
    foreach($entry in @($Settings.Transport.entries)){
        if(-not $entry -or -not $Root){continue};$cache=Join-Path (Get-TransportCacheRoot $Settings $Root) ('secrets/entries/'+$entry.name+'.json')
        # Root задаётся параметром ниже: отключённый узел также исключается из TUN.
        if($Root -and (Test-Path -LiteralPath $cache)){$hosts+=(Read-TransportJson $cache).server}
    }
    foreach($hop in @($Settings.Transport.hops)){
        if(-not $hop){continue};$h=Get-TransportHopArguments $hop ([string]$hop.knownHostsPath);$args=@('-n','-G')+@($h.options)+@($h.target)
        $text=Invoke-TransportText $Settings.Profile.sshExecutable $args
        foreach($line in $text -split "`n"){if($line -match '^hostname (.+)$'){$hosts+=$Matches[1].Trim();break}}
    }
    foreach($hostName in @($hosts|Where-Object {$_}|Select-Object -Unique)){
        $ip=$null;$addresses=@()
        if([Net.IPAddress]::TryParse([string]$hostName,[ref]$ip)){$addresses=@($ip.ToString())}
        elseif($Resolved.ContainsKey([string]$hostName)){$addresses=@($Resolved[[string]$hostName])}
        else{$addresses=@([Net.Dns]::GetHostAddresses([string]$hostName)|ForEach-Object {$_.ToString()})}
        if(-not $addresses.Count){throw 'Не удалось исключить внешний узел VPN'}
        foreach($address in $addresses){$cidrs+=ConvertTo-VpnHostCidr $address}
    }
    $openVpn=@($Snapshot.Adapters|Where-Object {($_.Name+' '+$_.InterfaceDescription) -match '(?i)OpenVPN'})
    foreach($route in @($Snapshot.Routes|Where-Object {$_.InterfaceIndex -in @($openVpn|ForEach-Object {$_.ifIndex})})){
        # Default/split-default нельзя исключать целиком: это отключило бы наш VPN.
        if($route.DestinationPrefix -notin @('0.0.0.0/0','0.0.0.0/1','128.0.0.0/1','::/0','::/1','8000::/1')){$cidrs+=$route.DestinationPrefix}
        if($route.NextHop -and $route.NextHop -notin @('0.0.0.0','::')){$cidrs+=ConvertTo-VpnHostCidr $route.NextHop}
    }
    foreach($cidr in $cidrs){Assert-VpnCidr $cidr}
    @($cidrs|Sort-Object -Unique)
}
function New-VpnTunConfig($Settings,$Paths,[string]$SelectedTag,[string[]]$ExcludeCidrs,[string]$Interface) {
    $v=Get-VpnOptions $Settings
    if(-not $Interface){throw 'Для TUN нужен физический интерфейс'}
    $candidate=$Paths.Candidates|Where-Object {$_.tag -eq $SelectedTag -and $_.enabled -ne $false}|Select-Object -First 1
    if(-not $candidate -or -not (Test-TransportInternetPath $SelectedTag $Paths.Outbounds)){throw 'Выбранный путь не поддерживает интернет TCP/UDP; TUN выключен'}
    $needed=@{};Add-TransportDependency $SelectedTag $Paths.Outbounds $needed;$outs=@()
    foreach($out in @($Paths.Outbounds|Where-Object {$needed.ContainsKey($_.tag)})){
        $copy=Copy-TransportObject $out
        if(-not $copy.detour){$copy|Add-Member -Force bind_interface $Interface;$copy|Add-Member -Force domain_resolver 'bootstrap'}
        $outs+=$copy
    }
    $outs+=@{type='selector';tag='vpn-active';outbounds=@($SelectedTag);default=$SelectedTag;interrupt_exist_connections=$false}
    # system использует TCP/IP Windows без дополнительного userspace TCP gVisor.
    # Выбор уменьшает число реализаций стека; превосходство на реальной сети ещё не проверено.
    @{log=@{disabled=$true};inbounds=@(@{type='tun';tag='vpn-tun';interface_name=$v.interfaceName;address=@($v.address);stack='system';auto_route=$true;strict_route=$false;route_exclude_address=@($ExcludeCidrs)});
      outbounds=$outs;route=@{auto_detect_interface=$true;default_interface=$Interface;default_domain_resolver='bootstrap';final='vpn-active';rules=@(
        @{inbound=@('vpn-tun');network='tcp';port=@(22,(Get-TransportServerPort $Settings.Profile))|Select-Object -Unique;ip_cidr=@($v.probeAddress+'/32');action='route';outbound='vpn-active';override_address=$Settings.Profile.serverAddress;override_port=(Get-TransportServerPort $Settings.Profile)},
        @{protocol='dns';action='hijack-dns'})};
      dns=@{servers=@(@{type='udp';tag='bootstrap';server=$v.dnsServer;bind_interface=$Interface},@{type='https';tag='vpn-dns';server=$v.dnsServer;detour='vpn-active'});final='vpn-dns'}}
}
function Write-VpnStatus([string]$Root,[bool]$Ok,[bool]$Enabled,[string]$State,$Conflict,[string]$Summary) {
    Write-TransportJson (Join-Path $Root 'status/vpn.json') @{ok=$Ok;enabled=$Enabled;state=$State;conflict=$Conflict;summary=$Summary;updatedAt=[DateTime]::UtcNow.ToString('o')}
    # Журнал всегда локальный; только категория, без текста исключений и параметров процессов.
    $dir=Join-Path $Root 'logs';[void][IO.Directory]::CreateDirectory($dir);$file=Join-Path $dir 'vpn.log'
    if((Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).Length -ge 1MB){Move-Item -LiteralPath $file -Destination ($file+'.1') -Force}
    [IO.File]::AppendAllText($file,([DateTime]::UtcNow.ToString('o')+' '+$State+"`n"),(New-Object Text.UTF8Encoding($false)))
}
function Set-VpnEnabled([string]$Root,[bool]$Enabled) {
    $mutex=New-Object Threading.Mutex($false,('Global\RemoteAgentsConfig-'+(Get-TransportFingerprint 'config' (Get-TransportHome $Root).ToLowerInvariant())));$locked=$false
    try{
        try{$locked=$mutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$locked=$true};if(-not $locked){throw 'Конфиг занят'}
        $file=Join-Path $Root 'config.json';$config=Read-TransportJson $file
        if(-not $config.vpn){$config|Add-Member -Force vpn ([pscustomobject]@{})};$config.vpn|Add-Member -Force enabled $Enabled
        if(-not $config.components){$config|Add-Member -Force components ([pscustomobject]@{})}
        if(-not $config.components.vpn){$config.components|Add-Member -Force vpn ([pscustomobject]@{})}
        $config.components.vpn|Add-Member -Force enabled $Enabled
        Write-TransportJson $file $config
    }finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Test-VpnAdministrator {
    if($env:OS -ne 'Windows_NT'){return $false}
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$principal=New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Save-TransportOwner([string]$Root,[string]$Component,$Child,[string]$Exe,[string]$Config) {
    Write-TransportJson (Join-Path $Root ('state/'+$Component+'-owner.json')) @{pid=$Child.Process.Id;exe=[IO.Path]::GetFullPath($Exe);config=[IO.Path]::GetFullPath($Config);startedAt=$Child.Process.StartTime.ToUniversalTime().ToString('o')} -Private
}
function Get-VpnTaskNames([string]$Root) {
    $id=(Get-TransportFingerprint 'vpn' (Get-TransportHome $Root).ToLowerInvariant()).Substring(0,16)
    @{Worker=('RemoteAgents-TUN-'+$id);Rollback=('RemoteAgents-TUN-Rollback-'+$id)}
}
function Assert-VpnTunRoute([string]$Address,[int]$InterfaceIndex) {
    $routes=@(Find-NetRoute -RemoteIPAddress $Address -ErrorAction Stop|Where-Object {$_.DestinationPrefix})
    if(-not $routes.Count -or @($routes|Where-Object {$_.InterfaceIndex -ne $InterfaceIndex}).Count){throw 'Пробный запрос обходит TUN'}
}
function Test-VpnThroughTun($Settings,$Adapter) {
    $v=Get-VpnOptions $Settings
    if(-not $Settings.Transport.bootstrap){
    Assert-VpnTunRoute $v.probeAddress $Adapter.ifIndex
    # SSH с закреплённым host key проверяет сервер через TUN (synthetic IP -> server loopback),
    # 64 КиБ дополнительно обнаруживают зависание после первых пакетов.
    $candidate=[pscustomobject]@{tag='tun-check';port=22}
    $a=@(Get-TransportSshArguments $Settings.Profile 22)+@($v.probeAddress,'head -c 65536 /dev/urandom')
    $child=Start-TransportProcess $Settings.Profile.sshExecutable $a -Probe
    Initialize-TransportCounter;$sink=New-Object RemoteAgents.TransportCounter
    try{
        $copy=$child.Process.StandardOutput.BaseStream.CopyToAsync($sink)
        $probe=[pscustomobject]@{child=$child;sink=$sink;copy=$copy;state=(New-TransportProbeState 65536 5 40)}
        while(-not (Receive-TransportProbe $probe)){Start-Sleep -Milliseconds 100}
        if($probe.state.state -ne 'ok'){throw 'Сервер через TUN не прошёл проверку'}
    }finally{Stop-TransportProcess $child;try{if($copy){[void]$copy.Wait(1000)}}catch{};$sink.Dispose()}
    }
    $uri=[Uri]$v.checkUrl
    $addresses=@([Net.Dns]::GetHostAddresses($uri.DnsSafeHost));if(-not $addresses.Count){throw 'DNS через VPN не отвечает'}
    # WebRequest может выбрать любой из A/AAAA: все результаты должны маршрутизироваться через наш TUN.
    foreach($ip in $addresses){Assert-VpnTunRoute $ip.ToString() $Adapter.ifIndex}
    $req=[Net.HttpWebRequest]::Create($uri);$req.Proxy=$null;$req.Timeout=20000;$req.ReadWriteTimeout=20000;$req.AllowAutoRedirect=$false;$req.KeepAlive=$false
    $response=$req.GetResponse()
    try{if([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300){throw 'Внешний HTTPS не прошёл проверку'}}finally{$response.Dispose()}
}
function Clear-VpnRoutes([string]$Root,[string]$Session) {
    $file=Join-Path $Root 'state/vpn-interface.json';if(-not (Test-Path -LiteralPath $file)){return}
    $owned=Read-TransportJson $file;if($owned.session -ne $Session){return}
    $adapter=Get-NetAdapter -IncludeHidden -ErrorAction Stop|Where-Object {[string]$_.InterfaceGuid -eq [string]$owned.guid -and $_.Name -eq $owned.name}|Select-Object -First 1
    if($adapter){
        Get-NetRoute -InterfaceIndex $adapter.ifIndex -ErrorAction Stop|Remove-NetRoute -Confirm:$false -ErrorAction Stop
        if(@(Get-NetRoute -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue).Count){throw 'Маршруты TUN остались после остановки'}
    }
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
}

function Register-VpnRollbackTask([string]$Root,[string]$Session,[string]$ScriptPath,[string]$UserId='') {
    if(-not $UserId){$UserId=[Security.Principal.WindowsIdentity]::GetCurrent().Name}
    $tasks=Get-VpnTaskNames $Root;$exe=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$ScriptPath,'-Home',$Root,'-Session',$Session,'-Rollback')
    $action=New-ScheduledTaskAction -Execute $exe -Argument (($args|ForEach-Object {Quote-Transport $_}) -join ' ')
    $principal=New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $tasks.Rollback -Action $action -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)) -Principal $principal -Settings $settings -Force|Out-Null
}

function Sync-TransportEntryCache($Settings,[string]$Root) {
    # Новые entries загружаются в background reload, не блокируя pin/API.
    # Старый кэш обновляет только явная Update-Entries.ps1; host keys не принимаются автоматически.
    foreach($entry in @($Settings.Transport.entries)){
        if(-not $entry -or -not (Test-TransportEnabled $entry)){continue}
        $file=Join-Path (Get-TransportCacheRoot $Settings $Root) ('secrets/entries/'+$entry.name+'.json');if(Test-Path -LiteralPath $file){continue}
        $args=@('-n','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','-o','StrictHostKeyChecking=yes')
        if($entry.configPath){$args+=@('-F',[string]$entry.configPath)}
        $alias=Get-TransportValue $entry 'ssh' $entry.alias
        $text=Invoke-TransportText $Settings.Profile.sshExecutable ($args+@([string]$alias,'cat /opt/rd-entry/client.json'))
        $data=ConvertFrom-Json (Convert-TransportLF $text)
        foreach($field in @('server','sni','cover','ports','secrets')){if(-not $data.$field){throw 'Неполный client.json'}}
        Write-TransportJson $file $data -Private
    }
}

function Initialize-TransportDiagnostics {
    if('RemoteAgents.TransportErrorBuffer' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
namespace RemoteAgents {
 public sealed class TransportErrorBuffer : Stream {
  readonly object gate = new object();
  readonly byte[] first = new byte[2048], recent = new byte[8192];
  int firstCount, recentCount; bool firstDone;
  public override void Write(byte[] b, int o, int n) {
   lock(gate) {
    for(int i=o;i<o+n;i++) {
     if(!firstDone) { if(firstCount<first.Length) first[firstCount++]=b[i]; if(b[i]==10 || firstCount==first.Length) firstDone=true; }
     if(recentCount==recent.Length) {Buffer.BlockCopy(recent,4096,recent,0,4096);recentCount=4096;}
     recent[recentCount++]=b[i];
    }
   }
  }
  public string Snapshot() {lock(gate) return Encoding.UTF8.GetString(first,0,firstCount)+"\n"+Encoding.UTF8.GetString(recent,0,recentCount);}
  public override bool CanRead {get{return false;}} public override bool CanSeek {get{return false;}} public override bool CanWrite {get{return true;}}
  public override long Length {get{return 0;}} public override long Position {get{return 0;}set{throw new NotSupportedException();}}
  public override void Flush() {} public override int Read(byte[] b,int o,int n){throw new NotSupportedException();}
  public override long Seek(long o,SeekOrigin s){throw new NotSupportedException();} public override void SetLength(long v){throw new NotSupportedException();}
 }
}
'@
}
function Get-TransportSecretValues($Value,[string]$Name='',[bool]$Sensitive=$false) {
    if($null -eq $Value){return}
    $sensitiveValue=$Sensitive -or $Name -match '(?i)password|secret|token|uuid|private_key|passphrase|short_id'
    if($Value -is [string]){if($sensitiveValue -and $Value){$Value};return}
    if($Value -is [Collections.IDictionary]){foreach($k in $Value.Keys){Get-TransportSecretValues $Value[$k] ([string]$k) $sensitiveValue}}
    elseif($Value -is [array]){foreach($v in $Value){Get-TransportSecretValues $v $Name $sensitiveValue}}
    elseif($Value -is [pscustomobject]){foreach($p in $Value.PSObject.Properties){Get-TransportSecretValues $p.Value $p.Name $sensitiveValue}}
}
function Protect-TransportDiagnostic([string]$Text,$Settings) {
    # Redact known values BEFORE generic patterns, including short passwords.
    foreach($value in @(Get-TransportSecretValues $Settings|Sort-Object Length -Descending)){
        if($value){$Text=$Text.Replace([string]$value,'<redacted>')}
    }
    $Text=$Text -replace '\x1b\[[0-9;]*m',''
    $Text=$Text -replace '(?i)((?:password|token|secret|passphrase|private_key|uuid)\s*[=:]\s*)[^\s,;]+','$1<redacted>'
    Protect-TransportText $Text
}
function New-TransportDiagnostic($Child,[string]$Candidate,[string]$Reason,$Settings=$null) {
    $code=$null;$line=''
    if($Child){
        try{if($Child.Process.HasExited){$code=$Child.Process.ExitCode;[void]$Child.ErrorDrain.Wait(500)}}catch{}
        if($Child.PSObject.Properties['ErrorBuffer']){
            $lines=@((Convert-TransportLF $Child.ErrorBuffer.Snapshot()) -split "`n"|Where-Object {$_.Trim()})
            if($lines.Count){$line=$lines[0]}
        }
    }
    # Error kind remains explicit even when stderr is empty or has been redacted.
    if($line -match '(?i)timed? out|timeout|deadline'){$Reason='timeout'}
    elseif($line -match '(?i)refused'){$Reason='connection-refused'}
    elseif($line -match '(?i)unreachable|no route'){$Reason='network-unreachable'}
    elseif($line -match '(?i)permission denied|authentication failed'){$Reason='authentication-failed'}
    [pscustomobject]@{candidate=$(if($Candidate -match '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,95}$'){$Candidate}else{'invalid-tag'});reason=$Reason;exitCode=$code;stderr=(Protect-TransportDiagnostic $line $Settings)}
}
function Format-TransportDiagnostic($Detail) {
    'candidate='+$Detail.candidate+' reason='+$Detail.reason+' exit='+$(if($null -eq $Detail.exitCode){'running/unknown'}else{[string]$Detail.exitCode})+' stderr='+$Detail.stderr+$(if($Detail.engineStderr){' sing-box='+$Detail.engineStderr}else{''})
}

function Get-TransportDiagnosticContext($Settings,[string]$Root) {
    $values=@($Settings)
    $apiSecret=Join-Path $Root 'state/transport-secret.json';if(Test-Path $apiSecret){$values+=,(Read-TransportJson $apiSecret)}
    $dir=Join-Path (Get-TransportCacheRoot $Settings $Root) 'secrets/entries'
    if(Test-Path $dir){foreach($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.json')){$values+=,(Read-TransportJson $file.FullName)}}
    $values
}
function Get-TransportEngineDiagnostic($Engine,[string]$Candidate,$Context) {
    if(-not $Engine -or -not $Engine.ErrorBuffer){return $null}
    $lines=@((Convert-TransportLF $Engine.ErrorBuffer.Snapshot()) -split "`n"|Where-Object {($_.Contains('['+$Candidate+']') -or $_.Contains('[probe-'+$Candidate+']'))})
    if(-not $lines.Count){return $null}
    $detail=New-TransportDiagnostic $null $Candidate 'transport-error'
    $detail.stderr=Protect-TransportDiagnostic $lines[0] $Context
    if($detail.stderr -match '(?i)timed? out|timeout|deadline'){$detail.reason='timeout'}
    elseif($detail.stderr -match '(?i)refused'){$detail.reason='connection-refused'}
    elseif($detail.stderr -match '(?i)unreachable|no route'){$detail.reason='network-unreachable'}
    $detail
}

# Bootstrap has no registered SSH key yet. Its tag was checked by HTTPS through
# a temporary local proxy; Worker still verifies DNS/HTTPS and routes through TUN.
function Get-VpnTransportState([string]$Root,$Settings) {
    if($Settings.Transport.bootstrap -and $Settings.Vpn.bootstrapTag){return [pscustomobject]@{active=[string]$Settings.Vpn.bootstrapTag;bootstrap=$true}}
    $status=Read-TransportJson (Join-Path $Root 'status/transport.json')
    if(-not $status.ok -or ([DateTime]::UtcNow-(Convert-TransportUtc $status.updatedAt)).TotalSeconds -gt 15){throw 'Транспорт ещё не проверен'}
    return $status
}

function Get-TransportCacheRoot($Settings,[string]$Root) {
    Get-TransportValue $Settings.Transport 'cacheRoot' $Root
}
