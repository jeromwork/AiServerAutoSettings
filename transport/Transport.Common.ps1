#requires -Version 5.1
$ErrorActionPreference='Stop'
function Test-ProductVpnEnabled {
    [bool](Read-TransportJson (Join-Path $PSScriptRoot 'product-features.json')).vpnEnabled
}
# Построение цепочек взято из Test-Transports.ps1; разбор профиля/ssh -G — из Disk.Common.ps1.
function Get-TransportHome([string]$Path){
    $full=[IO.Path]::GetFullPath($Path);$base=[IO.Path]::GetPathRoot($full)
    if($full.Length -gt $base.Length){return $full.TrimEnd('\','/')}
    $full
}
function Convert-TransportLF([string]$Text) {$Text.Replace("`r",'').TrimStart([char]0xFEFF)}
# stdin of child processes uses the OEM code page (cp866 on Russian Windows), servers read UTF-8:
# send JSON with every non-ASCII character as \uXXXX so names like a Cyrillic user name survive (16.11.2026).
function ConvertTo-AsciiJson([string]$Json) {$b=New-Object Text.StringBuilder;foreach($c in $Json.ToCharArray()){if([int]$c -gt 126){[void]$b.Append('\u').Append(([int]$c).ToString('x4'))}else{[void]$b.Append($c)}};$b.ToString()}
function Read-TransportJson([string]$Path) {
    # Держим открытый снимок до конца чтения: атомарная замена оставляет его целым.
    for($attempt=0;;$attempt++){
        $stream=$null;$reader=$null
        try{
            $stream=New-Object IO.FileStream($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
            $text=Convert-TransportLF $reader.ReadToEnd()
            if(-not [string]::IsNullOrWhiteSpace($text)){return (ConvertFrom-Json $text)}
            if($attempt -ge 20){throw (New-Object IO.InvalidDataException('Пустой JSON после повторного чтения'))}
        }catch [IO.IOException]{
            # ERROR_SHARING_VIOLATION / ERROR_LOCK_VIOLATION; пустой снимок повторяем в том же лимите.
            if(($_.Exception.GetBaseException().HResult -band 0xffff) -notin @(32,33) -or $attempt -ge 20){throw}
        }finally{if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
        Start-Sleep -Milliseconds 50
    }
}
function Convert-TransportUtc($Value) {
    if($Value -is [DateTimeOffset]){return $Value.UtcDateTime}
    if($Value -is [DateTime]){return $Value.ToUniversalTime()}
    [DateTime]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}
function Copy-TransportObject($Value) {ConvertFrom-Json (ConvertTo-Json -InputObject $Value -Depth 40 -Compress)}
function Get-TransportValue($Object,[string]$Name,$Default) {
    if($null -ne $Object -and $null -ne $Object.$Name){return $Object.$Name};return $Default
}
function Protect-TransportPath([string]$Path,[switch]$System) {
    if($env:OS -eq 'Windows_NT'){
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
        if([IO.Directory]::Exists($Path)){$acl=New-Object Security.AccessControl.DirectorySecurity;$inherit=[Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'}else{$acl=New-Object Security.AccessControl.FileSecurity;$inherit=[Security.AccessControl.InheritanceFlags]::None}
        $acl.SetAccessRuleProtection($true,$false)
        $rule=New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl',$inherit,[Security.AccessControl.PropagationFlags]::None,'Allow')
        $acl.AddAccessRule($rule)
        if($System){$systemSid=New-Object Security.Principal.SecurityIdentifier('S-1-5-18');$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($systemSid,'FullControl',$inherit,[Security.AccessControl.PropagationFlags]::None,'Allow')))}
        # Только DACL: Set-Acl пишет и SACL и без SeSecurityPrivilege (не админ) падает на PS 5.1.
        if([IO.Directory]::Exists($Path)){[IO.Directory]::SetAccessControl($Path,$acl)}else{[IO.File]::SetAccessControl($Path,$acl)}
    }else{if([IO.Directory]::Exists($Path)){& chmod 700 -- $Path}else{& chmod 600 -- $Path};if($LASTEXITCODE -ne 0){throw 'Не удалось ограничить права'}}
}
function Write-TransportJson([string]$Path,$Value,[switch]$Private,[switch]$Durable,[switch]$System) {
    $dir=[IO.Path]::GetDirectoryName($Path);[void][IO.Directory]::CreateDirectory($dir)
    $tmp=Join-Path $dir ([IO.Path]::GetRandomFileName());$backup=$tmp+'.old'
    try{
        # Файл создаётся внутри закрытого каталога, ACL задаётся до записи секрета.
        if($Private){Protect-TransportPath $dir;if([IO.File]::Exists($Path)){Protect-TransportPath $Path -System:$System};[IO.File]::WriteAllText($tmp,'');Protect-TransportPath $tmp -System:$System}
        $json=ConvertTo-Json -InputObject $Value -Depth 40
        if($Durable){
            $stream=New-Object IO.FileStream($tmp,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{$bytes=[Text.Encoding]::UTF8.GetBytes($json);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        }else{[IO.File]::WriteAllText($tmp,$json,(New-Object Text.UTF8Encoding($false)))}
        for($attempt=0;$attempt -lt 5;$attempt++){
            try{if([IO.File]::Exists($Path)){[IO.File]::Replace($tmp,$Path,$backup)}else{[IO.File]::Move($tmp,$Path)};break}
            catch [IO.IOException]{if($attempt -eq 4){throw};Start-Sleep -Milliseconds 20}
        }
        if($Private){Protect-TransportPath $Path -System:$System}
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
    $allowed=@('start','ready','switch','probe-ok','probe-failed','network-change','restart','api-failed','process-failed','memory-invalid','network-unavailable','stop','fatal','port-moved','channel-address-moved','happier-port-conflict')
    if($Event -notin $allowed){$Event='process-failed'}
    $dir=Join-Path $Root 'logs';[void][IO.Directory]::CreateDirectory($dir);$path=Join-Path $dir 'transport.log'
    if([IO.File]::Exists($path) -and (Get-Item -LiteralPath $path).Length -ge 1MB){Move-Item -LiteralPath $path -Destination ($path+'.1') -Force}
    $line=[DateTime]::UtcNow.ToString('o')+' '+$Event
    # Plain exception text is rejected; callers supply a sanitized diagnostic or safe script location.
    if($Event -in @('port-moved','channel-address-moved','happier-port-conflict') -and $Detail -is [pscustomobject] -and $Detail.PSObject.Properties['message']){$line+=' '+([string]$Detail.message -replace '[\r\n]',' ')}
    elseif($Detail -is [pscustomobject] -and $Detail.PSObject.Properties['reason']){$line+=' '+(Format-TransportDiagnostic $Detail)}
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
    }catch{try{if(-not $p.HasExited){$p.Kill();[void]$p.WaitForExit(2000)}}catch{};$p.Dispose();$ex=New-Object Exception('Не удалось запустить дочерний процесс');$reason='start-failed';$inner=$_.Exception
        while($inner){if($inner -is [ComponentModel.Win32Exception] -and $inner.NativeErrorCode -in @(2,3)){$reason='executable-not-found';break};$inner=$inner.InnerException}
        if($reason -eq 'executable-not-found'){$ex=New-Object Exception('Программа или файл запуска не найдены')}
        $ex.Data['transportDiagnostic']=New-TransportDiagnostic $null 'process' $reason;throw $ex}
}
function Stop-TransportProcess($Child) {
    if(-not $Child){return};$p=$Child.Process
    try{if(-not $p.HasExited){
        if($env:OS -eq 'Windows_NT'){& "$env:SystemRoot/System32/taskkill.exe" /PID $p.Id /T /F 2>$null | Out-Null}
        if(-not $p.HasExited){$p.Kill()};[void]$p.WaitForExit(2000)
    }}catch{}finally{$p.Dispose()}
}
function Invoke-TransportText([string]$Exe,[string[]]$Arguments,[int[]]$SuccessExitCodes=@(0)) {
    $c=Start-TransportProcess $Exe $Arguments -Probe
    try{
        $task=$c.Process.StandardOutput.ReadToEndAsync()
        $reason=$null;$message=''
        if(-not $c.Process.WaitForExit(15000)){$reason='timeout';$message='Таймаут внешней команды'}
        elseif($c.Process.ExitCode -notin $SuccessExitCodes){$reason='command-failed';$message='Внешняя команда не выполнена (код выхода '+$c.Process.ExitCode+')'}
        if($reason){$ex=New-Object Exception($message);$ex.Data['transportDiagnostic']=New-TransportDiagnostic $null 'process' $reason;$ex.Data['transportDiagnostic'].exitCode=$(if($c.Process.HasExited){$c.Process.ExitCode}else{$null});throw $ex}
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
    if(Test-Path -LiteralPath $file){
        $config=Read-TransportJson $file;$route=$config.wizard.serverRoute
        if($route -and $route.used -eq 'proxy' -and $route.proxy.host -in @('127.0.0.1','localhost')){
            $ports=Get-TransportEffectivePorts $Root;$configured=Get-TransportConfiguredPorts $config.transport $null
            if([int]$route.proxy.port -eq [int]$configured.channelSocksPort){$route.proxy.port=[int]$ports.channelSocksPort}
        }
        return $route
    }
}
function Get-TransportSavedRouteOptions([string]$Root,$Profile) {
    $route=Get-TransportSavedRoute $Root
    if($route -and $route.used -eq 'proxy' -and $route.proxy.host -in @('127.0.0.1','localhost') -and [int]$route.proxy.port -eq [int](Get-TransportEffectivePort $Root 'channelSocksPort')){
        # Старый ProxyCommand в профиле мог запомнить прежний порт нашего SOCKS.
        $Profile=Copy-TransportObject $Profile;$Profile.PSObject.Properties.Remove('routeProxyCommand')
    }
    New-TransportRouteOptions $route $Profile (Join-Path $Root 'RemoteAgents.exe')
}
function Get-TransportRouteOverlay($Route,[string]$Root) {
    if(-not $Route -or $Route.used -eq 'direct'){return $null}
    $copy=Copy-TransportObject $Route
    if($copy.used -eq 'proxy'){$copy|Add-Member -Force proxyExecutable (Join-Path $Root 'RemoteAgents.exe')}
    return $copy
}
# Настроенные значения отделены от состояния: выбор порта не меняет ревизию config.json.
function Get-TransportPortDefaults {
    @{sshPort=2222;channelSocksPort=2223;channelSshAddress='127.0.0.2';syncPort=22001;lanProxyPort=17880;vpnInPort=17881;probePortBase=26000;socksPortBase=28000;apiPort=29090}
}
function Get-TransportConfiguredPorts($Transport,$Profile) {
    $ports=[ordered]@{};$defaults=Get-TransportPortDefaults
    foreach($key in @('sshPort','channelSocksPort','syncPort','lanProxyPort','vpnInPort','apiPort','probePortBase','socksPortBase','channelSshAddress')){$ports[$key]=Get-TransportValue $Transport $key $defaults[$key]}
    $ports['serverPort']=Get-TransportServerPort $Profile
    [pscustomobject]$ports
}
function Test-TransportPortsEqual($Left,$Right) {
    if(-not $Left -or -not $Right){return $false}
    foreach($key in @('sshPort','channelSocksPort','syncPort','lanProxyPort','vpnInPort','apiPort','probePortBase','socksPortBase','channelSshAddress','serverPort')){
        if([string]$Left.$key -cne [string]$Right.$key){return $false}
    };return $true
}
function Get-TransportEffectivePorts([string]$Root) {
    $t=$null;$p=$null;$file=Join-Path $Root 'config.json'
    if(Test-Path -LiteralPath $file){$t=(Read-TransportJson $file).transport;if($t.profilePath -and (Test-Path -LiteralPath $t.profilePath)){$p=Read-TransportJson $t.profilePath}}
    $configured=Get-TransportConfiguredPorts $t $p
    try{
        $state=Read-TransportJson (Join-Path $Root 'state/transport-ports.json')
        if($state.schema -eq 1 -and (Test-TransportPortsEqual $configured $state.configured)){
            foreach($key in @('sshPort','channelSocksPort','syncPort','lanProxyPort','vpnInPort','apiPort','probePortBase','socksPortBase','serverPort')){
                if([int]$state.effective.$key -lt 1 -or [int]$state.effective.$key -gt 65535){return $configured}
            }
            $ip=$null
            if(-not [Net.IPAddress]::TryParse([string]$state.effective.channelSshAddress,[ref]$ip) -or $ip.ToString() -notmatch '^127\.' -or $ip.ToString() -eq '127.0.0.1' -or $state.effective.serverPort -ne $configured.serverPort){return $configured}
            return $state.effective
        }
    }catch{}
    return $configured
}
function Get-TransportEffectivePort([string]$Root,[string]$Key) {
    $ports=Get-TransportEffectivePorts $Root
    if(-not $ports.PSObject.Properties[$Key]){throw 'Неизвестный параметр порта транспорта'}
    $ports.$Key
}
function Test-TransportPortFree([string]$Address,[int]$Port,$Snapshot=$null) {
    if($Port -lt 1 -or $Port -gt 65535){return $false}
    if($null -eq $Snapshot){$Snapshot=Get-TransportPortSnapshot}
    if(@($Snapshot.listeners|Where-Object {[int]$_.port -eq $Port -and [string]$_.address -in @($Address,'0.0.0.0','::')}).Count){return $false}
    $listener=$null
    try{$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse($Address),$Port);$listener.ExclusiveAddressUse=$true;$listener.Start();return $true}catch{return $false}finally{if($listener){$listener.Stop()}}
}
function Find-TransportChannelAddress([int]$Port,[string]$Preferred,$Snapshot=$null) {
    if($null -eq $Snapshot){$Snapshot=Get-TransportPortSnapshot}
    # Wildcard занимает весь loopback: смена 127.x здесь не поможет.
    if(@($Snapshot.listeners|Where-Object {[int]$_.port -eq $Port -and $_.address -in @('0.0.0.0','::')}).Count){throw 'Нет свободного локального адреса для входа канала: порт занят на всех адресах'}
    foreach($address in @(@($Preferred)+@(2..254|ForEach-Object {'127.0.0.'+$_})|Select-Object -Unique)){
        $ip=$null
        if([Net.IPAddress]::TryParse($address,[ref]$ip) -and $ip.ToString() -match '^127\.' -and $ip.ToString() -ne '127.0.0.1' -and (Test-TransportPortFree $address $Port $Snapshot)){return $address}
    }
    throw 'Нет свободного локального адреса для входа канала'
}
function Select-TransportPortBlock([int]$Preferred,[int]$Count,[int]$Step,$Snapshot,$Selected) {
    if($Count -le 0){return $Preferred}
    for($attempt=0;$attempt -lt 200;$attempt++){
        $port=$Preferred+$attempt*$Step;if($port+$Count-1 -gt 65535){break}
        $free=$true
        for($i=0;$i -lt $Count;$i++){if($Selected.ContainsKey($port+$i) -or -not (Test-TransportPortFree '127.0.0.1' ($port+$i) $Snapshot)){$free=$false;break}}
        if($free){for($i=0;$i -lt $Count;$i++){$Selected[$port+$i]=$true};return $port}
    }
    # ОС выбирает начало блока. Держим весь блок до конца проверки, затем освобождаем перед запуском.
    for($attempt=0;$attempt -lt 200;$attempt++){
        $held=New-Object Collections.ArrayList
        try{
            $first=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$first.ExclusiveAddressUse=$true;$first.Start();[void]$held.Add($first);$port=$first.LocalEndpoint.Port
            if($port+$Count-1 -gt 65535){continue}
            $free=$true
            for($i=0;$i -lt $Count;$i++){
                if($Selected.ContainsKey($port+$i) -or @($Snapshot.listeners|Where-Object {[int]$_.port -eq $port+$i -and $_.address -in @('127.0.0.1','0.0.0.0','::')}).Count){$free=$false;break}
                if($i -gt 0){$next=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,($port+$i));[void]$held.Add($next);$next.ExclusiveAddressUse=$true;$next.Start()}
            }
            if($free){for($i=0;$i -lt $Count;$i++){$Selected[$port+$i]=$true};return $port}
        }catch{}finally{foreach($listener in $held){$listener.Stop()}}
    }
    throw 'Не удалось выбрать свободные локальные порты транспорта'
}
function Update-TransportChannelRoute([string]$Root,$Settings,[string]$Old,[string]$New) {
    if(-not $Old -or $Old -ceq $New){return}
    $profile=$Settings.Profile;$file=[string]$profile.configPath;$changed=$false
    if($file -and [IO.File]::Exists($file)){
        $bytes=[IO.File]::ReadAllBytes($file);$bom=($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
        $text=[Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
        $pattern='(?im)^(\s*HostName[ \t]+)'+[regex]::Escape($Old)+'([ \t]*\r?$)'
        $next=[regex]::Replace($text,$pattern,('${1}'+$New+'${2}'))
        if($next -cne $text){
            $tmp=$file+'.'+[guid]::NewGuid().ToString('N')+'.tmp';$backup=$tmp+'.old'
            try{[IO.File]::WriteAllText($tmp,$next,(New-Object Text.UTF8Encoding($bom)));Protect-TransportPath $tmp;[IO.File]::Replace($tmp,$file,$backup);$changed=$true}
            finally{foreach($path in @($tmp,$backup)){if([IO.File]::Exists($path)){[IO.File]::Delete($path)}}}
        }
    }
    $args=@($profile.arguments|ForEach-Object {if([string]$_ -ceq ('HostName='+$Old)){'HostName='+$New}else{$_}})
    if(($args -join "`n") -cne (@($profile.arguments) -join "`n")){
        $profile|Add-Member -Force arguments $args
        if($Settings.Transport.profilePath){Write-TransportJson $Settings.Transport.profilePath $profile -Private};$changed=$true
    }
    if($changed){Write-TransportLog $Root 'channel-address-moved' ([pscustomobject]@{message=('Адрес входа канала в SSH-профиле изменён: '+$Old+' — '+$New)})}
}
function Resolve-TransportPorts([string]$Root,$Settings,[int]$ProbeCount,[int]$SocksCount,[switch]$Preview) {
    $Settings|Add-Member -Force Root (Get-TransportHome $Root)
    $configured=Get-TransportConfiguredPorts $Settings.Transport $Settings.Profile;$effective=Copy-TransportObject $configured
    $previous=$null;try{$previous=Read-TransportJson (Join-Path $Root 'state/transport-ports.json')}catch{}
    $snapshot=Get-TransportPortSnapshot -ListenersOnly;$selected=@{};$moved=New-Object Collections.ArrayList;$owners=$null
    # Reserve even an occupied fixed origin before allocating movable inputs/probe/SOCKS blocks.
    $local=Get-TransportValue $Settings 'LocalWeb' $null
    if($local -and $local.enabled){
        $selected[[int]$local.port]=$true;$local.available=Test-TransportPortFree '127.0.0.1' $local.port $snapshot;$local.conflict=$null
        if(-not $local.available){
            try{$owners=Get-TransportPortSnapshot}catch{$owners=$snapshot}
            $local.conflict=Get-TransportPortConflict '127.0.0.1' $local.port $owners
            $local.conflict.message+=' Вход Happier не запущен; освободите фиксированный порт или измените happier.localWeb.port в конфиге. Доступна облачная страница.'
            if(-not $Preview){Write-TransportLog $Root 'happier-port-conflict' ([pscustomobject]@{message=$local.conflict.message})}
        }
    }
    $keys=@('sshPort');if($Settings.Transport.channelFirst){$keys+=@('channelSocksPort')}
    if(@($Settings.Channel.inbounds|Where-Object {$_.tag -eq 'sync'}).Count){$keys+=@('syncPort')};$keys+=@('apiPort','probePortBase','socksPortBase','lanProxyPort','vpnInPort')
    foreach($key in $keys){
        $count=1;$step=10
        if($key -eq 'probePortBase'){$count=$ProbeCount}elseif($key -eq 'socksPortBase'){$count=$SocksCount}
        if($key -in @('probePortBase','socksPortBase')){$step=[int]([Math]::Max(100,[Math]::Ceiling($count/100.0)*100))}
        $from=[int]$configured.$key;$to=Select-TransportPortBlock $from $count $step $snapshot $selected;$effective.$key=$to
        if($from -ne $to){
            $conflict=$null
            if($null -eq $owners){try{$owners=Get-TransportPortSnapshot}catch{$owners=$snapshot}}
            for($i=0;$i -lt $count;$i++){$c=Get-TransportPortConflict '127.0.0.1' ($from+$i) $owners;if($c.listening){$conflict=$c;break}}
            $owner='';if($conflict.exe){$owner=' ('+$conflict.exe+', PID '+$conflict.pid+')'}elseif($conflict.pid){$owner=' (PID '+$conflict.pid+')'}
            [void]$moved.Add([pscustomobject]@{key=$key;from=$from;to=$to;pid=$(if($conflict){$conflict.pid}else{0});exe=$(if($conflict){$conflict.exe}else{''})})
            if(-not $Preview){Write-TransportLog $Root 'port-moved' ([pscustomobject]@{message=('Порт '+$from+' занят другой программой'+$owner+' — использую '+$to)})}
        }
    }
    if($Settings.Transport.channelFirst){
        $from=[string]$configured.channelSshAddress;$to=Find-TransportChannelAddress $configured.serverPort $from $snapshot;$effective.channelSshAddress=$to
        if($from -cne $to){
            if($null -eq $owners){try{$owners=Get-TransportPortSnapshot}catch{$owners=$snapshot}}
            $c=Get-TransportPortConflict $from $configured.serverPort $owners
            [void]$moved.Add([pscustomobject]@{key='channelSshAddress';from=$from;to=$to;pid=$c.pid;exe=$c.exe})
            if(-not $Preview){Write-TransportLog $Root 'port-moved' ([pscustomobject]@{message=($c.message+' — использую '+$to+':'+$configured.serverPort)})}
        }
        if(-not $Preview){
            # Профиль мог хранить предыдущий эффективный адрес либо настроенный адрес.
            $old=$from;if($previous.effective.channelSshAddress){$old=[string]$previous.effective.channelSshAddress}
            Update-TransportChannelRoute $Root $Settings $old $to
            if($old -cne $from){Update-TransportChannelRoute $Root $Settings $from $to}
        }
    }
    if($Settings.Lan.enabled){
        $Settings.Lan.proxyPort=[int]$effective.lanProxyPort
        $effective|Add-Member -Force lan $Settings.Lan
    }
    if(-not $Preview){Write-TransportJson (Join-Path $Root 'state/transport-ports.json') ([ordered]@{schema=1;defaults=(Get-TransportPortDefaults);configured=$configured;effective=$effective;moved=@($moved.ToArray());updatedAt=[DateTime]::UtcNow.ToString('o')}) -Private}
    foreach($key in (Get-TransportPortDefaults).Keys){$Settings.Options[$key]=$effective.$key}
    return $Settings
}

# The paste profile is desired state; older/manual installations can keep this in config.happier.
function Get-TransportLocalWeb($Config) {
    $h=$Config.happier
    if($Config.profile.happier -and $Config.profile.happier.PSObject.Properties['localWeb']){$h=$Config.profile.happier}
    if(-not $h -or -not $h.PSObject.Properties['localWeb']){return [pscustomobject]@{enabled=$false;available=$false;port=0;serverPort=0;conflict=$null}}
    $local=$h.localWeb
    if($local -isnot [pscustomobject]){throw 'happier.localWeb должен быть объектом'}
    foreach($property in $local.PSObject.Properties){if($property.Name -cnotin @('enabled','port','serverPort','hint')){throw 'Неизвестное поле happier.localWeb'}}
    if($local.enabled -isnot [bool]){throw 'happier.localWeb.enabled должен быть boolean'}
    foreach($key in @('port','serverPort')){
        $value=$local.$key
        if($value -isnot [ValueType] -or $value -is [bool] -or [double]$value -ne [Math]::Floor([double]$value) -or [double]$value -lt 1024 -or [double]$value -gt 65535){throw ('Неверный happier.localWeb.'+$key+': нужен целый порт 1024–65535')}
    }
    [pscustomobject]@{enabled=$local.enabled;available=$local.enabled;port=[int]$local.port;serverPort=[int]$local.serverPort;conflict=$null}
}
# Parse the optional public profile only; do not inspect VPN secrets or change Windows networking.
function Assert-LanCidr([string]$Cidr) {
    if($Cidr -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$'){throw 'share.subnets: неверный CIDR'}
    $parts=$Cidr.Split('/');$octets=$parts[0].Split('.');$bits=[int]$parts[1]
    if($bits -lt 8 -or $bits -gt 32){throw 'share.subnets: нужна подсеть RFC1918'}
    [uint64]$ip=0
    foreach($octet in $octets){if([int]$octet -gt 255 -or ($octet.Length -gt 1 -and $octet[0] -eq '0')){throw 'share.subnets: неверный IPv4'};$ip=$ip*256+[int]$octet}
    $private=($octets[0] -eq '10' -and $bits -ge 8) -or ($octets[0] -eq '172' -and [int]$octets[1] -ge 16 -and [int]$octets[1] -le 31 -and $bits -ge 12) -or ($octets[0] -eq '192' -and $octets[1] -eq '168' -and $bits -ge 16)
    if(-not $private -or $ip % [Math]::Pow(2,32-$bits) -ne 0){throw 'share.subnets: нужна каноническая подсеть RFC1918'}
}
function Assert-LanDomain([string]$Domain) {
    $name=$Domain;if($name.StartsWith('*.')){$name=$name.Substring(2)}
    $ip=$null
    if($name.Length -gt 253 -or -not $name.Contains('.') -or [Net.IPAddress]::TryParse($name,[ref]$ip)){throw 'share.domains: нужно DNS-имя'}
    foreach($label in $name.Split('.')){if($label -notmatch '^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'){throw 'share.domains: неверное DNS-имя'}}
}
function Assert-LanIPv4([string]$Address) {
    if($Address -notmatch '^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$'){throw 'share.dnsServers: нужен IPv4'}
    [uint64]$value=0
    foreach($part in $Address.Split('.')){
        if([int]$part -gt 255 -or ($part.Length -gt 1 -and $part[0] -eq '0')){throw 'share.dnsServers: неверный IPv4'}
        $value=$value*256+[int]$part
    }
    return $value
}
function Assert-LanContains([string]$Address,$Subnets) {
    $ip=Assert-LanIPv4 $Address
    foreach($subnet in @($Subnets)){
        Assert-LanCidr ([string]$subnet)
        $parts=([string]$subnet).Split('/');$size=[Math]::Pow(2,32-[int]$parts[1]);$network=Assert-LanIPv4 $parts[0]
        if($ip -ge $network -and $ip -lt $network+$size){return $true}
    }
    return $false
}
function Get-TransportLan($Config) {
    $subnets=@();$domains=@();$dnsServers=@();$networks=@();$probeHost='';$probePort=0;$names=@{}
    foreach($item in @($Config.profile.lan)){
        if(-not $item){continue}
        $name=[string]$item.name
        if($names.ContainsKey($name)){throw 'lan: имена сетей повторяются'};$names[$name]=$true
        if($null -eq $item.share){continue}
        $share=$item.share;$oneSubnets=@();$oneDomains=@();$oneDns=@()
        $keys=if($share -is [Collections.IDictionary]){@($share.Keys)}else{@($share.PSObject.Properties.Name)}
        foreach($subnet in @($share.subnets|Where-Object {$null -ne $_})){Assert-LanCidr ([string]$subnet);$oneSubnets+=[string]$subnet}
        foreach($domain in @($share.domains|Where-Object {$null -ne $_})){Assert-LanDomain ([string]$domain);$oneDomains+=([string]$domain).ToLowerInvariant()}
        if('dnsServers' -in $keys -and $share.dnsServers -isnot [Array]){throw 'share.dnsServers: нужен массив IPv4'}
        $rawDns=@();if('dnsServers' -in $keys){$rawDns=$share.dnsServers}
        foreach($dns in $rawDns){
            if($dns -isnot [string] -or -not (Assert-LanContains ([string]$dns) $oneSubnets)){throw 'share.dnsServers: DNS-сервер должен входить в share.subnets этой сети'}
            if($dns -in $oneDns){throw 'share.dnsServers: адреса повторяются'};$oneDns+=$dns
        }
        if($oneDns.Count -gt 4){throw 'share.dnsServers: не более 4 DNS-серверов'}
        if($oneDomains.Count -gt 0 -and $oneDns.Count -eq 0){throw ('Для доменов сети '+$name+' укажите share.dnsServers (DNS-серверы внутри ЛВС)')}
        $enabled=if('enabled' -in $keys){$share.enabled}else{$true}
        if($enabled -isnot [bool]){throw 'share.enabled: нужно true или false'}
        $hostName=[string](Get-TransportValue $item 'testHost' (Get-TransportValue $item 'host' ''))
        $port=Get-TransportValue $item 'testPort' (Get-TransportValue $item 'port' 22)
        # Keep each network separate, including disabled rows. Deprecated forwards are ignored.
        $networks+=[pscustomobject]@{name=$name;subnets=@($oneSubnets|Select-Object -Unique);domains=@($oneDomains|Select-Object -Unique);dnsServers=@($oneDns);testHost=$hostName;testPort=$port;enabled=$enabled}
        if(-not $enabled -or $oneSubnets.Count+$oneDomains.Count -eq 0){continue}
        if(-not $hostName -or $port -is [bool] -or $port -isnot [ValueType] -or [double]$port -ne [Math]::Floor([double]$port) -or [int]$port -lt 1 -or [int]$port -gt 65535 -or $hostName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*$'){throw 'lan.share: нужен корректный testHost/testPort'}
        $allowed=$false
        if($hostName -match '^[0-9.]+$'){$allowed=Assert-LanContains $hostName $oneSubnets}
        foreach($domain in $oneDomains){if(($domain.StartsWith('*.') -and $hostName.EndsWith($domain.Substring(1),[StringComparison]::OrdinalIgnoreCase)) -or $hostName -ieq $domain){$allowed=$true}}
        if(-not $allowed){throw 'lan.share: testHost должен входить в share этой сети'}
        if(-not $probeHost){$probeHost=$hostName;$probePort=[int]$port}
        $subnets+=$oneSubnets;$domains+=$oneDomains;$dnsServers+=$oneDns
    }
    [pscustomobject]@{networks=@($networks);enabled=($subnets.Count+$domains.Count -gt 0);proxyAddress='127.0.0.1';proxyPort=0;subnets=@($subnets|Select-Object -Unique);domains=@($domains|Select-Object -Unique);dnsServers=@($dnsServers|Select-Object -Unique);forwards=@();probeHost=$probeHost;probePort=$probePort}
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
    $defaults=@{bindPhysical=$true;activeProbeBytes=65536;rankProbeBytes=262144;activeIntervalSec=120;meteredActiveIntervalSec=300;allLivenessIntervalSec=600;meteredAllLivenessIntervalSec=1800;switchFactor=1.5;rankIntervalSec=1800;rankConcurrency=1;topOnMetered=3;stallSeconds=5;probeTimeoutSec=45;metered='auto';restartDelaySec=3;openSsh=$true;singBoxPath=(Join-Path $PSScriptRoot 'sing-box.exe')}
    $portDefaults=Get-TransportPortDefaults;foreach($k in $portDefaults.Keys){$defaults[$k]=$portDefaults[$k]}
    $s=@{};foreach($k in $defaults.Keys){$s[$k]=Get-TransportValue $t $k $defaults[$k]}
    foreach($k in @('bindPhysical','openSsh')){if($s[$k] -isnot [bool]){throw 'Нужен логический параметр transport'}}
    foreach($k in @('sshPort','channelSocksPort','syncPort','lanProxyPort','vpnInPort','probePortBase','socksPortBase','apiPort')){if([int]$s[$k] -lt 1 -or [int]$s[$k] -gt 65535){throw 'Неверный порт transport'}}
    if([string]$s.channelSshAddress -notmatch '\A127\.\d{1,3}\.\d{1,3}\.\d{1,3}\z' -or [string]$s.channelSshAddress -eq '127.0.0.1'){throw 'Неверный адрес входа канала'}
    foreach($k in @('activeProbeBytes','rankProbeBytes','activeIntervalSec','meteredActiveIntervalSec','allLivenessIntervalSec','meteredAllLivenessIntervalSec','switchFactor','rankIntervalSec','rankConcurrency','topOnMetered','stallSeconds','probeTimeoutSec','restartDelaySec')){if([double]$s[$k] -le 0){throw 'Параметры transport должны быть положительными'}}
    if([double]$s.switchFactor -lt 1){throw 'switchFactor должен быть не меньше 1'}
    if($null -ne $t.priority -and $t.priority -isnot [Array]){throw 'priority должен быть массивом префиксов'}
    if($null -ne $t.priority){foreach($prefix in @($t.priority)){if($null -eq $prefix -or $prefix -isnot [string] -or -not $prefix.Trim()){throw 'Неверный префикс priority'}}}
    if([string]$s.metered -notin @('auto','true','false','True','False')){throw 'Неверный metered'}
    if(-not $t.serverRoute -and $config.wizard.serverRoute){$overlay=Get-TransportRouteOverlay $config.wizard.serverRoute $Root;if($overlay){$t|Add-Member -Force serverRoute $overlay}}
    Assert-TransportLists $t -ForBuild
    $effective=Get-TransportEffectivePorts $Root;foreach($k in (Get-TransportPortDefaults).Keys){$s[$k]=$effective.$k}
    [pscustomobject]@{Root=(Get-TransportHome $Root);Options=$s;Transport=$t;Profile=$profile;Channel=$channel;LocalWeb=(Get-TransportLocalWeb $config);Lan=(Get-TransportLan $config);Vpn=(Get-TransportValue $config 'vpn' ([pscustomobject]@{enabled=$false}))}
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
    if(-not [IO.File]::Exists($KnownHosts)){$ex=New-Object Exception('Нет файла закреплённых ключей хоста');$ex.Data['transportReason']='host-key-missing';throw $ex}
    $keygen='ssh-keygen.exe';$resolved=Get-Command $Ssh -ErrorAction SilentlyContinue
    if($resolved -and $resolved.Source){$keygen=Join-Path ([IO.Path]::GetDirectoryName($resolved.Source)) 'ssh-keygen.exe'}
    if($env:OS -ne 'Windows_NT'){$keygen='ssh-keygen'}
    $text=Invoke-TransportText $keygen @('-F',$HostName,'-f',$KnownHosts) @(0,1)
    $keys=@();foreach($line in $text -split "`n"){
        # CA/revoked строки требуют иного trust-policy: не трактуем как обычный ключ.
        if($line -match '^\S+\s+((?:ssh-|ecdsa-)[^ ]+\s+[A-Za-z0-9+/=]+)'){$keys+=$Matches[1]}
    }
    if(-not $keys.Count){$ex=New-Object Exception('Нет закреплённого ключа хоста');$ex.Data['transportReason']='host-key-missing';throw $ex};$keys
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
function Assert-TransportHopKnownHosts($Hop) {
    if($Hop.knownHostsPath -and -not [IO.File]::Exists([string]$Hop.knownHostsPath)){
        $ex=New-Object Exception('Нет ключа хоста промежуточного сервера');$ex.Data['transportReason']='hop-host-key-missing';throw $ex
    }
}
function Add-TransportCandidateFailure($Failures,[string]$Tag,$ErrorRecord,[string]$Root) {
    $reason='candidate-build-failed'
    $known=@('hop-host-key-missing','host-key-missing','executable-not-found','start-failed','command-failed','timeout')
    $value=[string]$ErrorRecord.Exception.Data['transportReason']
    if(-not $value){$value=[string]$ErrorRecord.Exception.Data['transportDiagnostic'].reason}
    if($value -in $known){$reason=$value}
    $detail=New-TransportDiagnostic $null $Tag $reason
    $detail.exitCode=$ErrorRecord.Exception.Data['transportDiagnostic'].exitCode
    $messages=@{'hop-host-key-missing'='Нет ключа хоста промежуточного сервера';'host-key-missing'='Нет закреплённого ключа хоста';'executable-not-found'='Программа или файл запуска не найдены';'start-failed'='Не удалось запустить дочерний процесс';'command-failed'='Внешняя команда завершилась с ошибкой';'timeout'='Таймаут внешней команды';'candidate-build-failed'='Не удалось построить кандидат'}
    $detail.stderr=$messages[$reason]
    [void]$Failures.Add([pscustomobject]@{tag=$detail.candidate;diagnostic=$detail})
    Write-TransportLog $Root 'process-failed' $detail
}
function Get-TransportCandidates($Settings,[string]$Root) {
    $p=$Settings.Profile;$t=Copy-TransportObject $Settings.Transport;$o=$Settings.Options;$out=New-Object Collections.ArrayList;$c=New-Object Collections.ArrayList;$tunnels=New-Object Collections.ArrayList;$failures=New-Object Collections.ArrayList
    # Personal route is a local overlay, kept outside the public server catalog.
    $route=$t.serverRoute
    if($route -and $route.used -ne 'direct' -and -not $p.routeProxyCommand){
        try{
        $proxyExe=[string]$route.proxyExecutable;if(-not $proxyExe){$proxyExe=Join-Path $Root 'RemoteAgents.exe'}
        $routeOptions=@(New-TransportRouteOptions $route $p $proxyExe)
        if($route.used -eq 'hop'){
            if(-not $o.openSsh -and -not @($Settings.Channel.outbounds|Where-Object {$_.type -eq 'vless'}).Count){throw 'Для выбранного промежуточного сервера включите OpenSSH в настройках связи'}
            $hop=Copy-TransportObject $route.hop
            # A stable local name replaces a public homonym only inside this effective overlay.
            $hop|Add-Member -Force name 'wizard-server-route';$hop|Add-Member -Force enabled $true
            $hop|Add-Member -Force configPath ([string]$p.configPath)
            if(-not $hop.knownHostsPath){$hop|Add-Member knownHostsPath (Join-Path (Split-Path $p.knownHostsPath -Parent) 'known_hosts-hop')}
            $t|Add-Member -Force hops (@($t.hops|Where-Object {$_ -and $_.name -ne $hop.name})+@($hop))
        }
        }catch{
            if($route.used -eq 'hop'){
                if(@($Settings.Channel.outbounds|Where-Object {$_.type -eq 'vless'}).Count){Add-TransportCandidateFailure $failures 'vless-sshhop-wizard-server-route' $_ $Root}
                if($o.openSsh){Add-TransportCandidateFailure $failures 'openssh-jump-wizard-server-route' $_ $Root}
            }else{Add-TransportCandidateFailure $failures 'openssh-proxy' $_ $Root}
            $route=$null
        }
    }
    $vless=@($Settings.Channel.outbounds|Where-Object {$_.type -eq 'vless'}|Select-Object -First 1)
    $v=$null
    if($vless.Count){
    $v=Copy-TransportObject $vless[0];$v.tag='vless-direct';$v.server=$p.serverAddress
    if($v.PSObject.Properties['detour']){$v.PSObject.Properties.Remove('detour')}
    [void]$out.Add($v);[void]$c.Add([pscustomobject]@{tag=$v.tag;port=0})
    }
    # Channel first = a network that cuts direct SSH after the handshake. Direct SSH candidates there never work, and every
    # attempt hangs on the server until LoginGraceTime: with tunnel restarts they fill MaxStartups and sshd starts refusing
    # everyone, the channel's own SSH included. Such a config carries the channel; direct SSH is not tried at all.
    $directSsh=-not $t.channelFirst
    if($directSsh -and (-not $t.bootstrap -or ((Test-Path $p.knownHostsPath) -and (Get-Item $p.knownHostsPath).Length -gt 1))){
    try{
    $ssh=@{type='ssh';tag='singbox-ssh-direct';server=$p.serverAddress;server_port=(Get-TransportServerPort $p);user=$p.login;private_key_path=$p.keyPath}
    $saved=@($Settings.Channel.outbounds|Where-Object {$_.type -eq 'ssh' -and $_.server -eq $p.serverAddress}|Select-Object -First 1)
    if($saved.Count){$ssh=Copy-TransportObject $saved[0];$ssh.tag='singbox-ssh-direct';if($ssh.PSObject.Properties['detour']){$ssh.PSObject.Properties.Remove('detour')}}
    if(-not $ssh.host_key){$hk=@(Get-TransportHostKeys $p.sshExecutable $p.serverAddress $p.knownHostsPath);if($ssh -is [hashtable]){$ssh.host_key=$hk}else{$ssh|Add-Member -Force host_key $hk}}
    Set-TransportHostKeyAlgorithms $ssh
    [void]$out.Add($ssh);[void]$c.Add([pscustomobject]@{tag=$ssh.tag;port=0})
    }catch{Add-TransportCandidateFailure $failures 'singbox-ssh-direct' $_ $Root}
    }
    foreach($relay in @($t.relays)){
        if($null -eq $relay -or -not (Test-TransportEnabled $relay)){continue};try{Assert-TransportName $relay.name;Assert-TransportCandidateSettings $relay 'relays' $t
        if(-not (Get-TransportValue $relay 'host' $relay.server) -or [int]$relay.port -lt 1 -or [int]$relay.port -gt 65535){throw 'Неполный ретранслятор'}
        if(-not $v){throw 'Для relay нужен VLESS канала сервера'}
        $r=Copy-TransportObject $v;$r.tag='vless-relay-'+$relay.name;$r.server=(Get-TransportValue $relay 'host' $relay.server);$r.server_port=[int]$relay.port
        [void]$out.Add($r);[void]$c.Add([pscustomobject]@{tag=$r.tag;port=0})
    }catch{Add-TransportCandidateFailure $failures ('vless-relay-'+$relay.name) $_ $Root}
    }
    foreach($hop in @($t.hops)){
        if($null -eq $hop -or -not (Test-TransportEnabled $hop)){continue};try{Assert-TransportName $hop.name;Assert-TransportCandidateSettings $hop 'hops' $t
        if(-not $v){continue}
        if(-not (Get-TransportValue $hop 'ssh' $hop.alias) -or (Get-TransportValue $hop 'ssh' $hop.alias) -match '^[\-]|[\r\n]'){throw 'Неверный SSH-алиас'}
        Assert-TransportHopKnownHosts $hop
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
    }catch{Add-TransportCandidateFailure $failures ('vless-sshhop-'+$hop.name) $_ $Root}
    }
    foreach($entry in @($t.entries)){
        if($null -eq $entry -or -not (Test-TransportEnabled $entry)){continue};try{Assert-TransportName $entry.name;Assert-TransportCandidateSettings $entry 'entries' $t
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
    }catch{
        $kinds=@('hy2','hy2obfs','tuic','trojan','reality','shadowtls','ws-direct','ws-cdn');if($entry.kinds){$kinds=@($entry.kinds)}
        foreach($kind in $kinds){Add-TransportCandidateFailure $failures ($kind+'-'+$entry.name) $_ $Root}
    }
    }
    foreach($cdn in @($t.cdn)){
        if($null -eq $cdn -or -not (Test-TransportEnabled $cdn)){continue}
        try{
        Assert-TransportCandidateSettings $cdn 'cdn' $t
        $e=Read-TransportJson (Join-Path (Get-TransportCacheRoot $Settings $Root) ('secrets/entries/'+$cdn.entry+'.json'));$x=$e.secrets
        if(-not $x.ws_uuid -or -not $x.ws_path){throw 'Узел не содержит WebSocket'}
        $r=@{type='vless';tag=('cdn-'+$cdn.name);server=$cdn.domain;server_port=443;uuid=$x.ws_uuid;
            tls=@{enabled=$true;server_name=$cdn.domain;alpn=@('http/1.1');utls=@{enabled=$true;fingerprint='chrome'}};
            transport=@{type='ws';path=(Get-TransportValue $cdn 'path' $x.ws_path);headers=@{Host=$cdn.domain};max_early_data=2048;early_data_header_name='Sec-WebSocket-Protocol'}}
        [void]$out.Add($r);[void]$c.Add([pscustomobject]@{tag=$r.tag;port=0})
    }catch{Add-TransportCandidateFailure $failures ('cdn-'+$cdn.name) $_ $Root}
    }
    # The saved route may be the daemon's own channel SOCKS (channel first): tunnels then go direct, never through themselves.
    $ownChannel=($route -and $route.used -eq 'proxy' -and [string]$route.proxy.host -in @('127.0.0.1','localhost') -and [int]$route.proxy.port -in @([int]$o.channelSocksPort,[int](Get-TransportConfiguredPorts $Settings.Transport $p).channelSocksPort))
    # OpenSSH из профиля + SOCKS (-D): один туннель несёт и SSH, и Syncthing через selector.
    if($o.openSsh -and $directSsh){
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
            $tag='openssh-jump-'+$hop.name
            try{
            Assert-TransportCandidateSettings $hop 'hops' $t
            Assert-TransportHopKnownHosts $hop
            $port=[int]$o.socksPortBase+$tunnels.Count
            $resolved=Get-TransportHopArguments $hop ([string]$hop.knownHostsPath)
            $proxy=@([string]$p.sshExecutable)+@($resolved.options)+@('-W','%h:%p',$resolved.target)
            $command=(@($proxy|ForEach-Object {Quote-Transport $_})) -join ' '
            $a=@(Get-TransportSshArguments $p (Get-TransportServerPort $p))|ForEach-Object {if($_ -like 'ProxyCommand=*'){'ProxyCommand='+$command}else{$_}}
            $a+=@('-N','-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2','-D',('127.0.0.1:'+$port))
            [void]$out.Add(@{type='socks';tag=$tag;server='127.0.0.1';server_port=$port;version='5'})
            [void]$c.Add([pscustomobject]@{tag=$tag;port=0})
            [void]$tunnels.Add([pscustomobject]@{tag=$tag;arguments=$a;target=$p.serverAddress;bind=$false})
            }catch{Add-TransportCandidateFailure $failures $tag $_ $Root}
        }
    }
    # A saved route through the daemon's own channel SOCKS entry must not become a daemon path: that is a loop.
    if($route -and $route.used -eq 'proxy' -and -not $ownChannel){
        try{
        if(-not $o.openSsh){throw 'Для выбранного локального прокси включите OpenSSH в настройках связи'}
        $port=[int]$o.socksPortBase+$tunnels.Count;$tag='openssh-proxy'
        $proxyExe=[string]$route.proxyExecutable;if(-not $proxyExe){$proxyExe=Join-Path $Root 'RemoteAgents.exe'}
        $routeOptions=@(New-TransportRouteOptions $route $p $proxyExe)
        $a=@(Get-TransportSshArguments $p (Get-TransportServerPort $p))|ForEach-Object {if($_ -eq 'ProxyCommand=none'){$routeOptions[1]}else{$_}}
        $a+=@('-N','-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2','-D',('127.0.0.1:'+$port))
        [void]$out.Add(@{type='socks';tag=$tag;server='127.0.0.1';server_port=$port;version='5'})
        [void]$c.Add([pscustomobject]@{tag=$tag;port=0})
        [void]$tunnels.Add([pscustomobject]@{tag=$tag;arguments=$a;target=$p.serverAddress;bind=$false})
    }catch{Add-TransportCandidateFailure $failures 'openssh-proxy' $_ $Root}
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
    foreach($failure in $failures){
        $meta=Get-TransportCandidateInfo $failure.tag $t
        [void]$all.Add([pscustomobject]@{tag=$failure.tag;port=0;title=$meta.title;kind=$meta.kind;via=$meta.via;enabled=($failure.tag -notin @($t.disabledTags));tunCapable=$false;buildFailed=$true;diagnostic=$failure.diagnostic})
    }
    foreach($candidate in $all){$candidate|Add-Member -Force priority (Get-TransportPriority $candidate.tag @($t.priority))}
    $enabled=@($all.ToArray()|Where-Object {$_.enabled -and -not $_.buildFailed});$enabledTags=@($enabled|ForEach-Object {$_.tag})
    if(-not $enabled.Count){throw 'Нет доступных кандидатов транспорта'}
    # Не оставляем выключенные внешние сокеты/SSH-туннели в рабочем процессе.
    $needed=@{};foreach($tag in $enabledTags){Add-TransportDependency $tag @($out.ToArray()) $needed}
    [pscustomobject]@{Outbounds=@($out.ToArray()|Where-Object {$needed.ContainsKey($_.tag)});Candidates=$enabled;AllCandidates=@($all.ToArray());Tunnels=@($tunnels.ToArray()|Where-Object {$_.tag -in $enabledTags})}
}

function New-TransportConfig($Settings,$Paths,[string]$Secret,[string]$DefaultTag,[string]$Interface='') {
    $o=$Settings.Options;$portDefaults=Get-TransportPortDefaults;$sync=@($Settings.Channel.inbounds|Where-Object {$_.tag -eq 'sync'}|Select-Object -First 1)
    if($sync.Count -and ([int]$sync[0].override_port -lt 1 -or [int]$sync[0].override_port -gt 65535)){throw 'Неверный порт Syncthing канала'}
    $in=@();$rules=@();$ports=@{}
    $targets=New-Object Collections.ArrayList;[void]$targets.Add(@('ssh',[int]$o.sshPort,(Get-TransportServerPort $Settings.Profile)))
    if($sync.Count){[void]$targets.Add(@('sync',[int]$o.syncPort,[int]$sync[0].override_port))}
    $local=Get-TransportValue $Settings 'LocalWeb' $null
    if($local -and $local.enabled -and $local.available){[void]$targets.Add(@('happier-web',[int]$local.port,[int]$local.serverPort))}
    # Channel first (config.transport.channelFirst): a loopback SOCKS entry to the server's sshd through the active path,
    # the same meaning as the 'ssh' entry; the wizard's SSH uses it as a 'proxy' route before any other route.
    if($Settings.Transport.channelFirst){
        $in+=@{type='mixed';tag='channel-socks';listen='127.0.0.1';listen_port=[int]$o.channelSocksPort}
        $rules+=@{inbound=@('channel-socks');action='route-options';override_address='127.0.0.1';override_port=(Get-TransportServerPort $Settings.Profile)}
        $rules+=@{inbound=@('channel-socks');action='route';outbound='active'}
        # The SSH entry of the channel: ssh connects here itself (HostName + HostKeyAlias), no ProxyCommand helper.
        # Its own loopback address keeps the server's port, so the route needs no Port that a -p elsewhere would shadow.
        $in+=@{type='direct';tag='channel-ssh';listen=[string]$o.channelSshAddress;listen_port=(Get-TransportServerPort $Settings.Profile);network='tcp';override_address='127.0.0.1';override_port=(Get-TransportServerPort $Settings.Profile)}
        $rules+=@{inbound=@('channel-ssh');action='route';outbound='active'}
    }
    foreach($row in $targets){
        $in+=@{type='direct';tag=$row[0];listen='127.0.0.1';listen_port=$row[1];network='tcp';override_address='127.0.0.1';override_port=$row[2]}
        $rules+=@{inbound=@($row[0]);action='route';outbound='active'}
    }
    foreach($c in $Paths.Candidates){$tag='probe-'+$c.tag;$in+=@{type='direct';tag=$tag;listen='127.0.0.1';listen_port=$c.port;network='tcp';override_address='127.0.0.1';override_port=(Get-TransportServerPort $Settings.Profile)};$rules+=@{inbound=@($tag);action='route';outbound=$c.tag}}
    $helper=Get-TransportHelperSecret ([string]$Settings.Root)
    $users=@(@{username=$helper.user;password=$helper.password})
    $in+=@{type='mixed';tag='lan-in';listen='127.0.0.1';listen_port=[int](Get-TransportValue $o 'lanProxyPort' $portDefaults.lanProxyPort);users=$users}
    $in+=@{type='mixed';tag='vpn-in';listen='127.0.0.1';listen_port=[int](Get-TransportValue $o 'vpnInPort' $portDefaults.vpnInPort);users=$users}
    $lan=Get-TransportValue $Settings 'Lan' $null
    if($lan -and $lan.enabled){
        if(@($lan.subnets).Count){$rules+=@{inbound=@('lan-in');ip_cidr=@($lan.subnets);action='route';outbound='active'}}

    }
    $rules+=@{inbound=@('lan-in');action='reject'}
    $rules+=@{inbound=@('vpn-in');action='route';outbound='active'}
    foreach($port in @(@($in|Where-Object {$_.listen -eq '127.0.0.1'}|ForEach-Object {$_.listen_port})+@([int]$o.apiPort)+@($Paths.Outbounds|Where-Object {$_.type -eq 'socks'}|ForEach-Object {$_.server_port}))){
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
# A separate credential lets the elevated helper use the channel without its outbound secrets.
function Get-TransportHelperSecret([string]$Root) {
    if(-not $Root){throw 'Не задан Home для секрета помощника'}
    $file=Join-Path $Root 'state/helper-socks.json'
    $mutex=New-Object Threading.Mutex($false,('Global\RemoteAgentsHelperSocks-'+(Get-TransportFingerprint 'helper' (Get-TransportHome $Root).ToLowerInvariant())));$locked=$false
    try{
        try{$locked=$mutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){throw 'Секрет помощника занят'}
        if(Test-Path -LiteralPath $file){
            Protect-TransportPath ([IO.Path]::GetDirectoryName($file));Protect-TransportPath $file -System
            try{
                $value=Read-TransportJson $file
                $bytes=[Convert]::FromBase64String([string]$value.password)
                if($value.user -cne 'ra-helper' -or $bytes.Length -ne 32 -or [Convert]::ToBase64String($bytes) -cne $value.password){throw 'invalid'}
            }catch{throw 'Неверный секрет помощника'}
            return $value
        }
        $bytes=New-Object byte[] 32;$rng=[Security.Cryptography.RandomNumberGenerator]::Create()
        try{$rng.GetBytes($bytes)}finally{$rng.Dispose()}
        $value=[pscustomobject]@{user='ra-helper';password=[Convert]::ToBase64String($bytes)}
        Write-TransportJson $file $value -Private -System
        return $value
    }finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Get-TransportHelperStatus($Settings,[string]$Tag,$Outbounds) {
    $defaults=Get-TransportPortDefaults
    [pscustomobject]@{lanInPort=[int](Get-TransportValue $Settings.Options 'lanProxyPort' $defaults.lanProxyPort);vpnInPort=[int](Get-TransportValue $Settings.Options 'vpnInPort' $defaults.vpnInPort);udp=[bool]($Tag -and (Test-TransportInternetPath $Tag $Outbounds))}
}
function Set-TransportSelector($Options,[string]$Secret,[string]$Tag) {
    # WebRequest без системного прокси: локальный API не зависит от Happ/WinHTTP.
    $req=[Net.HttpWebRequest]::Create(('http://127.0.0.1:'+$Options.apiPort+'/proxies/active'));$req.Proxy=$null;$req.Method='PUT';$req.Timeout=1500;$req.ContentType='application/json';$req.Headers['Authorization']='Bearer '+$Secret
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress @{name=$Tag}));$req.ContentLength=$bytes.Length
    try{$s=$req.GetRequestStream();try{$s.Write($bytes,0,$bytes.Length)}finally{$s.Dispose()};$response=$req.GetResponse();$response.Dispose()}catch{throw 'Локальный API transport недоступен'}
}
function New-TransportProbeState([long]$Target,[double]$Stall,[double]$Timeout) {
    [pscustomobject]@{target=$Target;stall=$Stall;timeout=$Timeout;bytes=[long]0;first=$null;last=$null;firstBytes=[long]0;state='pending';kbps=$null;maxGapMs=0;latencyMs=$null}
}
function Update-TransportProbeState($State,[long]$Bytes,[double]$Seconds,[bool]$Ended=$false) {
    if($State.state -ne 'pending'){return $State}
    $gap=0;if($null -ne $State.last){$gap=$Seconds-$State.last;$State.maxGapMs=[math]::Max($State.maxGapMs,[math]::Round($gap*1000))}
    if($Bytes -gt $State.bytes){if($null -eq $State.first){$State.first=$Seconds;$State.latencyMs=[math]::Max(1,[math]::Ceiling($Seconds*1000));$State.firstBytes=$Bytes};$State.last=$Seconds;$State.bytes=$Bytes}
    if($Bytes -ge $State.target){
        # Эффективная скорость от начала пробы: ssh.exe отдаёт поток пачками, «от первого байта» даёт сотни МБ/с.
        $State.state='ok';if($Seconds -gt 0){$State.kbps=[math]::Round($Bytes/1KB/$Seconds,2)}
    }elseif($gap -ge $State.stall){$State.state='frozen'
    }elseif($Ended -or $Seconds -ge $State.timeout){
        if($Bytes -gt 0 -and -not $Ended){$State.state='slow'}else{$State.state='fail'}
    }
    $State
}
# Небольшой Stream нужен вместо PowerShell callback: CopyToAsync считает байты и время
# на потоке .NET без задержек цикла демона, без файла и без накопления скачанного в памяти.
function Initialize-TransportCounter {Initialize-TransportDiagnostics}
function Start-TransportProbe($Profile,$Candidate,[long]$Bytes,$Options,[string]$Purpose) {
    Initialize-TransportCounter
    $a=@(Get-TransportSshArguments $Profile $Candidate.port)+@('127.0.0.1',('head -c '+$Bytes+' /dev/urandom'))
    $sink=New-Object RemoteAgents.TransportCounter;$child=$null
    try{
        $child=Start-TransportProcess $Profile.sshExecutable $a -Probe
        $copy=$child.Process.StandardOutput.BaseStream.CopyToAsync($sink)
        [pscustomobject]@{tag=$Candidate.tag;purpose=$Purpose;child=$child;sink=$sink;copy=$copy;state=(New-TransportProbeState $Bytes $Options.stallSeconds $Options.probeTimeoutSec)}
    }catch{Stop-TransportProcess $child;$sink.Dispose();throw 'Не удалось начать чтение SSH'}
}
function Receive-TransportProbe($Probe) {
    # Завершённость фиксируем ДО снимка: CopyToAsync может дописать последние байты между ними.
    $completed=$Probe.copy.IsCompleted;$x=$Probe.sink.Snapshot();$freq=[double][Diagnostics.Stopwatch]::Frequency
    $elapsed=([Diagnostics.Stopwatch]::GetTimestamp()-$Probe.sink.Started)/$freq
    $s=$Probe.state;$s.bytes=$x[0]
    if($x[1] -ne 0){$s.first=($x[1]-$Probe.sink.Started)/$freq;$s.last=($x[2]-$Probe.sink.Started)/$freq;$s.firstBytes=$x[3]}
    if($null -ne $s.first){$s.latencyMs=[math]::Max(1,[math]::Ceiling($s.first*1000))}
    $gap=$x[4]/$freq;if($s.bytes -lt $s.target -and $null -ne $s.last){$gap=[math]::Max($gap,$elapsed-$s.last)}
    $s.maxGapMs=[math]::Round($gap*1000)
    if($s.bytes -ge $s.target){
        $s.state='ok';$dt=($x[2]-$Probe.sink.Started)/$freq
        if($dt -gt 0){$s.kbps=[math]::Round($s.bytes/1KB/$dt,2)}
    }elseif($gap -ge $s.stall){$s.state='frozen'}
    elseif($completed){$s.state='fail'}
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
function Get-TransportPriority([string]$Tag,$Prefixes) {
    for($i=0;$i -lt $Prefixes.Count;$i++){if($null -ne $Prefixes[$i] -and $Tag.StartsWith([string]$Prefixes[$i],[StringComparison]::OrdinalIgnoreCase)){return $i}}
    return 999
}
function Get-TransportOrdered($Rows) {
    $Rows|Sort-Object @{Expression={if($_.enabled -eq $false){3}elseif($_.state -eq 'ok'){0}elseif($_.state -eq 'remembered'){1}else{2}}},@{Expression={[int](Get-TransportValue $_ 'priority' 999)}},@{Expression={if($null -eq $_.kbps){-1}else{[double]$_.kbps}};Descending=$true},@{Expression={if($null -eq $_.latencyMs){[double]::MaxValue}else{[double]$_.latencyMs}}},tag
}
function Get-TransportBest($Rows,[string[]]$Allowed=@(),[switch]$Remembered) {
    Get-TransportOrdered @($Rows|Where-Object {($_.enabled -ne $false) -and ($_.state -eq 'ok' -or ($Remembered -and $_.state -eq 'remembered')) -and (-not $Allowed.Count -or $_.tag -in $Allowed)})|Select-Object -First 1
}
function Test-TransportBetter($Current,$Best,$Options) {
    if(-not $Best){return $false}
    if(-not $Current -or $Current.state -ne 'ok'){return $true}
    [double]$Best.kbps -gt 0 -and [double]$Best.kbps -ge ([double]$Current.kbps*[double]$Options.switchFactor)
}
function Get-TransportRankTags($Rows,$Candidates,$Options,$Metered) {
    if($Metered -eq $false){return @($Candidates|ForEach-Object {$_.tag})}
    # Неизвестная стоимость тоже экономная; память имеет приоритет над непроверенными.
    Get-TransportOrdered @($Rows|Where-Object {$_.enabled -ne $false -and $_.tag -in @($Candidates|ForEach-Object {$_.tag})})|Select-Object -First ([int]$Options.topOnMetered)|ForEach-Object {$_.tag}
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
        if($c.buildFailed -and $c.enabled -ne $false){$state='fail';$speed=$null;$checked=[DateTime]::UtcNow.ToString('o')}
        $row=[pscustomobject]@{tag=$c.tag;title=$c.title;kind=$c.kind;via=$c.via;enabled=($c.enabled -ne $false);state=$state;kbps=$speed;checkedAt=$checked;suspect=$false;priority=[int](Get-TransportValue $c 'priority' 999);order=0;latencyMs=$r.latencyMs;lastOkAt=$r.lastOkAt;lastFailAt=$r.lastFailAt;rankState=$null;maxGapMs=$null}
        if($c.buildFailed){$row|Add-Member diagnostic $c.diagnostic}
        $row
    }
}

function Test-TransportEnabled($Item) {return ((Get-TransportValue $Item 'enabled' $true) -eq $true)}
function Assert-TransportLists($Transport,[switch]$ForBuild) {
    $names=@{}
    foreach($group in @('entries','relays','hops','cdn')){foreach($item in @($Transport.$group)){
        if($null -eq $item){continue};Assert-TransportName $item.name
        if($names.ContainsKey($item.name)){throw 'Имена узлов должны быть уникальны во всех списках'};$names[$item.name]=$true
        if((Get-TransportValue $item 'enabled' $true) -isnot [bool]){throw 'enabled должен быть boolean'}
        if(-not $ForBuild){Assert-TransportCandidateSettings $item $group $Transport}
    }}
    foreach($tag in @($Transport.disabledTags)){if($null -ne $tag){Assert-TransportTag $tag}}
}
function Assert-TransportCandidateSettings($Item,[string]$Group,$Transport) {
    if($group -in @('entries','hops')){$ssh=Get-TransportValue $item 'ssh' $item.alias;if(-not $ssh -or $ssh -match '^[\-]|[\r\n]'){throw 'Неверный SSH-алиас'}}
    if($group -eq 'hops'){foreach($field in @('keyFile','knownHostsPath')){if($item.$field -and ([string]$item.$field -match '[\r\n\x00]')){throw 'Неверный локальный путь промежуточного сервера'}}}
    if($group -eq 'entries'){foreach($kind in @($item.kinds)){if($null -ne $kind -and $kind -notin @('hy2','hy2obfs','tuic','trojan','reality','shadowtls','ws-direct','ws-cdn')){throw 'Неизвестный kind'}}}
    if($group -eq 'relays'){if(-not (Get-TransportValue $item 'host' $item.server) -or [int]$item.port -lt 1 -or [int]$item.port -gt 65535){throw 'Неверный relay'}}
    if($group -eq 'cdn'){
        if($item.domain -notmatch '^(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$'){throw 'Неверный домен CDN'}
        if(-not @($Transport.entries|Where-Object {$_.name -eq $item.entry}).Count){throw 'Не найден узел CDN'}
        if($item.path -and ($item.path -notmatch '^/' -or $item.path -match '[\r\n]')){throw 'Неверный путь CDN'}
    }
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
    # One spelling of Home for daemon and Bootstrap (relative/trailing separators differ at entry).
    $Root=Get-TransportHome $Root
    # Содержимое, а не mtime: Syncthing/атомарная замена и одинаковая длина не скрывают изменение.
    $config=Read-TransportJson (Join-Path $Root 'config.json');$files=@()
    foreach($field in @('profilePath','channelPath')){if($config.transport.$field){$files+=[string]$config.transport.$field}}
    $files=@($files|Select-Object -Unique)
    $cache=Join-Path (Get-TransportValue $config.transport 'cacheRoot' $Root) 'secrets/entries';if(Test-Path -LiteralPath $cache){$files+=@(Get-ChildItem -LiteralPath $cache -Filter '*.json'|Sort-Object Name|ForEach-Object {$_.FullName})}
    $route=$config.transport.serverRoute;if(-not $route){$route=$config.wizard.serverRoute}
    if($route.used -eq 'hop' -and $config.transport.profilePath){$p=Read-TransportJson $config.transport.profilePath;$kh=Join-Path (Split-Path $p.knownHostsPath -Parent) 'known_hosts-hop';if(Test-Path $kh){$files+=$kh}}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$text=(ConvertTo-Json -InputObject (Get-TransportLan $config) -Depth 20 -Compress)+(ConvertTo-Json -InputObject (Get-TransportLocalWeb $config) -Depth 5 -Compress)+(ConvertTo-Json -InputObject $route -Depth 20 -Compress)+(ConvertTo-Json -InputObject $config.transport -Depth 40 -Compress)+"`n"+((@($files|ForEach-Object {$(if($env:OS -eq 'Windows_NT'){[IO.Path]::GetFullPath($_).Replace('\','/').ToLowerInvariant()}else{[IO.Path]::GetFullPath($_)})+"`n"+(Convert-TransportLF ([IO.File]::ReadAllText($_)))})) -join "`n");[Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))}finally{$sha.Dispose()}
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
    if(-not (Test-ProductVpnEnabled)){$result.enabled=$false}
    if($result.enabled -isnot [bool]){throw 'vpn.enabled должен быть boolean'}
    if($result.interfaceName -notmatch '^RemoteAgents-[a-zA-Z0-9_-]{1,32}$'){throw 'Неверное имя нашего TUN'}
    $uri=$null;if(-not [Uri]::TryCreate($result.checkUrl,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https'){throw 'vpn.checkUrl должен быть HTTPS'}
    if($uri.HostNameType -ne [UriHostNameType]::Dns){throw 'vpn.checkUrl должен содержать домен для проверки защищённого DNS'}
    foreach($cidr in @($result.address)+@($result.excludeCidrs)){Assert-VpnCidr $cidr}
    $ip=$null;if(-not [Net.IPAddress]::TryParse($result.dnsServer,[ref]$ip)){throw 'vpn.dnsServer должен быть IP'}
    $ip=$null;if(-not [Net.IPAddress]::TryParse($result.probeAddress,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'vpn.probeAddress должен быть IPv4'}
    return $result
}
function Get-VpnSnapshot([switch]$IncludeDns) {
    # Ошибка инвентаризации не означает отсутствие конфликтов: вызывающий запрещает включение.
    $snapshot=[pscustomobject]@{Processes=@(Get-CimInstance Win32_Process -ErrorAction Stop);Adapters=@(Get-NetAdapter -IncludeHidden -ErrorAction Stop);Routes=@(Get-NetRoute -ErrorAction Stop)}
    if($IncludeDns){
        # Read effective policy, not just local NRPT rules: MagicDNS can use NRPT
        # without putting its resolver into the adapter's DNS server list.
        $snapshot|Add-Member DnsServers @(Get-DnsClientServerAddress -ErrorAction Stop)
        $snapshot|Add-Member DnsClients @(Get-DnsClient -ErrorAction Stop)
        $snapshot|Add-Member Nrpt @(Get-DnsClientNrptPolicy -Effective -ErrorAction Stop)
    }
    $snapshot
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
function Assert-VpnCidr([string]$Cidr) {
    $parts=$Cidr.Split('/');$ip=$null;$bits=0
    if($parts.Count -ne 2 -or -not [Net.IPAddress]::TryParse($parts[0],[ref]$ip) -or -not [int]::TryParse($parts[1],[ref]$bits)){throw 'Неверный CIDR VPN'}
    $max=128;if($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork){$max=32}
    if($bits -lt 0 -or $bits -gt $max){throw 'Неверная маска VPN'}
}
function Write-VpnStatus([string]$Root,[bool]$Ok,[bool]$Enabled,[string]$State,$Conflict,[string]$Summary,[string]$Stage='',[string]$ErrorType='') {
    Write-TransportJson (Join-Path $Root 'status/vpn.json') @{ok=$Ok;enabled=$Enabled;state=$State;conflict=$Conflict;summary=$Summary;stage=$Stage;errorType=$ErrorType;updatedAt=[DateTime]::UtcNow.ToString('o')}
    # Журнал всегда локальный; только категория, без текста исключений и параметров процессов.
    $dir=Join-Path $Root 'logs';[void][IO.Directory]::CreateDirectory($dir);$file=Join-Path $dir 'vpn.log'
    if((Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).Length -ge 1MB){Move-Item -LiteralPath $file -Destination ($file+'.1') -Force}
    [IO.File]::AppendAllText($file,([DateTime]::UtcNow.ToString('o')+' '+$State+' stage='+$Stage+' type='+$ErrorType+"`n"),(New-Object Text.UTF8Encoding($false)))
}
function Set-VpnEnabled([string]$Root,[bool]$Enabled) {
    $Enabled=$Enabled -and (Test-ProductVpnEnabled)
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
# The bounded HTTPS probe and route assertion run in VpnProbe.cs in the elevated host.
# No SSH, DNS or HTTPS waits on the PowerShell lifecycle thread.
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


function Sync-TransportEntryCache($Settings,[string]$Root) {
    # Новые entries загружаются в background reload, не блокируя pin/API.
    # Старый кэш обновляет только явная Update-Entries.ps1; host keys не принимаются автоматически.
    foreach($entry in @($Settings.Transport.entries)){
        if(-not $entry -or -not (Test-TransportEnabled $entry)){continue}
        $file=Join-Path (Get-TransportCacheRoot $Settings $Root) ('secrets/entries/'+$entry.name+'.json');if(Test-Path -LiteralPath $file){continue}
        try{
        $args=@('-n','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','-o','StrictHostKeyChecking=yes')
        if($entry.configPath){$args+=@('-F',[string]$entry.configPath)}
        $alias=Get-TransportValue $entry 'ssh' $entry.alias
        $text=Invoke-TransportText $Settings.Profile.sshExecutable ($args+@([string]$alias,'cat /opt/rd-entry/client.json'))
        $data=ConvertFrom-Json (Convert-TransportLF $text)
        foreach($field in @('server','sni','cover','ports','secrets')){if(-not $data.$field){throw 'Неполный client.json'}}
        Write-TransportJson $file $data -Private
        }catch{Write-TransportLog $Root 'process-failed' (New-TransportDiagnostic $null ('entry-'+$entry.name) 'entry-cache-unavailable')}
    }
}

function Initialize-TransportDiagnostics {
    if('RemoteAgents.TransportErrorBuffer' -as [type]){return}
    # Both helper streams (stderr buffer, probe counter) in ONE compilation: on PS 5.1 every Add-Type runs csc.exe.
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Diagnostics;
namespace RemoteAgents {
 public sealed class TransportErrorBuffer : Stream {
  readonly object gate = new object();
  readonly byte[] first = new byte[2048], recent = new byte[8192];
  int firstCount, recentCount; bool firstDone;
  public override void Write(byte[] b, int o, int n) {
   lock(gate) {
    for(int i=o;i<o+n;i++) {
     if(!firstDone) { if(firstCount<first.Length) first[firstCount++]=b[i]; if(b[i]==10 || firstCount==first.Length) firstDone=true; }
     if(recentCount==recent.Length) {Buffer.BlockCopy(recent,4096,recent,0,4096);recentCount=4096;recentCut=true;}
     recent[recentCount++]=b[i];
    }
   }
  }
  bool recentCut;
  public string Snapshot() {lock(gate) return Decode(first,firstCount,false,firstCount==first.Length && first[first.Length-1]!=10)+"\n"+Decode(recent,recentCount,recentCut,false);}
  // Windows PowerShell 5.1 writes a redirected child's output in the console OEM code page (cp866 on Russian Windows), other
  // children write UTF-8. Same rule as External.ReadPowerShellOutput in the launcher: strict UTF-8, otherwise the OEM page.
  // A buffer edge may split one UTF-8 character; only those edge bytes are tolerated.
  public static int OemCodePage;
  [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern uint GetOEMCP();
  public static string Decode(byte[] b, int count, bool cutStart, bool cutEnd) {
   int start=0, end=count;
   if(cutStart) while(start<end && start<3 && (b[start]&0xC0)==0x80) start++;
   if(cutEnd) { int i=end-1, back=0; while(i>=start && back<3 && (b[i]&0xC0)==0x80) {i--;back++;} if(i>=start && b[i]>=0xC0) { int need=b[i]>=0xF0?4:b[i]>=0xE0?3:2; if(end-i<need) end=i; } }
   try { return new UTF8Encoding(false,true).GetString(b,start,end-start); }
   catch(DecoderFallbackException) {
    int page=OemCodePage;
    if(page==0) { try { page=Environment.OSVersion.Platform==PlatformID.Win32NT?(int)GetOEMCP():System.Globalization.CultureInfo.CurrentCulture.TextInfo.OEMCodePage; } catch { page=437; } }
    try { return Encoding.GetEncoding(page).GetString(b,0,count); } catch { return Encoding.UTF8.GetString(b,0,count); }
   }
  }
  public override bool CanRead {get{return false;}} public override bool CanSeek {get{return false;}} public override bool CanWrite {get{return true;}}
  public override long Length {get{return 0;}} public override long Position {get{return 0;}set{throw new NotSupportedException();}}
  public override void Flush() {} public override int Read(byte[] b,int o,int n){throw new NotSupportedException();}
  public override long Seek(long o,SeekOrigin s){throw new NotSupportedException();} public override void SetLength(long v){throw new NotSupportedException();}
 }
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
# Снимок только слушающих TCP-сокетов. Ошибки поиска владельца не подменяют причину bind.
# -ListenersOnly: быстрый снимок для выбора портов; список процессов (CIM) нужен только для имени владельца.
function Get-TransportPortSnapshot([switch]$ListenersOnly) {
    if($env:OS -eq 'Windows_NT'){
        $listeners=@(Get-NetTCPConnection -State Listen -ErrorAction Stop|ForEach-Object {
            [pscustomobject]@{address=[string]$_.LocalAddress;port=[int]$_.LocalPort;pid=[int]$_.OwningProcess}
        })
        if($ListenersOnly){return [pscustomobject]@{listeners=$listeners;processes=@();legacyActions=@()}}
        $processes=@(Get-CimInstance Win32_Process -ErrorAction Stop)
        $legacyActions=@();try{$task=Get-ScheduledTask -TaskPath '\' -TaskName 'RemoteDiskChannel' -ErrorAction Stop;foreach($a in @($task.Actions)){$legacyActions+=@{exe=[string]$a.Execute;arguments=[string]$a.Arguments}}}catch{}
    }else{
        $listeners=@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()|ForEach-Object {
            [pscustomobject]@{address=$_.Address.ToString();port=$_.Port;pid=0}
        });$processes=@()
    }
    [pscustomobject]@{listeners=$listeners;processes=$processes;legacyActions=@($legacyActions)}
}
function Get-TransportPortConflict([string]$Address,[int]$Port,$Snapshot=$null) {
    if(-not $Snapshot){try{$Snapshot=Get-TransportPortSnapshot}catch{$Snapshot=[pscustomobject]@{listeners=@();processes=@()}}}
    $listener=@($Snapshot.listeners|Where-Object {$_.port -eq $Port -and $_.address -in @($Address,'0.0.0.0','::')}|Select-Object -First 1)
    $owner=$null;$ownerId=0
    if($listener.Count){$ownerId=[int]$listener[0].pid;$owner=@($Snapshot.processes|Where-Object {[int]$_.ProcessId -eq $ownerId}|Select-Object -First 1)}
    $exe='';if($owner){$exe=[string]$owner[0].ExecutablePath}
    $legacy=$false
    if($exe -and $env:LOCALAPPDATA){
        $old=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'RemoteDisk/channel/sing-box.exe'))
        $legacy=([IO.Path]::GetFullPath($exe) -ieq $old)
    }
    if(-not $legacy -and $exe -and $owner){
        # Задача могла указывать другой путь. Одного имени exe недостаточно: сверяем действие и аргументы.
        $line=([string]$owner[0].CommandLine).Replace('/','\').Trim()
        foreach($action in @($Snapshot.legacyActions)){
            if(-not $action -or -not $action.exe -or -not $action.arguments){continue}
            $arguments=([string]$action.arguments).Replace('/','\').Trim()
            $sameExe=([IO.Path]::GetFullPath([string]$action.exe) -ieq [IO.Path]::GetFullPath($exe))
            if($sameExe -and $line.EndsWith($arguments,[StringComparison]::OrdinalIgnoreCase)){$legacy=$true;break}
        }
    }
    $endpoint=$Address+':'+$Port
    $message='Порт '+$endpoint+' занят другой программой'
    if($exe){$message+=' '+$exe+' (PID '+$ownerId+')'}elseif($ownerId){$message+=' (PID '+$ownerId+', путь программы недоступен)'}else{$message+='; определить программу не удалось'}
    if($legacy){$message+=' — это старая установка RemoteDisk: закройте программу и запустите Remove-OldInstall.cmd из инструмента очистки, затем откройте RemoteAgents снова'}
    $message+='.'
    [pscustomobject]@{address=$Address;port=$Port;pid=$ownerId;exe=$exe;legacy=$legacy;message=$message;listening=($listener.Count -gt 0)}
}
function Get-TransportBindConflict([string]$Text,$Snapshot=$null) {
    if($Text -notmatch '(?i)Only one usage of each socket address|address already in use|WSAEADDRINUSE'){return}
    if($Text -match '(?i)(?:listen (?:tcp|udp)\S*\s+)?(127\.\d+\.\d+\.\d+|0\.0\.0\.0|\[::1\]|\[::\]):(\d+)'){
        return (Get-TransportPortConflict $Matches[1].Trim('[',']') ([int]$Matches[2]) $Snapshot)
    }
    [pscustomobject]@{address='';port=0;pid=0;exe='';legacy=$false;message='Порт модуля связи занят другой программой. Освободите порт или измените порты в настройках связи.'}
}
# Счётчик относится к одному endpoint и одной фактической ошибке stderr, не ко всем падениям.
function Get-TransportBindRetry($Previous,$Detail) {
    if(-not $Detail -or -not $Detail.portConflict){return $null}
    $key=$Detail.portConflict.address+':'+$Detail.portConflict.port+' '+(Convert-TransportLF ([string]$Detail.stderr)).Trim()
    $failures=1
    if($Previous -and $Previous.key -ceq $key){$failures=[Math]::Min(4,$Previous.failures+1)}
    [pscustomobject]@{key=$key;failures=$failures}
}
function Get-TransportRestartDelay([double]$Base,[int]$BindFailures) {
    if($BindFailures -le 0){return [Math]::Min(30,$Base)}
    [Math]::Min(30,[Math]::Max(5,$Base)*[Math]::Pow(2,[Math]::Min(3,$BindFailures-1)))
}

function New-TransportDiagnostic($Child,[string]$Candidate,[string]$Reason,$Settings=$null) {
    $code=$null;$line=''
    if($Child){
        try{if($Child.Process.HasExited){$code=$Child.Process.ExitCode;[void]$Child.ErrorDrain.Wait(500)}}catch{}
        if($Child.PSObject.Properties['ErrorBuffer']){
            $lines=@((Convert-TransportLF $Child.ErrorBuffer.Snapshot()) -split "`n"|Where-Object {$_.Trim()})
            if($lines.Count){
                $line=$lines[0]
                # sing-box может вывести предупреждение до ошибки запуска: ищем саму bind-строку.
                foreach($entry in $lines){if($entry -match '(?i)bind:.*(?:Only one usage of each socket address|address already in use|WSAEADDRINUSE)'){$line=$entry;break}}
            }
        }
    }
    # Error kind remains explicit even when stderr is empty or has been redacted.
    $portConflict=Get-TransportBindConflict $line
    if($portConflict){$Reason='port-in-use'}
    elseif($line -match '(?i)timed? out|timeout|deadline'){$Reason='timeout'}
    elseif($line -match '(?i)refused'){$Reason='connection-refused'}
    elseif($line -match '(?i)unreachable|no route'){$Reason='network-unreachable'}
    elseif($line -match '(?i)permission denied|authentication failed'){$Reason='authentication-failed'}
    [pscustomobject]@{candidate=$(if($Candidate -match '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,95}$'){$Candidate}else{'invalid-tag'});reason=$Reason;portConflict=$portConflict;exitCode=$code;stderr=(Protect-TransportDiagnostic $line $Settings)}
}
function Format-TransportDiagnostic($Detail) {
    if($Detail.portConflict){return $Detail.portConflict.message}
    'candidate='+$Detail.candidate+' reason='+$Detail.reason+' exit='+$(if($null -eq $Detail.exitCode){'running/unknown'}else{[string]$Detail.exitCode})+' stderr='+$Detail.stderr+$(if($Detail.engineStderr){' sing-box='+$Detail.engineStderr}else{''})
}

function Get-TransportDiagnosticContext($Settings,[string]$Root) {
    $values=@($Settings)
    $apiSecret=Join-Path $Root 'state/transport-secret.json';if(Test-Path $apiSecret){$values+=,(Read-TransportJson $apiSecret)}
    $dir=Join-Path (Get-TransportCacheRoot $Settings $Root) 'secrets/entries'
    if(Test-Path $dir){foreach($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.json')){try{$values+=,(Read-TransportJson $file.FullName)}catch{}}}
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

# Only the already running transport's current proof can authorize a VPN session.
function Get-TransportCacheRoot($Settings,[string]$Root) {
    Get-TransportValue $Settings.Transport 'cacheRoot' $Root
}

function Test-VpnHostAlive([string]$Root) {
    try{
        $owner=Read-TransportJson (Join-Path $Root 'state/vpn-host.json')
        $p=[Diagnostics.Process]::GetProcessById([int]$owner.pid)
        # net48 HasExited requests elevated query rights; these two APIs need only limited query/synchronize.
        try{return (-not $p.WaitForExit(0) -and $p.StartTime.ToUniversalTime().Ticks -eq [long]$owner.startedTicks)}finally{$p.Dispose()}
    }catch{return $false}
}
