#requires -Version 5.1
$ErrorActionPreference='Stop'
# .NET Framework writes Console.InputEncoding's BOM into every redirected stdin; on a UTF-8 console that corrupts the first line sent to ssh.
try{[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false);if([Console]::InputEncoding.GetPreamble().Length){[Console]::InputEncoding=New-Object Text.UTF8Encoding($false)}}catch{}
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
# Valid project names in our own .stignore refusal are context, even when they look like long tokens.
function Protect-DiskFailureText([string]$Text) {
    $names=@();$safe=$Text
    foreach($m in [regex]::Matches($Text,'(^|: )([\p{L}\p{N}_. -]{1,128})(?=: Чужой \.stignore)')){
        $name=$m.Groups[2].Value;$placeholder='diskfolder'+$names.Count
        $safe=$safe.Replace($name+': Чужой .stignore',$placeholder+': Чужой .stignore');$names+=@($name)
    }
    if(Get-Command Protect-TransportText -ErrorAction SilentlyContinue){$safe=Protect-TransportText $safe}
    else{$safe=$safe -replace '[A-Za-z0-9+/_=-]{20,}','<secret>' -replace '://[^/@\s]+@','://<auth>@'}
    for($i=0;$i -lt $names.Count;$i++){$safe=$safe.Replace(('diskfolder'+$i+': Чужой .stignore'),($names[$i]+': Чужой .stignore'))}
    $safe
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
# Retry only an explicitly reviewed idempotent operation. Three repeats, four attempts total.
function Test-DiskSshTransient([int]$ExitCode,[string]$Text) {
    $text=$Text.Replace("`r",'')
    if($text -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed|Permission denied|Сервер отклонил вход|Ключ хоста|Чужой \.stignore'){return $false}
    return $ExitCode -eq 255 -and $text -match 'banner exchange|kex_exchange_identification|Connection closed|Connection reset|timed out|Connection refused|No route to host|Network is unreachable|Нет SSH-баннера|Нет связи с сервером'
}
function Invoke-DiskRetry([scriptblock]$Operation) {
    $delays=@(2,5,10)
    for($attempt=0;;$attempt++){
        try{return & $Operation}catch{
            $failure=$_;$message=[string]$failure.Exception.Message
            $transient=$failure.Exception.Data['DiskSshTransient'] -eq $true
            # A lost control session can have executed the command; callers must opt in to safe replay.
            if($message -like 'Управляющий SSH-сеанс прерван*'){$transient=$true}
            if(-not $transient -or $attempt -ge $delays.Count){throw}
            $seconds=$delays[$attempt]
            Write-DiskProgress ('Нет связи с сервером, повтор через '+$seconds+' с…') | Out-Null
            Start-Sleep -Seconds $seconds
        }
    }
}
function Invoke-DiskProcess($Exe,$Arguments,[string]$InputText='',[string]$OutputFile='',[int]$TimeoutSeconds=45,[switch]$RetrySafe) {
    $run={Invoke-DiskProcessOnce $Exe $Arguments $InputText $OutputFile -TimeoutSeconds $TimeoutSeconds}
    if($RetrySafe){return Invoke-DiskRetry $run}
    return & $run
}
function Invoke-DiskProcessOnce($Exe,$Arguments,[string]$InputText='',[string]$OutputFile='',[int]$TimeoutSeconds=45) {
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
        try{if(-not $write.Wait([Math]::Max(15,$TimeoutSeconds)*1000)){throw 'Таймаут ввода'}}catch{
            # A server can refuse before reading stdin. Its stderr/exit code is more useful than Broken pipe.
            if(-not $p.WaitForExit(1000)){throw};$inputFailure=$_
        }
        try{$p.StandardInput.Close()}catch{if(-not $p.HasExited){throw};if(-not $inputFailure){$inputFailure=$_}}
        if(-not $p.WaitForExit($TimeoutSeconds*1000)){$p.Kill();throw 'Таймаут команды'};$out.GetAwaiter().GetResult() | Out-Null
        if($p.ExitCode -ne 0){$reason='Внешняя команда не выполнена';if($p.ExitCode -eq 255 -and [IO.Path]::GetFileNameWithoutExtension($Exe) -ieq 'ssh'){$reason=if($err.Result -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed'){"Ключ хоста не совпал с приглашением или known_hosts. Подключение остановлено; попросите администратора проверить ключ сервера"}elseif($err.Result -match 'Permission denied'){'Сервер отклонил вход'}elseif($err.Result -match 'Remote protocol version' -and $err.Result -match 'timed out|Connection reset'){'Сервер ответил, но сеть глушит SSH после рукопожатия — нужен обход (канал через промежуточный сервер)'}elseif($err.Result -match 'banner exchange|kex_exchange_identification|Connection closed|Connection reset|timed out'){'Нет SSH-баннера от сервера'}else{'Нет связи с сервером'};if($err.Result -match 'proxy-connect: ([^\r\n]+)'){$reason+=': '+$Matches[1]}}elseif([IO.Path]::GetFileNameWithoutExtension($Exe) -ieq 'ssh'){$detail=Get-DiskServerFailure $err.Result;if($detail){$reason=$detail}};$failure=New-Object IO.IOException ($reason+' (код выхода '+$p.ExitCode+')');$failure.Data['DiskSshTransient']=([IO.Path]::GetFileNameWithoutExtension($Exe) -ieq 'ssh' -and (Test-DiskSshTransient $p.ExitCode $err.Result));throw $failure}
        if($inputFailure){throw $inputFailure}
        if(-not $OutputFile){$out.Result.Replace("`r",'').TrimStart([char]0xFEFF).Trim()}
    }finally{if($file){$file.Dispose()};if($p.Id -and -not $p.HasExited){$p.Kill()}
        if($trace){try{$code=if($p.HasExited){[string]$p.ExitCode}else{'прервано'};$text=if($err -and $err.Wait(2000)){$err.Result}else{''};Write-WizardTrace $Exe $si.Arguments $code $watch.ElapsedMilliseconds $text}catch{}}
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
function Invoke-DiskSsh($Command,[switch]$Direct,[string]$InputText='',[string]$OutputFile='',[int]$TimeoutSeconds=45,[switch]$RetrySafe) {
    $c=$script:Connection;$args=@('-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes')
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
    Invoke-DiskProcess $c.sshExecutable ($args+@($Command)) $InputText $OutputFile -TimeoutSeconds $TimeoutSeconds -RetrySafe:$RetrySafe
}
function Get-DiskTreeCommand([string]$RelativePath='') {
    $command='bash "$HOME/.local/share/remote-disk/server-disk.sh" tree'
    if($RelativePath){
        Assert-SelectionPath $RelativePath
        # Quote a literal argument for the remote POSIX shell (names may contain apostrophes).
        $quote=[string][char]39;$escape=$quote+'"'+$quote+'"'+$quote
        $command+=' '+$quote+$RelativePath.Replace($quote,$escape)+$quote
    }
    $command
}
function Invoke-DiskServer($Action,$Data=$null,[switch]$Direct,[string]$OutputFile='') {
    $cmd='bash "$HOME/.local/share/remote-disk/server-disk.sh" '+$Action
    $inputText=''
    if($Action -eq 'tree'){$cmd=Get-DiskTreeCommand ([string]$Data.path)}
    elseif($Data){
        $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Data|ConvertTo-Json -Depth 20 -Compress)))
        if($Action -eq 'verify-selection'){$cmd+=' --stdin';$inputText=$encoded}else{$cmd+=' '+$encoded}
    }
    # list/tree/verification read state; attach/detach/add-device are upserts of stable identities.
    # Other server actions get no implicit replay.
    $safe=$Action -in @('list','tree','channel-config','verify-selection','attach','detach','add-device','bootstrap')
    $text=Invoke-DiskSsh $cmd -Direct:$Direct -OutputFile $OutputFile -InputText $inputText -RetrySafe:$safe
    if(-not $OutputFile -and $text){$value=$text|ConvertFrom-Json;if($null -ne $value){foreach($item in $value){$item}}}
}
function Invoke-DiskApi($Route,$Method='GET',$Body=$null) {
    if(-not $script:DiskHome){$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'}
    if(-not $script:Gui -or -not $script:ApiKey){Read-DiskState}
    $args=@{Uri=('http://'+$script:Gui+'/rest/'+$Route);Method=$Method;Headers=@{'X-API-Key'=$script:ApiKey};TimeoutSec=5;UseBasicParsing=$true}
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
    @('[General]','v=2.1.9','[tray]','connections\size=1','connections\1\label=RemoteDisk',('connections\1\syncthingUrl=http://'+$Gui),('connections\1\apiKey='+$ApiKey),'connections\1\autoConnect=true','connections\1\reconnectInterval=30','notifyOnDisconnect=false','notifyOnErrors=true','showSyncthingNotifications=true','[startup]','syncthingAutostart=true','useLibSyncthing=false',('syncthingPath='+$Tray.Replace('\','/')),('syncthingArgs="syncthing serve --home \"'+$State.Replace('\','/')+'\" --no-browser --no-restart"'),'considerLauncherForReconnect=true','showLauncherButton=false','') -join "`n"
}
# One upgrade boundary for Install, Select and the wizard. The history is append-only across bundle versions.
function Get-DiskIgnoreUpload([string]$Directory=$PSScriptRoot) {
    $payload=@{rules=[IO.File]::ReadAllText((Join-Path $Directory 'stignore.txt')).Replace("`r",'');versions=@([IO.File]::ReadAllLines((Join-Path $Directory 'stignore-previous.sha256')))}|ConvertTo-Json -Depth 5 -Compress
    $source=@'
import os,base64,json,hashlib,tempfile,fcntl
from pathlib import Path
p=Path.home()/'.local/share/remote-disk'
if any(x.is_symlink() for x in (p,*p.parents)):raise ValueError('symlink')
p.mkdir(parents=True,exist_ok=True)
def safe(f):
 if f.is_symlink():raise ValueError('symlink')
def normalized(s):return s.lstrip('\ufeff').replace('\r','').rstrip('\n')+'\n'
def digest(s):return hashlib.sha256(normalized(s).encode()).hexdigest()
r=json.loads(base64.b64decode('PAYLOAD_BASE64'));history=p/'stignore-previous.sha256';template=p/'stignore.txt';lock=p/'.stignore-history.lock'
for f in (history,template,lock):safe(f)
with lock.open('a') as gate:
 fcntl.flock(gate,fcntl.LOCK_EX)
 versions=set(r['versions'])
 if history.exists():versions.update(history.read_text(encoding='utf-8-sig').splitlines())
 if template.exists():versions.add(digest(template.read_text(encoding='utf-8-sig')))
 versions.add(digest(r['rules']))
 versions={v.strip() for v in versions if v.strip()}
 if any(len(v)!=64 or any(c not in '0123456789abcdef' for c in v) for v in versions):raise ValueError('Invalid stignore history')
 # Publish history first: even an interrupted template update recognizes both versions.
 for f,text in ((history,'\n'.join(sorted(versions))+'\n'),(template,normalized(r['rules']))):
  fd,tmp=tempfile.mkstemp(dir=p)
  try:
   with os.fdopen(fd,'w',encoding='utf-8',newline='\n') as out:out.write(text);out.flush();os.fsync(out.fileno())
   os.replace(tmp,f)
  finally:
   if os.path.exists(tmp):os.unlink(tmp)
'@
    $source=$source.Replace('PAYLOAD_BASE64',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)))
    'python3 -c ''import base64;exec(base64.b64decode("'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source.Replace("`r",'')))+'"))''' + "`n"
}
function Get-DiskKnownIgnoreHashes {
    if(-not $script:DiskHome){$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'}
    [void][IO.Directory]::CreateDirectory($script:DiskHome)
    $file=Join-Path $script:DiskHome 'stignore-previous.sha256'
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
        $id=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($file).ToLowerInvariant())))).Replace('-','')
        $rules=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'stignore.txt')).Replace("`r",'').TrimEnd("`n")+"`n"
        $current=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($rules)))).Replace('-','').ToLowerInvariant()
    }finally{$sha.Dispose()}
    $mutex=New-Object Threading.Mutex($false,('RemoteDiskIgnoreHistory-'+$id));$held=$false
    try{
        try{$held=$mutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){throw 'История шаблонов Disk занята; повторите подключение'}
        $versions=@([IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'stignore-previous.sha256')))+@($current)
        if(Test-Path -LiteralPath $file){$versions+=@([IO.File]::ReadAllLines($file))}
        $versions=@($versions|ForEach-Object {$_.Trim()}|Where-Object {$_}|Sort-Object -Unique)
        foreach($v in $versions){if($v -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Повреждена история шаблонов Disk'}}
        $temp=$file+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        try{Write-DiskUtf8 $temp (($versions -join "`n")+"`n");if([IO.File]::Exists($file)){[IO.File]::Replace($temp,$file,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temp,$file)}}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
        $versions
    }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Test-DiskIgnores($Path,[switch]$Write) {
    $known=@(Get-DiskKnownIgnoreHashes)
    $file=Join-Path $Path '.stignore';$rules=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'stignore.txt'))
    $managed='';if(Get-Command Get-SelectionPolicyFile -ErrorAction SilentlyContinue){$policy=Get-SelectionPolicyFile $Path;if(Test-Path -LiteralPath $policy){$managed=[IO.File]::ReadAllText($policy).Replace("`r",'')}}
    if(Test-Path -LiteralPath $file){
        if([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::ReparsePoint){throw 'Ссылка .stignore запрещена'}
        $old=[IO.File]::ReadAllText($file)
        if($old.Replace("`r",'').TrimEnd("`n") -cne $rules.Replace("`r",'').TrimEnd("`n") -and $old.Replace("`r",'') -cne $managed -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'stignore.txt')))){
            $normalized=($old.TrimEnd("`r","`n").Replace("`r`n","`n")+"`n");$sha=[Security.Cryptography.SHA256]::Create()
            try{$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
            if($hash -cnotin $known){throw ((Split-Path -Leaf $Path)+': Чужой .stignore: сохраните и удалите его вручную перед подключением')}
        }
    }
    if($managed){$rules=$managed}
    if($Write){if(Test-Path -LiteralPath $file){[IO.File]::SetAttributes($file,([IO.File]::GetAttributes($file) -band (-bnot [IO.FileAttributes]::Hidden)))};try{if(-not [IO.Directory]::Exists((Join-Path $Path '.stfolder'))){[void][IO.Directory]::CreateDirectory((Join-Path $Path '.stfolder'))};Write-SelectionAtomic $file $rules}finally{if(Test-Path -LiteralPath $file){[IO.File]::SetAttributes($file,([IO.File]::GetAttributes($file) -bor [IO.FileAttributes]::Hidden))}}}
}
# -AllowContent: an existing local folder with files is merged (owner decision), only links and Syncthing overlaps are refused.
function Assert-DiskFreePath([string]$Path,$Folders,[switch]$AllowContent) {
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    for($part=$full;$part;$part=[IO.Path]::GetDirectoryName($part)){
        if(Test-Path -LiteralPath $part){if([IO.File]::GetAttributes($part) -band [IO.FileAttributes]::ReparsePoint){throw 'Ссылки в пути запрещены'}}
    }
    foreach($folder in $Folders){
        $other=[IO.Path]::GetFullPath($folder.path).TrimEnd('\','/')
        if($full -ieq $other -or $full.StartsWith($other+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $other.StartsWith($full+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'папка занята: пересечение с Syncthing'}
    }
    if(Test-Path -LiteralPath $full){
        if($AllowContent -and (Get-Item -LiteralPath $full).PSIsContainer){return}
        if(-not (Get-Item -LiteralPath $full).PSIsContainer -or @(Get-ChildItem -LiteralPath $full -Force).Count){throw 'папка занята'}
    }
}
# Base folder like Yandex Disk: %USERPROFILE%\Disk unless the owner chose another one.
function Get-DiskBase {
    $saved=Join-Path $script:DiskHome 'base.txt'
    if(Test-Path -LiteralPath $saved){return [IO.File]::ReadAllText($saved).Trim()}
    Join-Path $env:USERPROFILE 'Disk'
}
# desktop.ini is only a placeholder marker while no user/engine entries exist.
# Own helper is needed because Syncthing does not know Explorer-only placeholders.
function Test-DiskPlaceholder([string]$Path) {
    if(-not [IO.Directory]::Exists($Path)){return $false}
    Assert-DiskPlainPath $Path
    $ini=Join-Path $Path 'desktop.ini'
    if(-not [IO.File]::Exists($ini) -or ([IO.File]::GetAttributes($ini) -band [IO.FileAttributes]::ReparsePoint)){return $false}
    $section='';$owner='';$placeholder=''
    foreach($line in ([IO.File]::ReadAllText($ini).Replace("`r",'') -split "`n")){
        if($line -match '^\s*\[([^]]+)\]\s*$'){$section=$Matches[1];continue}
        if($section -ieq 'RemoteAgents'){
            if($line -match '^\s*Owner\s*=\s*(.*?)\s*$'){$owner=$Matches[1]}
            if($line -match '^\s*Placeholder\s*=\s*(.*?)\s*$'){$placeholder=$Matches[1]}
        }
    }
    if($owner -cne 'RemoteAgents.Disk.v1' -or $placeholder -cne '1'){return $false}
    foreach($item in (New-Object IO.DirectoryInfo($Path)).EnumerateFileSystemInfos()){
        if($item.Name -ine 'desktop.ini'){return $false}
    }
    return $true
}
function Test-DiskLocalContent([string]$Path) {
    if(-not [IO.Directory]::Exists($Path) -or (Test-DiskPlaceholder $Path)){return $false}
    foreach($item in (New-Object IO.DirectoryInfo($Path)).EnumerateFileSystemInfos()){
        if($item.Name -in @('.git','.stignore','.stfolder','.stversions')){continue}
        if($item.Name -ieq 'desktop.ini' -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){
            $text=[IO.File]::ReadAllText($item.FullName).Replace("`r",'')
            if($text -match '(?m)^Owner=RemoteAgents\.Disk\.v1$'){continue}
        }
        return $true
    }
    return $false
}
function Copy-DiskTree([string]$From,[string]$To) {
    Assert-DiskPlainPath $From;Assert-DiskPlainPath $To
    [void][IO.Directory]::CreateDirectory($To);$dir=New-Object IO.DirectoryInfo($From)
    foreach($item in $dir.GetFileSystemInfos()){
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Ссылки в папке запрещены: '+$item.FullName)}
        $target=Join-Path $To $item.Name
        if($item -is [IO.DirectoryInfo]){Copy-DiskTree $item.FullName $target}else{[IO.File]::Copy($item.FullName,$target);[IO.File]::SetLastWriteTimeUtc($target,$item.LastWriteTimeUtc)}
        [IO.File]::SetAttributes($target,$item.Attributes)
    }
    [IO.Directory]::SetLastWriteTimeUtc($To,$dir.LastWriteTimeUtc)
}
function Get-DiskTreeList([string]$Path) {
    Assert-DiskPlainPath $Path
    function Read-DiskTreeList([string]$Directory,[string]$Root) {
        foreach($item in (New-Object IO.DirectoryInfo($Directory)).EnumerateFileSystemInfos()){
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Ссылки в папке запрещены: '+$item.FullName)}
            $item.FullName.Substring($Root.Length)+'|'+$(if($item -is [IO.DirectoryInfo]){'d'}else{(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash})
            if($item -is [IO.DirectoryInfo]){Read-DiskTreeList $item.FullName $Root}
        }
    }
    @(Read-DiskTreeList $Path $Path|Sort-Object) -join "`n"
}
function Move-DiskFolder([string]$FolderId,[string]$Destination,[switch]$Copy) {
    $route='config/folders/'+[Uri]::EscapeDataString($FolderId)
    $folder=Invoke-DiskApi $route;$old=[IO.Path]::GetFullPath($folder.path).TrimEnd('\','/');$Destination=[IO.Path]::GetFullPath($Destination).TrimEnd('\','/')
    if($old -ieq $Destination){return 'Папка уже на месте'}
    if($Destination.StartsWith($old+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Нельзя перенести папку внутрь неё самой'}
    $others=@(Invoke-DiskApi 'config/folders'|Where-Object {$_.id -cne $FolderId})
    Assert-DiskFreePath $Destination $others
    if([IO.Path]::GetPathRoot($old) -ine [IO.Path]::GetPathRoot($Destination)){$Copy=$true}
    $source=Get-Item -LiteralPath $old
    for($part=$source;$null -ne $part;$part=$part.Parent){if($part.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Ссылки в пути запрещены'}}
    $paused=[bool]$folder.paused
    $events=@(Invoke-DiskApi 'events?since=0&limit=1&timeout=1');$since=0;if($events.Count){$since=$events[-1].id}
    [void](Invoke-DiskApi $route PATCH @{paused=$true})
    $ready=$false
    for($i=0;$i -lt 8;$i++){
        $events=@(Invoke-DiskApi ('events?since='+$since+'&timeout=1'))
        if(@($events|Where-Object {$_.type -eq 'FolderPaused' -and $_.data.id -ceq $FolderId}).Count){$ready=$true;break}
        if($paused -and (Invoke-DiskApi 'config/insync').configInSync -and (Invoke-DiskApi ('db/status?folder='+[Uri]::EscapeDataString($FolderId))).state -eq ''){$ready=$true;break}
    }
    if(-not $ready){throw 'Не подтверждена пауза: перенос отменён, папка оставлена на паузе'}
    Assert-DiskFreePath $Destination $others
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination))
    if(Test-Path -LiteralPath $Destination){[IO.Directory]::Delete($Destination,$false)} # empty only
    if($Copy){
        # Another volume: verify content, but retain the recovery source because editors remain live.
        try{Copy-DiskTree $old $Destination;if((Get-DiskTreeList $old) -cne (Get-DiskTreeList $Destination)){throw 'Копия не совпадает с исходной папкой'}}
        catch{throw ('Копия не проверена. Исходная папка и неполная копия сохранены: '+$old+'; '+$Destination+'. Проверьте их перед повторным переносом')}
        # Editors are not suspended by a Syncthing pause. Keep the source as a
        # recovery copy, including files created/changed during the copy.
        Write-DiskLog ('Исходная копия после переноса сохранена: '+$old)
    }else{[IO.Directory]::Move($old,$Destination)}
    # A selective policy belongs to its path; carry its trusted receipt with a managed move.
    if(Get-Command Get-SelectionPolicyFile -ErrorAction SilentlyContinue){$policy=Get-SelectionPolicyFile $old;if(Test-Path -LiteralPath $policy){Save-SelectionPolicy $Destination ([IO.File]::ReadAllText($policy))}}
    # On API failure leave paused; files are safe at Destination. Rerun path PATCH manually.
    [void](Invoke-DiskApi $route PATCH @{path=$Destination})
    [void](Invoke-DiskApi $route PATCH @{paused=$paused})
    $summary='Перенесено: '+$Destination;if($Copy){$summary+='; исходная копия сохранена: '+$old};$summary
}
# Changing the base moves every server folder lying directly in the previous base.
function Set-DiskBase([string]$Path) {
    $new=[IO.Path]::GetFullPath($Path).TrimEnd('\','/');$saved=Join-Path $script:DiskHome 'base.txt'
    $old=@((Get-DiskBase))
    $old=@($old|ForEach-Object {[IO.Path]::GetFullPath($_).TrimEnd('\','/')}|Where-Object {$_ -ine $new})
    $server=Join-Path $script:DiskHome 'server.txt'
    if($old.Count -and (Test-Path -LiteralPath $server)){
        $peer=[IO.File]::ReadAllText($server).Trim();$failed=@()
        foreach($folder in @(Invoke-DiskApi 'config/folders')){
            if(-not @($folder.devices|Where-Object {$_.deviceID -ceq $peer}).Count){continue}
            $path=[IO.Path]::GetFullPath($folder.path).TrimEnd('\','/')
            if([IO.Path]::GetDirectoryName($path) -notin $old){continue}
            try{Write-Output (Move-DiskFolder $folder.id (Join-Path $new ([IO.Path]::GetFileName($path))));Write-DiskLog ('Переезд базы: '+$folder.label)}
            catch{Write-DiskLog ('Переезд базы: '+$folder.label) $_;$failed+=($folder.label+': '+$_.Exception.Message)}
        }
        if($failed.Count){throw ('Не перенесены: '+($failed -join '; ')+'. Прежняя база сохранена; устраните причину и повторите')}
    }
    [void][IO.Directory]::CreateDirectory($new);Write-DiskUtf8 $saved $new
    # An existing Explorer entry follows the new root; a failure leaves the base change intact.
    if((Get-Command Test-DiskNavPane -ErrorAction SilentlyContinue) -and (Test-DiskNavPane $new).installed){try{Install-DiskNavPane $new}catch{Write-DiskLog 'Значок Disk в Проводнике' $_}}
}

$selective=Join-Path $PSScriptRoot 'Disk.Selective.ps1';if(Test-Path -LiteralPath $selective){. $selective}
$navPane=Join-Path $PSScriptRoot 'Disk.NavPane.ps1';if(Test-Path -LiteralPath $navPane){. $navPane}
$explorer=Join-Path $PSScriptRoot 'Disk.Explorer.ps1';if(Test-Path -LiteralPath $explorer){. $explorer}

# Только локальный адрес устройства сервера; остальные настройки устройства сохраняются.
function Sync-DiskServerAddress([string]$LauncherRoot=(Join-Path $env:LOCALAPPDATA 'RemoteAgents')) {
    $file=Join-Path $script:DiskHome 'server.txt'
    if(-not (Test-Path -LiteralPath $file)){return $false}
    try{
        if(-not (Get-Command Get-TransportEffectivePort -ErrorAction SilentlyContinue)){. (Join-Path (Split-Path $PSScriptRoot -Parent) 'transport/Transport.Common.ps1')}
        $peer=[IO.File]::ReadAllText($file).Replace("`r",'').TrimStart([char]0xFEFF).Trim()
        if(-not $peer){return $false}
        $route='config/devices/'+[Uri]::EscapeDataString($peer)
        $device=Invoke-DiskApi $route
        $address='tcp://127.0.0.1:'+[int](Get-TransportEffectivePort $LauncherRoot 'syncPort')
        if(@($device.addresses).Count -eq 1 -and [string]$device.addresses[0] -ceq $address){return $false}
        [void](Invoke-DiskApi $route PATCH @{addresses=@($address)})
        Write-DiskLog ('Адрес сервера Syncthing обновлён: '+$address)
        return $true
    }catch{Write-DiskLog 'Не удалось обновить локальный адрес сервера Syncthing; повторим проверку';return $false}
}
