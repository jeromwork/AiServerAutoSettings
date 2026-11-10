#requires -Version 5.1
$ErrorActionPreference='Stop'
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
function Quote-Disk([string]$Value) {'"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'}
function Invoke-DiskProcess($Exe,$Arguments,[string]$InputText='',[string]$OutputFile='',[int]$TimeoutSeconds=45) {
    $si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=$Exe;$si.Arguments=($Arguments|ForEach-Object {Quote-Disk ([string]$_)}) -join ' '
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true;$si.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
    $p=New-Object Diagnostics.Process;$p.StartInfo=$si;$file=$null
    try {[void]$p.Start();$err=$p.StandardError.ReadToEndAsync()
        if($OutputFile){$file=[IO.File]::Create($OutputFile);$out=$p.StandardOutput.BaseStream.CopyToAsync($file)}else{$out=$p.StandardOutput.ReadToEndAsync()}
        $bytes=[Text.Encoding]::UTF8.GetBytes($InputText.Replace("`r",''));$write=$p.StandardInput.BaseStream.WriteAsync($bytes,0,$bytes.Length)
        if(-not $write.Wait(15000)){throw 'Таймаут ввода'};$p.StandardInput.Close()
        if(-not $p.WaitForExit($TimeoutSeconds*1000)){$p.Kill();throw 'Таймаут команды'};$out.GetAwaiter().GetResult() | Out-Null
        if($p.ExitCode -ne 0){$reason='Внешняя команда не выполнена';if($p.ExitCode -eq 255 -and [IO.Path]::GetFileNameWithoutExtension($Exe) -ieq 'ssh'){$reason='Нет связи с сервером'}elseif($err.Result -match 'Чужой .stignore'){$reason='Чужой .stignore на сервере: сохраните и удалите его вручную'}elseif($err.Result -match 'требуется -Merge'){$reason='Обе папки непустые: требуется -Merge'};throw ($reason+' (код выхода '+$p.ExitCode+')')}
        if(-not $OutputFile){$out.Result.Replace("`r",'').TrimStart([char]0xFEFF).Trim()}
    }finally{if($file){$file.Dispose()};if($p.Id -and -not $p.HasExited){$p.Kill()};$p.Dispose()}
}
function Read-DiskProfile([string]$Profile) {
    if(-not $Profile){$saved=Join-Path $script:DiskHome 'profile.txt';if(Test-Path -LiteralPath $saved){$Profile=[IO.File]::ReadAllText($saved)}}
    if(-not $Profile){$files=@(Get-ChildItem -Path "$env:LOCALAPPDATA/RemoteAgents/ssh-profiles/*/project-connections/*/ssh-transport.json" -File);if($files.Count -ne 1){throw 'Укажите -Profile: нужен один SSH-профиль'};$Profile=$files[0].FullName}
    $script:ProfilePath=[IO.Path]::GetFullPath($Profile);$script:Connection=[IO.File]::ReadAllText($script:ProfilePath)|ConvertFrom-Json
    foreach($f in @('sshExecutable','arguments','serverAddress','login','keyPath','knownHostsPath','configPath')){if(-not $script:Connection.$f){throw 'Неполный SSH-профиль'}}
    if($script:Connection.login.Trim() -ieq 'root'){throw 'SSH-профиль должен входить как рабочий пользователь, не root'}
}
function Invoke-DiskSsh($Command,[switch]$Direct,[string]$InputText='',[string]$OutputFile='',[int]$TimeoutSeconds=45) {
    $c=$script:Connection;$args=@('-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes')
    $localPort=2222
    if($c.configPath -and (Test-Path -LiteralPath $c.configPath)){
        $managed=[regex]::Match([IO.File]::ReadAllText($c.configPath),'(?ms)^# BEGIN RemoteAgents transport [^\r\n]+\r?\n(.*?)^# END RemoteAgents transport [^\r\n]+')
        if($managed.Success -and $managed.Groups[1].Value -match ('(?m)^Host "'+[regex]::Escape($c.serverAddress)+'"\r?$') -and $managed.Groups[1].Value -match '(?m)^    Port (\d+)\r?$'){$localPort=[int]$Matches[1]}
    }
    if($Direct){$args+=@($c.arguments)}else{$args+=@('-F','NUL','-p',[string]$localPort,'-i',$c.keyPath,'-o',('HostKeyAlias='+$c.serverAddress),'-o',('UserKnownHostsFile="'+$c.knownHostsPath.Replace('\','/')+'"'),'-o','IdentitiesOnly=yes',($c.login+'@127.0.0.1'))}
    Invoke-DiskProcess $c.sshExecutable ($args+@($Command)) $InputText $OutputFile -TimeoutSeconds $TimeoutSeconds
}
function Invoke-DiskServer($Action,$Data=$null,[switch]$Direct,[string]$OutputFile='') {
    $cmd='bash "$HOME/.local/share/remote-disk/server-disk.sh" '+$Action
    $inputText=''
    if($Data){
        $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Data|ConvertTo-Json -Depth 20 -Compress)))
        if($Action -eq 'verify-selection'){$cmd+=' --stdin';$inputText=$encoded}else{$cmd+=' '+$encoded}
    }
    $text=Invoke-DiskSsh $cmd -Direct:$Direct -OutputFile $OutputFile -InputText $inputText
    if(-not $OutputFile -and $text){$value=$text|ConvertFrom-Json;if($null -ne $value){foreach($item in $value){$item}}}
}
function Invoke-DiskApi($Route,$Method='GET',$Body=$null) {
    if(-not $script:DiskHome){$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'}
    if(-not $script:Gui -or -not $script:ApiKey){Read-DiskState}
    $args=@{Uri=('http://'+$script:Gui+'/rest/'+$Route);Method=$Method;Headers=@{'X-API-Key'=$script:ApiKey};TimeoutSec=5;UseBasicParsing=$true}
    if($null -ne $Body){$args.Body=[Text.Encoding]::UTF8.GetBytes(($Body|ConvertTo-Json -Depth 30 -Compress));$args.ContentType='application/json'}
    try {$value=Invoke-RestMethod @args;foreach($item in $value){if($null -ne $item -and -not ($item -is [string] -and $item.Length -eq 0)){$item}}}catch{throw ('REST Syncthing недоступен ('+$script:Gui+'); проверьте запущенный RemoteDisk и state/config.xml')}
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
function New-DiskHop([string]$Text) {
    $values=@{};foreach($line in $Text.Replace("`r",'') -split "`n"){if($line -match '^(hostname|user|identityfile|port) (.+)$' -and -not $values.ContainsKey($Matches[1])){$values[$Matches[1]]=$Matches[2].Trim('"')}}
    foreach($k in @('hostname','user','identityfile')){if(-not $values[$k]){throw 'Неполный профиль промежуточного хоста'}}
    $profileHome=[Environment]::GetFolderPath('UserProfile');if($env:USERPROFILE){$profileHome=$env:USERPROFILE};$key=$values.identityfile.Replace('%d',$profileHome)
    if($key -match '^~(?=[\\/]|$)'){$key=$profileHome+$key.Substring(1)}
    @{server=$values.hostname;server_port=[int]$values.port;user=$values.user;private_key_path=$key}
}
function Convert-DiskChannel([string]$Text) {$c=$Text|ConvertFrom-Json;if($c.route.final -ne 'server' -or @($c.inbounds).Count -ne 2){throw 'Неверная конфигурация канала'};$c|ConvertTo-Json -Depth 20 -Compress}
function Test-DiskIgnores($Path,[switch]$Write) {
    $file=Join-Path $Path '.stignore';$rules=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'stignore.txt'))
    $managed='';if(Get-Command Get-SelectionPolicyFile -ErrorAction SilentlyContinue){$policy=Get-SelectionPolicyFile $Path;if(Test-Path -LiteralPath $policy){$managed=[IO.File]::ReadAllText($policy).Replace("`r",'')}}
    if(Test-Path -LiteralPath $file){
        if([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::ReparsePoint){throw 'Ссылка .stignore запрещена'}
        $old=[IO.File]::ReadAllText($file)
        if($old.Replace("`r",'').TrimEnd("`n") -cne $rules.Replace("`r",'').TrimEnd("`n") -and $old.Replace("`r",'') -cne $managed -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'stignore.txt')))){
            $normalized=($old.TrimEnd("`r","`n").Replace("`r`n","`n")+"`n");$sha=[Security.Cryptography.SHA256]::Create()
            try{$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
            if($hash -cnotin [IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'legacy-ignores.sha256'))){throw 'Чужой .stignore: сохраните и удалите его вручную перед подключением'}
        }
    }
    if($managed){$rules=$managed}
    if($Write){if(Test-Path -LiteralPath $file){[IO.File]::SetAttributes($file,([IO.File]::GetAttributes($file) -band (-bnot [IO.FileAttributes]::Hidden)))};try{Write-DiskUtf8 $file $rules}finally{if(Test-Path -LiteralPath $file){[IO.File]::SetAttributes($file,([IO.File]::GetAttributes($file) -bor [IO.FileAttributes]::Hidden))}}}
}
function Assert-DiskFreePath([string]$Path,$Folders) {
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    for($part=$full;$part;$part=[IO.Path]::GetDirectoryName($part)){
        if(Test-Path -LiteralPath $part){if([IO.File]::GetAttributes($part) -band [IO.FileAttributes]::ReparsePoint){throw 'Ссылки в пути запрещены'}}
    }
    foreach($folder in $Folders){
        $other=[IO.Path]::GetFullPath($folder.path).TrimEnd('\','/')
        if($full -ieq $other -or $full.StartsWith($other+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $other.StartsWith($full+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'папка занята: пересечение с Syncthing'}
    }
    if(Test-Path -LiteralPath $full){
        if(-not (Get-Item -LiteralPath $full).PSIsContainer -or @(Get-ChildItem -LiteralPath $full -Force).Count){throw 'папка занята'}
    }
}
# Base folder like Yandex Disk: %USERPROFILE%\Disk unless the owner chose another one.
function Get-DiskBase {
    $saved=Join-Path $script:DiskHome 'base.txt'
    if(Test-Path -LiteralPath $saved){return [IO.File]::ReadAllText($saved).Trim()}
    Join-Path $env:USERPROFILE 'Disk'
}
function Copy-DiskTree([string]$From,[string]$To) {
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
    @(Get-ChildItem -LiteralPath $Path -Recurse -Force|ForEach-Object {$_.FullName.Substring($Path.Length)+'|'+$(if($_.PSIsContainer){'d'}else{$_.Length})}|Sort-Object) -join "`n"
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
        # Another volume: copy, verify, then remove the source. A failed copy leaves the source intact.
        try{Copy-DiskTree $old $Destination;if((Get-DiskTreeList $old) -cne (Get-DiskTreeList $Destination)){throw 'Копия не совпадает с исходной папкой'}}
        catch{if(Test-Path -LiteralPath $Destination){Remove-Item -LiteralPath $Destination -Recurse -Force};throw}
        Remove-Item -LiteralPath $old -Recurse -Force
    }else{[IO.Directory]::Move($old,$Destination)}
    # On API failure leave paused; files are safe at Destination. Rerun path PATCH manually.
    [void](Invoke-DiskApi $route PATCH @{path=$Destination})
    [void](Invoke-DiskApi $route PATCH @{paused=$paused})
    'Перенесено: '+$Destination
}
# Changing the base moves every server folder lying directly in the previous base.
function Set-DiskBase([string]$Path) {
    $new=[IO.Path]::GetFullPath($Path).TrimEnd('\','/');$saved=Join-Path $script:DiskHome 'base.txt'
    $old=@('C:\work');if(Test-Path -LiteralPath $saved){$old=@([IO.File]::ReadAllText($saved).Trim())} # C:\work was the earlier default
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
}

$selective=Join-Path $PSScriptRoot 'Disk.Selective.ps1';if(Test-Path -LiteralPath $selective){. $selective}
