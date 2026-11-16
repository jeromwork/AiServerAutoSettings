#requires -Version 5.1
$ErrorActionPreference='Stop'
# .NET Framework writes Console.InputEncoding's BOM into every redirected stdin; on a UTF-8 console that corrupts the first line sent to ssh.
try{[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false);if([Console]::InputEncoding.GetPreamble().Length){[Console]::InputEncoding=New-Object Text.UTF8Encoding($false)}}catch{}
# Durations are milliseconds; absent overrides retain the installed defaults.
function Get-DiskMilliseconds([string]$Name,[int]$Default) {
    $value=[Environment]::GetEnvironmentVariable('REMOTE_DISK_'+$Name+'_MS')
    if([string]::IsNullOrEmpty($value)){return $Default}
    $parsed=0
    if(-not [int]::TryParse($value,[ref]$parsed) -or $parsed -le 0){throw ('Недопустимый интервал Диска: '+$Name)}
    return $parsed
}
function Get-DiskAttempts([string]$Name,[int]$Default) {
    $value=[Environment]::GetEnvironmentVariable('REMOTE_DISK_'+$Name+'_ATTEMPTS')
    if([string]::IsNullOrEmpty($value)){return $Default}
    $parsed=0
    if(-not [int]::TryParse($value,[ref]$parsed) -or $parsed -le 0){throw ('Недопустимое число попыток Диска: '+$Name)}
    return $parsed
}
function Get-DiskSeconds([string]$Name,[double]$Default) { (Get-DiskMilliseconds $Name ([int]($Default*1000)))/1000.0 }
function Get-DiskNowMilliseconds { [Diagnostics.Stopwatch]::GetTimestamp()*1000.0/[Diagnostics.Stopwatch]::Frequency }
function Write-DiskUtf8($File,[string]$Text) {[IO.File]::WriteAllText($File,$Text.Replace("`r",''),(New-Object Text.UTF8Encoding($false)))}
function Write-DiskLog($Step,$Failure=$null) {
    try {
        [void][IO.Directory]::CreateDirectory($script:DiskHome);$file=Join-Path $script:DiskHome 'install.log';$message='Успех'
        if($Failure){$message=$Failure.Exception.Message+' | '+$Failure.InvocationInfo.PositionMessage}
        $text=('{0:o} [{1}] {2}' -f (Get-Date),$Step,$message)+"`n";$encoding=New-Object Text.UTF8Encoding($false)
        if((Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).Length+$encoding.GetByteCount($text) -gt 256KB){Write-DiskUtf8 $file ''}
        [IO.File]::AppendAllText($file,$text,$encoding)
    }catch{}
}
# A line for the wizard journal while the step is still running (the wizard passes its file to children).
function Write-DiskProgress([string]$Text) {
    if(-not $env:REMOTEAGENTS_WIZARD_PROGRESS){Write-Output $Text;return}
    try{[IO.File]::AppendAllText($env:REMOTEAGENTS_WIZARD_PROGRESS,((@{text=$Text}|ConvertTo-Json -Compress)+"`n"),(New-Object Text.UTF8Encoding($false)))}catch{}
}
function Quote-Disk([string]$Value) {'"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'}
function Protect-DiskFailureText([string]$Text) {
    if(Get-Command Protect-TransportText -ErrorAction SilentlyContinue){return Protect-TransportText $Text}
    $Text -replace '[A-Za-z0-9+/_=-]{20,}','<secret>' -replace '://[^/@\s]+@','://<auth>@'
}
# A server refusal is a useful cause. Native tools' arbitrary stderr still stays out of the UI.
function Get-DiskServerFailure([string]$Text) {
    foreach($line in ($Text.Replace("`r",'') -split "`n")){
        $clean=($line -replace '\x1b\[[0-9;]*[a-zA-Z]','').Trim()
        if(-not $clean -or $clean -match '^(Warning: Permanently added|Connection to .* closed\.?$)'){continue}
        return Protect-DiskFailureText $clean
    }
    return ''
}
function Invoke-DiskProcess($Exe,$Arguments,[string]$InputText='',[string]$OutputFile='',[double]$TimeoutSeconds=(Get-DiskSeconds PROCESS_TIMEOUT 45)) {
    $si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=$Exe;$si.Arguments=($Arguments|ForEach-Object {Quote-Disk ([string]$_)}) -join ' '
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true;$si.StandardOutputEncoding=New-Object Text.UTF8Encoding($false);$si.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
    $p=New-Object Diagnostics.Process;$p.StartInfo=$si;$file=$null;$err=$null
    # The wizard journal (Write-WizardTrace) gets every SSH run with its stderr; elsewhere nothing is traced.
    $trace=if([IO.Path]::GetFileNameWithoutExtension([string]$Exe) -match '\A(ssh|scp|sftp)\z'){Get-Command Write-WizardTrace -ErrorAction SilentlyContinue};$watch=[Diagnostics.Stopwatch]::StartNew()
    try {[void]$p.Start();$err=$p.StandardError.ReadToEndAsync()
        if($OutputFile){$file=[IO.File]::Create($OutputFile);$out=$p.StandardOutput.BaseStream.CopyToAsync($file)}else{$out=$p.StandardOutput.ReadToEndAsync()}
        $bytes=[Text.Encoding]::UTF8.GetBytes($InputText.Replace("`r",''));$write=$p.StandardInput.BaseStream.WriteAsync($bytes,0,$bytes.Length)
        # ssh reads stdin only after the session is up; via a hop that alone can exceed 15 s.
        $inputFailure=$null
        try{if(-not $write.Wait([Math]::Max((Get-DiskMilliseconds PROCESS_INPUT_MIN 15000),$TimeoutSeconds*1000))){throw 'Таймаут ввода'}}catch{
            # A server can refuse before reading stdin. Its stderr/exit code is more useful than Broken pipe.
            if(-not $p.WaitForExit((Get-DiskMilliseconds PROCESS_EXIT 1000))){throw};$inputFailure=$_
        }
        try{$p.StandardInput.Close()}catch{if(-not $p.HasExited){throw};if(-not $inputFailure){$inputFailure=$_}}
        if(-not $p.WaitForExit($TimeoutSeconds*1000)){$p.Kill();throw 'Таймаут команды'};$out.GetAwaiter().GetResult() | Out-Null
        if($p.ExitCode -ne 0){$reason='Внешняя команда не выполнена';if($p.ExitCode -eq 255 -and [IO.Path]::GetFileNameWithoutExtension($Exe) -ieq 'ssh'){$reason=if($err.Result -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed'){"Ключ хоста не совпал с приглашением или known_hosts. Подключение остановлено; попросите администратора проверить ключ сервера"}elseif($err.Result -match 'Permission denied'){'Сервер отклонил вход'}elseif($err.Result -match 'Remote protocol version' -and $err.Result -match 'timed out|Connection reset'){'Сервер ответил, но сеть глушит SSH после рукопожатия — нужен обход (канал через промежуточный сервер)'}elseif($err.Result -match 'banner exchange|kex_exchange_identification|Connection closed|Connection reset|timed out'){'Нет SSH-баннера от сервера'}else{'Нет связи с сервером'};if($err.Result -match 'proxy-connect: ([^\r\n]+)'){$reason+=': '+$Matches[1]}}elseif([IO.Path]::GetFileNameWithoutExtension($Exe) -ieq 'ssh'){$detail=Get-DiskServerFailure $err.Result;if($detail){$reason=$detail}};throw ($reason+' (код выхода '+$p.ExitCode+')')}
        if($inputFailure){throw $inputFailure}
        if(-not $OutputFile){$out.Result.Replace("`r",'').TrimStart([char]0xFEFF).Trim()}
    }finally{if($file){$file.Dispose()};if($p.Id -and -not $p.HasExited){$p.Kill()}
        if($trace){try{$code=if($p.HasExited){[string]$p.ExitCode}else{'прервано'};$text=if($err -and $err.Wait((Get-DiskMilliseconds PROCESS_STDERR 2000))){$err.Result}else{''};Write-WizardTrace $Exe $si.Arguments $code $watch.ElapsedMilliseconds $text}catch{}}
        $p.Dispose()}
}
function Read-DiskProfile([string]$Profile) {
    if(-not $Profile){$saved=Join-Path $script:DiskHome 'profile.txt';if(Test-Path -LiteralPath $saved){$Profile=[IO.File]::ReadAllText($saved)}}
    # Before RemoteDisk exists (Happier, first run) the launcher's chosen profile wins: an older setup may leave a second one.
    if(-not $Profile){$launcher=Join-Path $env:LOCALAPPDATA 'RemoteAgents/config.json';if(Test-Path -LiteralPath $launcher){try{$c=[IO.File]::ReadAllText($launcher)|ConvertFrom-Json;$chosen=[string]$c.wizard.pendingProfile;if(-not $chosen){$chosen=[string]$c.transport.profilePath};if($chosen -and (Test-Path -LiteralPath $chosen)){$Profile=$chosen}}catch{}}}
    if(-not $Profile){$files=@(Get-ChildItem -Path "$env:LOCALAPPDATA/RemoteAgents/ssh-profiles/*/project-connections/*/ssh-transport.json" -File);if($files.Count -ne 1){throw 'Укажите -Profile: нужен один SSH-профиль'};$Profile=$files[0].FullName}
    $script:ProfilePath=[IO.Path]::GetFullPath($Profile);$script:Connection=[IO.File]::ReadAllText($script:ProfilePath)|ConvertFrom-Json
    foreach($f in @('sshExecutable','arguments','serverAddress','login','keyPath','knownHostsPath','configPath')){if(-not $script:Connection.$f){throw 'Неполный SSH-профиль'}}
    if($script:Connection.login.Trim() -ieq 'root'){throw 'SSH-профиль должен входить как рабочий пользователь, не root'}
}
function Invoke-DiskSsh($Command,[switch]$Direct,[string]$InputText='',[string]$OutputFile='',[double]$TimeoutSeconds=(Get-DiskSeconds PROCESS_TIMEOUT 45)) {
    $c=$script:Connection;$args=@('-o','BatchMode=yes','-o',('ConnectTimeout='+[Math]::Max(1,[Math]::Ceiling((Get-DiskSeconds SSH_CONNECT 8)))),'-o','StrictHostKeyChecking=yes')
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'transport/Transport.Common.ps1')
    $root=Join-Path $env:LOCALAPPDATA 'RemoteAgents';$launcher=Join-Path $root 'config.json'
    $localPort=[int](Get-TransportEffectivePort $root 'sshPort')
    if($Direct){
        $root=Split-Path $launcher -Parent
        # A manually selected profile must never inherit another server's personal route.
        if(Test-Path -LiteralPath $launcher){
            $config=Read-TransportJson $launcher
            $routeProfile=[string]$config.transport.profilePath;if($config.wizard.pendingProfile){$routeProfile=[string]$config.wizard.pendingProfile}
            if($routeProfile -and $script:ProfilePath -eq [IO.Path]::GetFullPath($routeProfile)){
                if($script:WizardRoute){$args+=@($script:WizardRoute.options)}else{$args+=@(Get-TransportSavedRouteOptions $root $c)}
            }
        }
        $args+=@($c.arguments)
    }else{$args+=@('-F','NUL','-p',[string]$localPort,'-i',$c.keyPath,'-o',('HostKeyAlias='+$c.serverAddress),'-o',('UserKnownHostsFile="'+$c.knownHostsPath.Replace('\','/')+'"'),'-o','IdentitiesOnly=yes',($c.login+'@127.0.0.1'))}
    Invoke-DiskProcess $c.sshExecutable ($args+@($Command)) $InputText $OutputFile -TimeoutSeconds $TimeoutSeconds
}
# Only idempotent installation commands may use this bounded retry.
function Invoke-DiskRetry([scriptblock]$Action,[string]$Step) {
    for($attempt=1;$attempt -le 3;$attempt++){
        try{& $Action;return}catch{
            Write-DiskLog ($Step+': попытка '+$attempt+' из 3') $_
            if($attempt -eq 3){throw}
            Start-Sleep -Milliseconds ((Get-DiskMilliseconds INSTALL_RETRY 1000)*$attempt)
        }
    }
}
function Invoke-DiskServer($Action,$Data=$null,[switch]$Direct) {
    $cmd='bash "$HOME/.local/share/remote-disk/server-disk.sh" '+$Action
    if($Data){$cmd+=' '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Data|ConvertTo-Json -Depth 20 -Compress)))}
    $text=Invoke-DiskSsh $cmd -Direct:$Direct
    if($text){$value=$text|ConvertFrom-Json;foreach($item in $value){if($null -ne $item){$item}}}
}
function Invoke-DiskApi($Route,$Method='GET',$Body=$null) {
    if(-not $script:DiskHome){$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'}
    if(-not $script:Gui -or -not $script:ApiKey){Read-DiskState}
    $endpoint=$null
    if(-not [Uri]::TryCreate(('http://'+$script:Gui),[UriKind]::Absolute,[ref]$endpoint) -or $endpoint.Host -cne '127.0.0.1' -or $endpoint.UserInfo -or $endpoint.Query -or $endpoint.Fragment -or $endpoint.AbsolutePath -cne '/'){throw 'REST Syncthing должен слушать только 127.0.0.1'}
    $args=@{Uri=('http://'+$script:Gui+'/rest/'+$Route);Method=$Method;Headers=@{'X-API-Key'=$script:ApiKey};TimeoutSec=[int][Math]::Max(1,[Math]::Ceiling((Get-DiskSeconds REST_TIMEOUT 5)));UseBasicParsing=$true;MaximumRedirection=0}
    if($null -ne $Body){$args.Body=[Text.Encoding]::UTF8.GetBytes(($Body|ConvertTo-Json -Depth 30 -Compress));$args.ContentType='application/json'}
    # PS 5.1 Invoke-RestMethod decodes a charset-less JSON answer as Latin-1; Syncthing text (labels, .stignore comments) is UTF-8.
    try {$response=Invoke-WebRequest @args;$text=[Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())}catch{throw ('REST Syncthing недоступен ('+$script:Gui+'); проверьте запущенный RemoteDisk и state/config.xml')}
    if($text.Trim().Length -eq 0){return}
    try{$value=$text|ConvertFrom-Json}catch{return $text}
    foreach($item in $value){if($null -ne $item -and -not ($item -is [string] -and $item.Length -eq 0)){$item}}
}
function Read-DiskState {
    $script:Engine=New-Object Xml.XmlDocument;$script:Engine.PreserveWhitespace=$true;$script:Engine.LoadXml([IO.File]::ReadAllText((Join-Path $script:DiskHome 'state/config.xml')))
    $script:Gui=[string]$script:Engine.configuration.gui.address;$script:ApiKey=[string]$script:Engine.configuration.gui.apikey
}
function Save-DiskState($Options) {
    $node=$script:Engine.configuration.options
    foreach($name in $Options.Keys){$xmlName=$name;if($name -eq 'listenAddresses'){$xmlName='listenAddress'};foreach($old in @($node.SelectNodes($xmlName))){[void]$node.RemoveChild($old)};$child=$script:Engine.CreateElement($xmlName);$child.InnerText=([string]$Options[$name]).ToLowerInvariant();[void]$node.AppendChild($child)}
    $script:Engine.Save((Join-Path $script:DiskHome 'state/config.xml'))
}
function New-DiskIni($Tray,$State,$Gui,$ApiKey) {
    @('[General]','v=2.1.9','[tray]','connections\size=1','connections\1\label=RemoteDisk',('connections\1\syncthingUrl=http://'+$Gui),('connections\1\apiKey='+$ApiKey),'connections\1\autoConnect=true',('connections\1\reconnectInterval='+[int][Math]::Max(1,[Math]::Ceiling((Get-DiskSeconds TRAY_RECONNECT 30)))),'notifyOnDisconnect=false','notifyOnErrors=true','showSyncthingNotifications=true','[startup]','syncthingAutostart=true','useLibSyncthing=false',('syncthingPath='+$Tray.Replace('\','/')),('syncthingArgs="syncthing serve --home \"'+$State.Replace('\','/')+'\" --no-browser --no-restart"'),'considerLauncherForReconnect=true','showLauncherButton=false','') -join "`n"
}
# Upload only our template; each folder keeps its own .stignore rules.
function Get-DiskIgnoreUpload([string]$Directory=$PSScriptRoot) {
    $rules=[IO.File]::ReadAllText((Join-Path $Directory 'stignore.txt')).Replace("`r",'')
    $source=@'
import os,base64,tempfile
from pathlib import Path
p=Path.home()/'.local/share/remote-disk'
if any(x.is_symlink() for x in (p,*p.parents)):raise ValueError('symlink')
p.mkdir(parents=True,exist_ok=True)
template=p/'stignore.txt'
if template.is_symlink():raise ValueError('symlink')
rules=base64.b64decode('RULES_BASE64')
fd,tmp=tempfile.mkstemp(dir=p)
try:
 with os.fdopen(fd,'wb') as out:out.write(rules);out.flush();os.fsync(out.fileno())
 os.replace(tmp,template)
finally:
 if os.path.exists(tmp):os.unlink(tmp)
'@
    $source=$source.Replace('RULES_BASE64',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rules)))
    'python3 -c ''import base64;exec(base64.b64decode("'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source.Replace("`r",'')))+'"))''' + "`n"
}
# Base folder like Yandex Disk: %USERPROFILE%\Disk unless the owner chose another one.
function Get-DiskBase {
    $saved=Join-Path $script:DiskHome 'base.txt'
    if(Test-Path -LiteralPath $saved){return [IO.File]::ReadAllText($saved).Trim()}
    Join-Path $env:USERPROFILE 'Disk'
}

# Only installation and the legacy metadata migration need filesystem checks.
function Assert-DiskPlainPath([string]$Path) {
    for($part=[IO.Path]::GetFullPath($Path);$part;$part=[IO.Path]::GetDirectoryName($part)){
        if((Test-Path -LiteralPath $part) -and ([IO.File]::GetAttributes($part) -band [IO.FileAttributes]::ReparsePoint)){throw ('Ссылки в пути запрещены: '+$Path)}
    }
}
function Set-DiskBase([string]$Path) {
    $new=Get-DiskNavPaneBase $Path;Assert-DiskPlainPath $new
    [void][IO.Directory]::CreateDirectory($new);Write-DiskUtf8 (Join-Path $script:DiskHome 'base.txt') $new
    if((Test-DiskNavPane $new).installed){[void](Ensure-DiskNavPane $new)}
}
. (Join-Path $PSScriptRoot 'Disk.NavPane.ps1')
function Get-DiskLegacyMetadata([string]$File) {
    if(-not [IO.File]::Exists($File) -or ([IO.File]::GetAttributes($File) -band [IO.FileAttributes]::ReparsePoint)){return $null}
    $values=@{};$section=''
    foreach($line in ([IO.File]::ReadAllText($File).Replace("`r",'') -split "`n")){
        if($line -match '^\s*\[([^]]+)\]\s*$'){$section=$Matches[1];continue}
        if($section -ieq 'RemoteAgents' -and $line -match '^\s*([^=]+?)\s*=\s*(.*?)\s*$'){$values[$Matches[1]]=$Matches[2]}
    }
    if($values.Owner -cne 'RemoteAgents.Disk.v1' -or $values.OriginalReadOnly -cnotin @('0','1')){return $null}
    $values
}
function Update-DiskLegacyItem([string]$Path) {
    if(-not (Test-DiskNavPaneWindows)){return}
    if(-not ('RemoteDisk.LegacyCleanup' -as [type])){
        Add-Type -Namespace RemoteDisk -Name LegacyCleanup -MemberDefinition '[DllImport("shell32.dll", CharSet=CharSet.Unicode)] public static extern void SHChangeNotify(int eventId, uint flags, string item1, IntPtr item2);'
    }
    [RemoteDisk.LegacyCleanup]::SHChangeNotify(0x2000,0x5,$Path,[IntPtr]::Zero) # SHCNE_UPDATEITEM, SHCNF_PATHW
}
function Remove-DiskLegacyFolderMetadata([string]$Path) {
    Assert-DiskPlainPath $Path
    $file=Join-Path $Path 'desktop.ini';$owned=Get-DiskLegacyMetadata $file
    if(-not $owned){return}
    $attributes=[IO.File]::GetAttributes($Path);$removed=$false
    try{
        [IO.File]::SetAttributes($Path,($attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
        [IO.File]::SetAttributes($file,[IO.FileAttributes]::Normal)
        [IO.File]::Delete($file);$removed=$true
    }finally{
        if($removed){
            if($owned.OriginalReadOnly -ceq '0'){$attributes=$attributes -band (-bnot [IO.FileAttributes]::ReadOnly)}
            elseif($owned.OriginalReadOnly -ceq '1'){$attributes=$attributes -bor [IO.FileAttributes]::ReadOnly}
        }
        [IO.File]::SetAttributes($Path,$attributes)
    }
    Update-DiskLegacyItem $Path
}
function Remove-DiskLegacy([string]$Base='') {
    if(-not $script:DiskHome){$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'}
    $owner='RemoteAgents.Disk.v1'
    foreach($action in @('download','sync','keep-server','add','progress')){
        $key='Software\Classes\Directory\shell\RemoteAgents.Disk.'+$action
        if((Get-DiskNavPaneValue $key 'RemoteAgentsOwner') -ceq $owner){Remove-DiskNavPaneKey $key}
    }
    if(-not $Base){$Base=Get-DiskBase}
    if([IO.Directory]::Exists($Base)){
        Assert-DiskPlainPath $Base
        foreach($item in (New-Object IO.DirectoryInfo($Base)).EnumerateDirectories()){
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
            $ini=Get-DiskLegacyMetadata (Join-Path $item.FullName 'desktop.ini')
            if(-not $ini){continue}
            # Directory.Delete(false) can remove only an empty product-created placeholder.
            $placeholder=$ini.Placeholder -ceq '1' -and $ini.CreatedDirectory -ceq '1'
            Remove-DiskLegacyFolderMetadata $item.FullName
            if($placeholder -and -not @($item.EnumerateFileSystemInfos()).Count){[IO.Directory]::Delete($item.FullName,$false)}
        }
    }
    # Old explicit external receipts identify metadata targets; never follow their junctions.
    $receipt=Join-Path $script:DiskHome 'external.json'
    if([IO.File]::Exists($receipt)){
        Assert-DiskPlainPath $receipt
        $saved=[IO.File]::ReadAllText($receipt)|ConvertFrom-Json
        if($saved.schema -ne 1){throw 'Неизвестный формат старых внешних папок Disk'}
        foreach($external in $saved.items){
            if($external.path -and [IO.Path]::IsPathRooted([string]$external.path) -and [IO.Directory]::Exists([string]$external.path)){
                Remove-DiskLegacyFolderMetadata ([string]$external.path)
            }
        }
    }
    $icons=Join-Path $env:LOCALAPPDATA 'RemoteAgents/icons'
    if([IO.Directory]::Exists($icons)){
        Assert-DiskPlainPath $icons
        foreach($state in @('Local','ServerOnly','Pending','Syncing','Synced','Paused','Error','Offline','Unavailable')){
            $file=Join-Path $icons ($owner+'.'+$state+'.ico')
            if([IO.File]::Exists($file) -and -not ([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::ReparsePoint)){[IO.File]::Delete($file)}
        }
    }
    Update-DiskNavPaneShell
}


# Match ConfigBundle.NormalizeWindowsPath even when these lexical rules are tested on Linux.
function ConvertTo-DiskAcceptWindowsPath([string]$Path) {
    $path=$Path.Replace('/','\')
    $drive=$path -match '\A[a-zA-Z]:\\';$unc=$path -match '\A\\\\[^\\]+\\[^\\]+(?:\\|\z)'
    if((-not $drive -and -not $unc) -or $path.StartsWith('\\?\') -or $path.StartsWith('\\.\')){throw 'AcceptFile: нужен абсолютный путь Windows без префикса устройства'}
    $offset=0;if($drive){$offset=2}
    if($path.Substring($offset) -match '[<>:"|?*\x00-\x1f]'){throw 'AcceptFile: недопустимый путь папки'}
    $offset=2;if($drive){$offset=3}
    $tail=$path.Substring($offset).TrimEnd('\');$parts=@()
    if(-not ($drive -and $tail.Length -eq 0)){$parts=@($tail -split '\\')}
    if(@($parts|Where-Object {$_ -eq '' -or $_ -in @('.','..') -or $_ -match '[ .]\z|\A(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|\z)'}).Count){throw 'AcceptFile: недопустимый путь папки'}
    if($drive -and $path.Length -eq 3){return $path}
    return $path.TrimEnd('\')
}
function Read-DiskAcceptFile([string]$File) {
    if(-not $File){return}
    try{$data=[IO.File]::ReadAllText($File)|ConvertFrom-Json}catch{throw 'AcceptFile: не удалось прочитать JSON со списком папок'}
    if($null -eq $data -or $null -eq $data.PSObject.Properties['folders'] -or $data.folders -isnot [Array]){throw 'AcceptFile: нужен JSON с массивом folders'}
    $ids=@{}
    foreach($folder in $data.folders){
        $id=[string]$folder.id
        if($folder.id -isnot [string] -or $id.Length -gt 128 -or $id -notmatch '\A[\p{L}\p{N}_][\p{L}\p{N}_. -]*\z' -or $id.Contains('..') -or $id -match '[ .]$|^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)'){throw ('AcceptFile: недопустимый ID папки: '+$id)}
        if($ids.ContainsKey($id)){throw ('AcceptFile: повторный ID папки: '+$id)};$ids[$id]=$true
        if($null -ne $folder.path -and $folder.path -isnot [string]){throw 'AcceptFile: путь папки должен быть строкой'}
        $path=[string]$folder.path
        if($path){
            $windows=$path.Replace('/','\')
            if($windows.StartsWith('\\?\') -or $windows.StartsWith('\\.\')){throw 'AcceptFile: пути устройств запрещены'}
            if($env:OS -eq 'Windows_NT'){$path=ConvertTo-DiskAcceptWindowsPath $path}
            if(-not [IO.Path]::IsPathRooted($path)){throw 'AcceptFile: нужен абсолютный путь к папке'}
        }else{$path=Join-Path (Get-DiskBase) $id}
        $path=[IO.Path]::GetFullPath($path);Assert-DiskAcceptBase $path
        [pscustomobject]@{id=$id;path=$path}
    }
}
function Assert-DiskAcceptBase([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $base=[IO.Path]::GetFullPath((Get-DiskBase)).TrimEnd('\','/')
    if(-not $full -or ([IO.Path]::GetDirectoryName($full)).TrimEnd('\','/') -ine $base){throw ('AcceptFile: только прямые папки внутри базы Disk; внешние и вложенные пути запрещены: '+$Path)}
}
function Test-DiskFolderAccepted($Folder,$Existing,[string]$Peer) {
    $full=[IO.Path]::GetFullPath([string]$Folder.path).TrimEnd('\','/')
    foreach($other in $Existing){
        if($other.id -ceq $Folder.id -or ($other.label -ceq $Folder.id -and $Peer -cin @($other.devices|ForEach-Object {$_.deviceID}))){return $true}
        if($other.path -and [IO.Path]::GetFullPath([string]$other.path).TrimEnd('\','/') -ieq $full){return $true}
    }
    return $false
}
function Assert-DiskAcceptPath([string]$Path,$Existing) {
    Assert-DiskAcceptBase $Path;Assert-DiskPlainPath $Path
    if([IO.File]::Exists($Path)){throw ('Путь папки занят файлом: '+$Path)}
    foreach($name in @('.stignore','.stignore-remoteagents')){
        $file=Join-Path $Path $name;Assert-DiskPlainPath $file
        if([IO.Directory]::Exists($file)){throw ('Файл правил занят каталогом: '+$file)}
    }
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    foreach($folder in $Existing){
        $other=[IO.Path]::GetFullPath([string]$folder.path).TrimEnd('\','/')
        if($full -ieq $other){continue}
        if($full.StartsWith($other+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $other.StartsWith($full+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw ('Путь пересекается с папкой Syncthing: '+$Path)}
    }
}
function Get-DiskPendingFolderId($Pending,[string]$Name,[string]$Peer) {
    # REST returns an object keyed by the real Syncthing ID, not by the folder name.
    $keys=if($Pending -is [Collections.IDictionary]){@($Pending.Keys)}else{@($Pending.PSObject.Properties|ForEach-Object {$_.Name})}
    foreach($key in $keys){
        $offer=$Pending.$key.offeredBy.$Peer
        if($null -ne $offer -and ($key -ceq $Name -or $offer.label -ceq $Name)){return [string]$key}
    }
}
function Set-DiskFolderIgnores([string]$Path) {
    Assert-DiskPlainPath $Path
    $managed=Join-Path $Path '.stignore-remoteagents';$file=Join-Path $Path '.stignore'
    Assert-DiskPlainPath $managed;Assert-DiskPlainPath $file
    $rules=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'stignore.txt')).Replace("`r",'')
    [void][IO.Directory]::CreateDirectory($Path)
    # Mandatory policy is first even before a user's negations or includes.
    if(-not [IO.File]::Exists($managed) -or [IO.File]::ReadAllText($managed) -cne $rules){Write-DiskUtf8 $managed $rules}
    $old='';$bom=$false;if([IO.File]::Exists($file)){$old=[IO.File]::ReadAllText($file);$raw=[IO.File]::ReadAllBytes($file);$bom=$raw.Length -ge 3 -and $raw[0] -eq 239 -and $raw[1] -eq 187 -and $raw[2] -eq 191}
    $newline="`n";if($old.Contains("`r`n")){$newline="`r`n"}
    $include='#include .stignore-remoteagents'
    $user=([regex]::Split($old,'(?<=\n)')|Where-Object {$_.Trim() -cne $include}) -join ''
    $next=$include+$newline+$user
    if($old -cne $next){[IO.File]::WriteAllText($file,$next,(New-Object Text.UTF8Encoding($bom)))}
}

function Set-DiskAcceptJournal([string]$Peer,$Folder,[string]$Id,$Config,[switch]$Complete) {
    $file=Join-Path $script:DiskHome 'disk-operations.json';$operations=@{}
    if([IO.File]::Exists($file)){
        $old=[IO.File]::ReadAllText($file)|ConvertFrom-Json
        if($null -eq $old.operations -or $old.operations -is [Array] -or $old.operations -is [string]){throw 'Повреждён журнал операций Диска'}
        foreach($p in $old.operations.PSObject.Properties){$operations[$p.Name]=$p.Value}
        if($old.peer -cne $Peer -and $operations.Count){throw 'Есть незавершённые операции прежнего сервера Диска'}
    }
    if($Complete){$operations.Remove([string]$Folder.path)}else{
        $operations[[string]$Folder.path]=@{kind='accept';phase='prepared';id=$Id;path=[string]$Folder.path;name=[string]$Folder.id;config=$Config}
    }
    [void][IO.Directory]::CreateDirectory($script:DiskHome)
    $temp=$file+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes((@{peer=$Peer;operations=$operations}|ConvertTo-Json -Depth 40 -Compress))
        $stream=New-Object IO.FileStream($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        if([IO.File]::Exists($file)){[IO.File]::Replace($temp,$file,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temp,$file)}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Enter-DiskOperationLock {
    $file=[IO.Path]::GetFullPath((Join-Path $script:DiskHome 'disk-operations.json')).ToUpperInvariant()
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$key=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($file)))).Replace('-','')}finally{$sha.Dispose()}
    $mutex=New-Object Threading.Mutex($false,('RemoteDiskOperations-'+$key))
    try{try{if(-not $mutex.WaitOne((Get-DiskMilliseconds OPERATION_LOCK 35000))){throw 'Диск занят другой операцией'}}catch [Threading.AbandonedMutexException]{};return $mutex}catch{$mutex.Dispose();throw}
}
function Test-DiskRetiredId([string]$Peer,[string]$Id) {
    $file=Join-Path $script:DiskHome ('explorer-retired-'+$Peer+'.json')
    if(-not [IO.File]::Exists($file)){return $false}
    $state=[IO.File]::ReadAllText($file)|ConvertFrom-Json
    if($state.peer -cne $Peer -or $null -eq $state.removed -or $state.removed -is [Array]){throw 'Повреждена память снятых папок Диска'}
    return $Id -cin @($state.removed.PSObject.Properties|ForEach-Object {$_.Name})
}
function Accept-DiskFolders($Folders,[string]$Peer,[string]$LocalId) {
    $operationLock=Enter-DiskOperationLock
    try {
    $journal=Join-Path $script:DiskHome 'disk-operations.json'
    if([IO.File]::Exists($journal)){
        $state=[IO.File]::ReadAllText($journal)|ConvertFrom-Json
        if($null -eq $state.operations -or $state.operations -is [Array] -or $state.operations -is [string]){throw 'Повреждён журнал операций Диска'}
        if(@($state.operations.PSObject.Properties).Count -gt 0 -and $state.peer -cne $Peer){throw 'Есть незавершённые операции прежнего сервера Диска'}
        if(@($state.operations.PSObject.Properties|Where-Object {$_.Value.kind -ceq 'keep'}).Count){throw 'Есть незавершённая операция Диска; запустите программу для восстановления'}
    }
    $existing=@(Invoke-DiskApi 'config/folders')
    $wanted=@($Folders|Where-Object {-not (Test-DiskFolderAccepted $_ $existing $Peer)})
    if(-not $wanted.Count){return}
    # Validate the entire batch before any write.
    $paths=@($existing)
    foreach($folder in $wanted){Assert-DiskAcceptPath $folder.path $paths;$paths+=@($folder)}
    $start=Get-DiskNowMilliseconds;$budget=Get-DiskMilliseconds OFFER_TIMEOUT 30000;$offers=@{}
    while($offers.Count -lt $wanted.Count -and ((Get-DiskNowMilliseconds)-$start) -lt $budget){
        $pending=Invoke-DiskApi 'cluster/pending/folders'
        foreach($folder in $wanted){$id=Get-DiskPendingFolderId $pending $folder.id $Peer;if($id){$offers[$folder.id]=$id}}
        if($offers.Count -lt $wanted.Count -and ((Get-DiskNowMilliseconds)-$start) -lt $budget){Start-Sleep -Milliseconds (Get-DiskMilliseconds OFFER_POLL 500)}
    }
    foreach($folder in $wanted){
        # A person may accept an offer in Tray while we wait. Preserve that registration as well.
        $existing=@(Invoke-DiskApi 'config/folders')
        if(Test-DiskFolderAccepted $folder $existing $Peer){continue}
        $id=$offers[$folder.id]
        if($id -and @($existing|Where-Object {$_.id -ceq $id}).Count){continue}
        Assert-DiskAcceptPath $folder.path $existing
        if($id -and (Test-DiskRetiredId $Peer $id)){Write-DiskProgress ('Удалена на сервере: '+$folder.id+'. Старая регистрация больше не принимается');continue}
        if(-not $id){
            $message='Ожидает сервер: папка '+$folder.id+' не предложена за '+($budget/1000)+' с; повторите приём позже'
            Write-DiskProgress $message;Write-DiskLog $message
            continue
        }
        if([IO.Directory]::Exists($folder.path)){
            $entries=@(Get-ChildItem -LiteralPath $folder.path -Force)
            $ini=Join-Path $folder.path 'desktop.ini'
            $placeholder=$entries.Count -eq 1 -and $entries[0].Name -ceq 'desktop.ini' -and [IO.File]::ReadAllText($ini).Contains('Owner=RemoteAgents.Disk.v2') -and [IO.File]::ReadAllText($ini).Contains('Placeholder=1')
            if($entries.Count -gt 0 -and -not $placeholder){Write-DiskProgress ('Локальная копия '+$folder.id+': выберите «Объединить с сервером» в Проводнике');continue}
        }
        $config=@{id=$id;label=$folder.id;path=$folder.path;type='sendreceive';fsWatcherDelayS=(Get-DiskSeconds WATCHER_DELAY 2);maxConflicts=-1;versioning=@{type='staggered';params=@{maxAge='2592000';cleanInterval='3600'}};devices=@(@{deviceID=$LocalId},@{deviceID=$Peer})}
        Set-DiskAcceptJournal $Peer $folder $id $config
        Set-DiskFolderIgnores $folder.path
        [void](Invoke-DiskApi 'config/folders' POST $config)
        Set-DiskAcceptJournal $Peer $folder $id $config -Complete
    }
    }finally{$operationLock.ReleaseMutex();$operationLock.Dispose()}
}
# REST patches keep paths, versions, ignores and all unrelated user settings intact.
function Test-DiskFolderIgnoresCurrent([string]$Path) {
    $managed=Join-Path $Path '.stignore-remoteagents';$file=Join-Path $Path '.stignore'
    foreach($item in @($managed,$file)){
        Assert-DiskPlainPath $item
        if([IO.Directory]::Exists($item)){throw 'Путь обязательных исключений занят каталогом'}
        if(-not [IO.File]::Exists($item)){return $false}
    }
    $rules=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'stignore.txt')).Replace("`r",'')
    $text=[IO.File]::ReadAllText($file)
    $include='#include .stignore-remoteagents';$lines=@($text.Replace("`r",'') -split "`n")
    return [IO.File]::ReadAllText($managed) -ceq $rules -and $lines[0] -ceq $include -and @($lines|Where-Object {$_.Trim() -ceq $include}).Count -eq 1
}
function Set-DiskWatcherDelay {
    $operationLock=Enter-DiskOperationLock
    try {
    $defaults=Invoke-DiskApi 'config/defaults/folder'
    if($defaults.fsWatcherDelayS -ne (Get-DiskSeconds WATCHER_DELAY 2)){[void](Invoke-DiskApi 'config/defaults/folder' PATCH @{fsWatcherDelayS=(Get-DiskSeconds WATCHER_DELAY 2)})}
    $peerFile=Join-Path $script:DiskHome 'server.txt'
    $peer='';if([IO.File]::Exists($peerFile)){$peer=[IO.File]::ReadAllText($peerFile).TrimStart([char]0xFEFF).Trim()}
    foreach($folder in @(Invoke-DiskApi 'config/folders')){
        $route='config/folders/'+[Uri]::EscapeDataString([string]$folder.id)
        $patch=@{}
        if($folder.fsWatcherDelayS -ne (Get-DiskSeconds WATCHER_DELAY 2)){$patch.fsWatcherDelayS=(Get-DiskSeconds WATCHER_DELAY 2)}
        if($peer -and $peer -cin @($folder.devices|ForEach-Object {$_.deviceID})){
            try{Assert-DiskAcceptBase $folder.path;Assert-DiskPlainPath $folder.path}catch{continue}
            if(-not [IO.Directory]::Exists($folder.path)){continue}
            try{$rulesChanged=-not (Test-DiskFolderIgnoresCurrent $folder.path)}catch{
                if(-not $folder.paused){[void](Invoke-DiskApi $route PATCH @{paused=$true})}
                throw
            }
            $optionsChanged=$folder.maxConflicts -ne -1 -or $folder.versioning.type -cne 'staggered' -or $folder.versioning.params.maxAge -cne '2592000' -or $folder.versioning.params.cleanInterval -cne '3600'
            if($rulesChanged -or $optionsChanged){
                # Pause only a real migration. Repeated startup must not interrupt transfers.
                if(-not $folder.paused){[void](Invoke-DiskApi $route PATCH @{paused=$true})}
                Set-DiskFolderIgnores $folder.path
                $patch.paused=[bool]$folder.paused;$patch.maxConflicts=-1
                $versions=@{};$parameters=@{}
                if($folder.versioning){if($folder.versioning -is [Collections.IDictionary]){foreach($key in $folder.versioning.Keys){$versions[$key]=$folder.versioning[$key]}}else{foreach($property in $folder.versioning.PSObject.Properties){$versions[$property.Name]=$property.Value}}}
                if($folder.versioning.params){if($folder.versioning.params -is [Collections.IDictionary]){foreach($key in $folder.versioning.params.Keys){$parameters[$key]=$folder.versioning.params[$key]}}else{foreach($property in $folder.versioning.params.PSObject.Properties){$parameters[$property.Name]=$property.Value}}}
                $parameters.maxAge='2592000';$parameters.cleanInterval='3600';$versions.type='staggered';$versions.params=$parameters
                $patch.versioning=$versions
            }
        }
        if($patch.Count){[void](Invoke-DiskApi $route PATCH $patch)}
    }
    }finally{$operationLock.ReleaseMutex();$operationLock.Dispose()}
}
function Set-DiskServerDevice([string]$Peer) {
    $address='tcp://127.0.0.1:'+[int](Get-TransportEffectivePort (Join-Path $env:LOCALAPPDATA 'RemoteAgents') 'syncPort')
    $route='config/devices/'+[Uri]::EscapeDataString($Peer)
    $device=@(Invoke-DiskApi 'config/devices'|Where-Object {$_.deviceID -ceq $Peer})
    if(-not $device.Count){
        [void](Invoke-DiskApi $route PUT @{deviceID=$Peer;name='RemoteDisk Server';addresses=@($address);autoAcceptFolders=$false})
    }else{
        $patch=@{}
        if($device[0].autoAcceptFolders){$patch.autoAcceptFolders=$false}
        if(@($device[0].addresses).Count -ne 1 -or [string]$device[0].addresses[0] -cne $address){$patch.addresses=@($address)}
        if($patch.Count){[void](Invoke-DiskApi $route PATCH $patch)}
    }
}

# Reconcile the transport's effective port once, before starting Tray; no SSH or background polling.
function Sync-DiskServerAddress([string]$LauncherRoot) {
    $file=Join-Path $script:DiskHome 'server.txt'
    if(-not [IO.File]::Exists($file)){return $false}
    $peer=[IO.File]::ReadAllText($file).TrimStart([char]0xFEFF).Trim()
    if(-not $peer){return $false}
    $address='tcp://127.0.0.1:'+[int](Get-TransportEffectivePort $LauncherRoot 'syncPort')
    $route='config/devices/'+[Uri]::EscapeDataString($peer)
    $rest=$false
    try{$device=Invoke-DiskApi $route;$rest=$true}catch{
        # An active engine owns config.xml even while its REST listener is starting.
        if(@(Get-DiskEngineProcesses $script:DiskHome).Count){throw 'Syncthing работает, но REST ещё недоступен; адрес сервера будет проверен при повторном запуске'}
    }
    if($rest){
        if(@($device.addresses).Count -eq 1 -and [string]$device.addresses[0] -ceq $address){return $false}
        [void](Invoke-DiskApi $route PATCH @{addresses=@($address)})
    }else{
        Read-DiskState
        $devices=@($script:Engine.configuration.SelectNodes('device')|Where-Object {$_.GetAttribute('id') -ceq $peer})
        if($devices.Count -ne 1){throw 'Устройство сервера отсутствует в config.xml Syncthing; повторите установку Disk'}
        $device=$devices[0];$addresses=@($device.SelectNodes('address'))
        if($addresses.Count -eq 1 -and $addresses[0].InnerText -ceq $address){return $false}
        foreach($old in $addresses){[void]$device.RemoveChild($old)}
        $node=$script:Engine.CreateElement('address');$node.InnerText=$address;[void]$device.AppendChild($node)
        $script:Engine.Save((Join-Path $script:DiskHome 'state/config.xml'))
    }
    Write-DiskLog ('Адрес сервера Syncthing обновлён: '+$address)
    return $true
}
