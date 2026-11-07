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
function Invoke-DiskProcess($Exe,$Arguments,[string]$InputText='',[string]$OutputFile='') {
    $si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=$Exe;$si.Arguments=($Arguments|ForEach-Object {Quote-Disk ([string]$_)}) -join ' '
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true;$si.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
    $p=New-Object Diagnostics.Process;$p.StartInfo=$si;$file=$null
    try {[void]$p.Start();$err=$p.StandardError.ReadToEndAsync()
        if($OutputFile){$file=[IO.File]::Create($OutputFile);$out=$p.StandardOutput.BaseStream.CopyToAsync($file)}else{$out=$p.StandardOutput.ReadToEndAsync()}
        $bytes=[Text.Encoding]::UTF8.GetBytes($InputText.Replace("`r",''));$write=$p.StandardInput.BaseStream.WriteAsync($bytes,0,$bytes.Length)
        if(-not $write.Wait(15000)){throw 'Таймаут ввода'};$p.StandardInput.Close()
        if(-not $p.WaitForExit(45000)){$p.Kill();throw 'Таймаут команды'};$out.GetAwaiter().GetResult() | Out-Null
        if($p.ExitCode -ne 0){$reason='Внешняя команда не выполнена';if($p.ExitCode -eq 255 -and [IO.Path]::GetFileNameWithoutExtension($Exe) -ieq 'ssh'){$reason='Нет связи с сервером'}elseif($err.Result -match 'Чужой .stignore'){$reason='Чужой .stignore на сервере: сохраните и удалите его вручную'}elseif($err.Result -match 'требуется -Merge'){$reason='Обе папки непустые: требуется -Merge'};throw ($reason+' (код выхода '+$p.ExitCode+')')}
        if(-not $OutputFile){$out.Result.TrimStart([char]0xFEFF).Trim()}
    }finally{if($file){$file.Dispose()};if($p.Id -and -not $p.HasExited){$p.Kill()};$p.Dispose()}
}
function Read-DiskProfile([string]$Profile) {
    if(-not $Profile){$saved=Join-Path $script:DiskHome 'profile.txt';if(Test-Path -LiteralPath $saved){$Profile=[IO.File]::ReadAllText($saved)}}
    if(-not $Profile){$files=@(Get-ChildItem -Path "$env:LOCALAPPDATA/RemoteAgents/ssh-profiles/*/project-connections/*/ssh-transport.json" -File);if($files.Count -ne 1){throw 'Укажите -Profile: нужен один SSH-профиль'};$Profile=$files[0].FullName}
    $script:ProfilePath=[IO.Path]::GetFullPath($Profile);$script:Connection=[IO.File]::ReadAllText($script:ProfilePath)|ConvertFrom-Json
    foreach($f in @('sshExecutable','arguments','serverAddress','login','keyPath','knownHostsPath','configPath')){if(-not $script:Connection.$f){throw 'Неполный SSH-профиль'}}
    if($script:Connection.login.Trim() -ieq 'root'){throw 'SSH-профиль должен входить как рабочий пользователь, не root'}
}
function Invoke-DiskSsh($Command,[switch]$Direct,[string]$InputText='',[string]$OutputFile='') {
    $c=$script:Connection;$args=@('-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes')
    if($Direct){$args+=@($c.arguments)}else{$args+=@('-F','NUL','-p','2222','-i',$c.keyPath,'-o',('HostKeyAlias='+$c.serverAddress),'-o',('UserKnownHostsFile='+$c.knownHostsPath),'-o','IdentitiesOnly=yes',($c.login+'@127.0.0.1'))}
    Invoke-DiskProcess $c.sshExecutable ($args+@($Command)) $InputText $OutputFile
}
function Invoke-DiskServer($Action,$Data=$null,[switch]$Direct,[string]$OutputFile='') {
    $cmd='bash "$HOME/.local/share/remote-disk/server-disk.sh" '+$Action
    if($Data){$cmd+=' '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Data|ConvertTo-Json -Depth 20 -Compress)))}
    $text=Invoke-DiskSsh $cmd -Direct:$Direct -OutputFile $OutputFile
    if(-not $OutputFile -and $text){$value=$text|ConvertFrom-Json;if($null -ne $value){foreach($item in $value){$item}}}
}
function Invoke-DiskApi($Route,$Method='GET',$Body=$null) {
    $args=@{Uri=('http://'+$script:Gui+'/rest/'+$Route);Method=$Method;Headers=@{'X-API-Key'=$script:ApiKey};TimeoutSec=5;UseBasicParsing=$true}
    if($null -ne $Body){$args.Body=[Text.Encoding]::UTF8.GetBytes(($Body|ConvertTo-Json -Depth 30 -Compress));$args.ContentType='application/json'}
    try {$value=Invoke-RestMethod @args;foreach($item in $value){if($null -ne $item -and -not ($item -is [string] -and $item.Length -eq 0)){$item}}}catch{throw 'REST Syncthing недоступен'}
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
    if(Test-Path -LiteralPath $file){
        if([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::ReparsePoint){throw 'Ссылка .stignore запрещена'}
        $old=[IO.File]::ReadAllText($file)
        if([Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'stignore.txt')))){
            $normalized=($old.TrimEnd("`r","`n").Replace("`r`n","`n")+"`n");$sha=[Security.Cryptography.SHA256]::Create()
            try{$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
            if($hash -cnotin [IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'legacy-ignores.sha256'))){throw 'Чужой .stignore: сохраните и удалите его вручную перед подключением'}
        }
    }
    if($Write){if(Test-Path -LiteralPath $file){[IO.File]::SetAttributes($file,([IO.File]::GetAttributes($file) -band (-bnot [IO.FileAttributes]::Hidden)))};try{Write-DiskUtf8 $file $rules}finally{if(Test-Path -LiteralPath $file){[IO.File]::SetAttributes($file,([IO.File]::GetAttributes($file) -bor [IO.FileAttributes]::Hidden))}}}
}
