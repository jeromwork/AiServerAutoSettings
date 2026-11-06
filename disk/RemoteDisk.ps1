#requires -Version 5.1
[CmdletBinding()]
param([string]$Profile,[string]$Command='show',[string]$Path,[switch]$LibraryOnly)
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'

function Get-DiskIgnores {
    # server-sync.py DENIED + DENIED_EXT. Case-insensitive on both platforms.
    $names=@('.env*','env.example','.npmrc','.pypirc','.netrc','auth.json','*credential*','*token*','*secret*','*private*','id_*','.git','.tools','ssh','.ssh','.codex','.claude','node_modules','vendor','deps','dependencies','.gradle','.next','.cache','.stversions','.stfolder','.stignore','build','dist','target','obj','bin','.dart_tool','.nuxt','.output','.turbo','.cxx','coverage','logs','log','cache','caches','db','database','databases','backup','backups','*backup*','*dump*','uploads','upload','storage','android-sdk','.idea','.vscode','local.properties','google-services*.json','GoogleService-Info.plist','config.php','*.pem','*.key','*.keystore','*.jks','*.p8','*.p12','*.pfx','*.sqlite','*.sqlite3','*.db','*.db3','*.bak','*.backup','*.dump','*.log','*.zip','*.tar','*.gz','*.exe','*.dll','*.so','*.bin')
    @($names | ForEach-Object { '(?i)'+$_ })
}
function New-DiskFolder($Id,$LocalPath,$LocalId,$PeerId) {
    @{id=$Id;label=$Id;path=$LocalPath;type='sendreceive';paused=$true;rescanIntervalS=60;fsWatcherEnabled=$true;devices=@(@{deviceID=$LocalId},@{deviceID=$PeerId});versioning=@{type='simple';params=@{keep='2147483647';cleanoutDays='30'};cleanupIntervalS=3600}}
}
function Get-DiskStatus($Connected,$Paused,$Db,$Conflicts) {
    if(-not $Connected){return 'offline'}
    if($Paused){return 'paused'}
    if($Conflicts){return 'conflict'}
    if($Db.pullErrors -gt 0 -or $Db.state -eq 'error'){return 'error'}
    if($Db.state -ne 'idle' -or $Db.needTotalItems -gt 0){return 'syncing'}
    'synced'
}
function Quote-Native([string]$Value) {
    '"'+([regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1'))+'"'
}
function Protect-DiskText([string]$Text) {
    # Never log profile contents, commands, stdout, REST bodies or arbitrary exception messages.
    $Text=[regex]::Replace($Text,'(?i)(api.?key|token|password|secret)([=: ]+)[^\s,;]+','$1$2[redacted]')
    foreach($k in @($script:LocalKey,$script:RemoteKey)){if($k){$Text=$Text.Replace($k,'[redacted]')}}
    $Text
}
function Get-DiskRelative([string]$Root,[string]$Item) {
    $r=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $p=[IO.Path]::GetFullPath($Item)
    if(-not $p.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)){throw 'Item is outside folder'}
    $v=$p.Substring($r.Length).Replace('\','/')
    if($v -match '[\r\n*?{}!#\[\]]'){throw 'Unsupported ignore characters'}
    $v
}
function Write-DiskLog([string]$Stage,[string]$Message='',[long]$Duration=0) {
    $row=@{time=[DateTime]::UtcNow.ToString('o');stage=$Stage;durationMs=$Duration;hostId=$script:HostName;message=(Protect-DiskText $Message)} | ConvertTo-Json -Compress
    [IO.File]::AppendAllText($script:LogFile,$row+"`n",(New-Object Text.UTF8Encoding($false)))
}
function Save-DiskConfig {
    $temp=$script:ConfigFile+'.tmp'
    [IO.File]::WriteAllText($temp,($script:Config|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $script:ConfigFile -Force
}
function Select-DiskProfile {
    if($Profile){$files=@(Get-Item -LiteralPath $Profile)}else{
        $files=@(Get-ChildItem -Path "$env:LOCALAPPDATA\RemoteAgents\ssh-profiles\*\project-connections\*\ssh-transport.json" -File)
    }
    if($files.Count -eq 0){throw 'SSH profile not found; use -Profile path'}
    if($files.Count -gt 1){
        $form=New-Object Windows.Forms.Form;$form.Text='Выберите SSH-профиль';$form.Width=850;$form.Height=240
        $list=New-Object Windows.Forms.ListBox;$list.Dock='Fill'
        foreach($f in $files){[void]$list.Items.Add($f.FullName)}
        $ok=New-Object Windows.Forms.Button;$ok.Text='Выбрать';$ok.Dock='Bottom';$ok.DialogResult='OK'
        $form.Controls.Add($list);$form.Controls.Add($ok);$form.AcceptButton=$ok
        if($form.ShowDialog() -ne 'OK' -or $list.SelectedIndex -lt 0){throw 'Profile selection cancelled'}
        $files=@($files[$list.SelectedIndex]);$form.Dispose()
    }
    $script:ProfileFile=$files[0].FullName
    $c=Get-Content -LiteralPath $script:ProfileFile -Raw|ConvertFrom-Json
    foreach($field in @('keyPath','knownHostsPath','configPath','serverAddress','login','sshExecutable','arguments')){
        if(-not $c.$field){throw "Missing SSH field: $field"}
    }
    # arguments already contains destination and the working fallback route.
    if(@($c.arguments)[-1] -ne $c.serverAddress){throw 'Unsupported profile arguments: destination must be last'}
    $script:Connection=$c
}
# This script has CRLF on Windows; bash treats a stray CR as part of the command.
function Convert-DiskRemoteText([string]$Text) { $Text.Replace("`r`n","`n").Replace("`r","`n") }
function Start-DiskSsh([string]$RemoteCommand,[string]$InputText='', [string[]]$Extra=@(),[switch]$KeepOpen) {
    $RemoteCommand=Convert-DiskRemoteText $RemoteCommand;$InputText=Convert-DiskRemoteText $InputText
    $c=$script:Connection
    $base=@($c.arguments)
    $args=@('-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=3')+ $Extra + $base + @($RemoteCommand)
    $si=New-Object Diagnostics.ProcessStartInfo
    $si.FileName=$c.sshExecutable;$si.Arguments=(@($args|ForEach-Object {Quote-Native ([string]$_)}) -join ' ')
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true
    $si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    $p=New-Object Diagnostics.Process;$p.StartInfo=$si
    [void]$p.Start()
    $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
    if($InputText){$p.StandardInput.Write($InputText.Replace("`r`n","`n"))};if(-not $KeepOpen){$p.StandardInput.Close()}
    Write-DiskLog 'ssh.start' ('pid='+$p.Id)
    @{p=$p;out=$out;err=$err;started=[DateTime]::UtcNow}
}
function Complete-DiskSsh($Job,[int]$Timeout=30) {
    if(-not $Job.p.WaitForExit($Timeout*1000)){$Job.p.Kill();$Job.p.WaitForExit();Write-DiskLog 'ssh.timeout';throw 'SSH timeout'}
    $stderr=Protect-DiskText $Job.err.Result
    Write-DiskLog 'ssh.exit' ('code='+$Job.p.ExitCode+' stderr='+$stderr) ([long]([DateTime]::UtcNow-$Job.started).TotalMilliseconds)
    if($Job.p.ExitCode -ne 0){throw 'SSH failed; inspect journal'}
    $Job.out.Result
}
function Send-DiskLogs([switch]$DrainOnly,[switch]$First) {
    if($script:Upload){
        if(-not $script:Upload.p.HasExited){
            if(([DateTime]::UtcNow-$script:Upload.started).TotalSeconds -gt 15){$script:Upload.p.Kill()}
            return
        }
        try{[void](Complete-DiskSsh $script:Upload 1);Move-Item -LiteralPath $script:Pending -Destination (Join-Path $script:Sent ([IO.Path]::GetFileName($script:Pending))) -Force}catch{}
        $script:Upload=$null
        Get-ChildItem -LiteralPath $script:Sent -Filter '*.jsonl' | Where-Object {$_.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-30)} | Remove-Item -Force
    }
    if($DrainOnly -or -not $script:Connection){return}
    # Immutable batch, atomic remote replace: retries cannot duplicate or lose a batch.
    $pending=@(Get-ChildItem -LiteralPath $script:Queue -Filter '*.jsonl'|Sort-Object Name|Select-Object -First 1)
    if($First -or -not $pending.Count){
        $script:Pending=Join-Path $script:Queue (([guid]::NewGuid().ToString('N'))+'.jsonl')
        Copy-Item -LiteralPath $script:LogFile -Destination $script:Pending
        # Rotate active journal only after the durable copy exists.
        [IO.File]::WriteAllText($script:LogFile,'')
    }else{$script:Pending=$pending[0].FullName}
    $name=[IO.Path]::GetFileName($script:Pending)
    $remote='umask 077; d="$HOME/.local/share/remote-disk/logs/'+$script:HostName+'"; mkdir -p "$d" && cat > "$d/'+$name+'.tmp" && mv "$d/'+$name+'.tmp" "$d/'+$name+'"'
    $script:Upload=Start-DiskSsh $remote ([IO.File]::ReadAllText($script:Pending))
}
function Start-DiskLogWorker {
    # A separate PowerShell worker keeps delivery alive during downloads/bootstrap/UI stalls.
    $script:LogWorker=Start-Job -ArgumentList $PSCommandPath,$script:Connection,$script:DiskHome,$script:HostName,$script:LogFile -ScriptBlock {
        param($Source,$Connection,$DiskHome,$HostName,$MainLog)
        . $Source -LibraryOnly
        $script:Connection=$Connection;$script:DiskHome=$DiskHome;$script:HostName=$HostName
        $script:LocalKey='';$script:RemoteKey=''
        $script:Queue=Join-Path $DiskHome 'logs\queue'
        $script:LogFile=Join-Path $DiskHome 'logs\delivery.jsonl'
        while($true){
            try{
                # Atomic remote replacement makes whole-session retries idempotent.
                foreach($f in @(Get-ChildItem (Join-Path $DiskHome 'logs') -Filter '*.jsonl')){
                    if($f.Length){Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $script:Queue $f.Name) -Force}
                }
                foreach($f in @(Get-ChildItem $script:Queue -Filter '*.jsonl'|Sort-Object LastWriteTimeUtc)){
                    try{
                        $remote='umask 077; d="$HOME/.local/share/remote-disk/logs/'+$HostName+'"; mkdir -p "$d" && cat > "$d/'+$f.Name+'.tmp" && mv "$d/'+$f.Name+'.tmp" "$d/'+$f.Name+'"'
                        [void](Complete-DiskSsh (Start-DiskSsh $remote ([IO.File]::ReadAllText($f.FullName))) 15)
                        Remove-Item -LiteralPath $f.FullName
                    }catch{Write-DiskLog 'delivery.retry';break}
                }
            }catch{Write-DiskLog 'delivery.error' $_.Exception.GetType().Name}
            Start-Sleep -Seconds 30
        }
    }
}
function Invoke-DiskApi([string]$Side,[string]$Route,[string]$Method='GET',$Body=$null) {
    $port=$script:Config.gui;$key=$script:LocalKey
    if($Side -eq 'remote'){$port=$script:Config.remoteGui;$key=$script:RemoteKey}
    $params=@{Uri="http://127.0.0.1:$port/rest/$Route";Headers=@{'X-API-Key'=$key};Method=$Method;TimeoutSec=4;UseBasicParsing=$true}
    if($null -ne $Body){$params.Body=ConvertTo-Json -InputObject $Body -Depth 30 -Compress;$params.ContentType='application/json; charset=utf-8'}
    $r=Invoke-WebRequest @params
    if($r.Content){$r.Content|ConvertFrom-Json}
}
function Get-FreeDiskPort {
    $s=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$s.Start();$v=$s.LocalEndpoint.Port;$s.Stop();$v
}
function Initialize-DiskLocal {
    $binary=Join-Path $script:DiskHome 'bin\syncthing.exe'
    if(-not (Test-Path -LiteralPath $binary)){
        Write-DiskLog 'install.download'
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        $zip=Join-Path $script:DiskHome 'syncthing.zip'
        Invoke-WebRequest 'https://github.com/syncthing/syncthing/releases/download/v2.1.7/syncthing-windows-amd64-v2.1.7.zip' -OutFile $zip -UseBasicParsing
        if((Get-FileHash $zip -Algorithm SHA256).Hash -ne '3CE7DA770F546A8D02B65B2E7EE31F2A3B8B7C3F990EDE045590CCA4172ECFE1'){throw 'SHA256 mismatch'}
        $extract=Join-Path $script:DiskHome 'extract';Expand-Archive $zip $extract -Force
        [void](New-Item -ItemType Directory -Path (Split-Path $binary) -Force)
        Move-Item (Join-Path $extract 'syncthing-windows-amd64-v2.1.7\syncthing.exe') $binary -Force
    }
    $state=Join-Path $script:DiskHome 'state';$xmlPath=Join-Path $state 'config.xml'
    if(-not (Test-Path $xmlPath)){
        & $binary generate --home $state --no-port-probing *> $null
        if($LASTEXITCODE){throw 'Syncthing generate failed'}
        [xml]$xml=Get-Content $xmlPath
        foreach($f in @($xml.configuration.folder)){[void]$xml.configuration.RemoveChild($f)}
        $opt=$xml.configuration.options
        foreach($n in @('globalAnnounceEnabled','localAnnounceEnabled','relaysEnabled','natEnabled','startBrowser','crashReportingEnabled')){$opt.$n='false'}
        $opt.autoUpgradeIntervalH='0';$opt.urAccepted='-1';$opt.listenAddress="tcp://127.0.0.1:$($script:Config.listen)"
        $xml.configuration.gui.address="127.0.0.1:$($script:Config.gui)";$xml.Save($xmlPath)
    }
    [xml]$xml=Get-Content $xmlPath;$script:LocalKey=[string]$xml.configuration.gui.apikey
    try{[void](Invoke-DiskApi local 'system/ping');return}catch{}
    $script:Engine=Start-Process $binary -ArgumentList @('serve','--home',(Quote-Native $state),'--no-browser','--no-restart','--no-upgrade') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $script:DiskHome 'syncthing.stdout.log') -RedirectStandardError (Join-Path $script:DiskHome 'syncthing.stderr.log')
    for($i=0;$i -lt 60;$i++){try{[void](Invoke-DiskApi local 'system/ping');Write-DiskLog 'syncthing.ready';return}catch{Start-Sleep -Milliseconds 200}}
    throw 'Local Syncthing unavailable'
}
function Initialize-DiskRemote {
    $scriptText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'server-disk.sh'))
    $cmd='set -eu; umask 077; mkdir -p "$HOME/.local/share/remote-disk"; cat > "$HOME/.local/share/remote-disk/server-disk.sh"; bash "$HOME/.local/share/remote-disk/server-disk.sh" bootstrap'
    $r=(Complete-DiskSsh (Start-DiskSsh $cmd $scriptText) 120)|ConvertFrom-Json
    $script:RemoteKey=$r.apiKey;$script:Remote=$r
}
function Start-DiskTunnel {
    $c=$script:Config;$r=$script:Remote
    $extra=@('-o','ExitOnForwardFailure=yes','-L',"127.0.0.1:$($c.forward):127.0.0.1:$($r.listen)",'-L',"127.0.0.1:$($c.remoteGui):127.0.0.1:$($r.gui)",'-R',"127.0.0.1:$($r.reverse):127.0.0.1:$($c.listen)")
    $script:Tunnel=Start-DiskSsh 'cat >/dev/null' '' $extra -KeepOpen
    # stdin must remain open for long-lived tunnel.
}
function Connect-DiskDevices {
    $l=Invoke-DiskApi local 'system/status';$r=Invoke-DiskApi remote 'system/status'
    $script:LocalId=$l.myID;$script:PeerId=$r.myID
    foreach($side in @('local','remote')){
        $id=$script:PeerId;$port=$script:Config.forward
        if($side -eq 'remote'){$id=$script:LocalId;$port=$script:Remote.reverse}
        [void](Invoke-DiskApi $side "config/devices/$id" 'PUT' @{deviceID=$id;name='RemoteDisk';addresses=@("tcp://127.0.0.1:$port");autoAcceptFolders=$false})
    }
}
function Set-DiskPause($Folder,[int]$Minutes) {
    $paused=$Minutes -ne 0
    [void](Invoke-DiskApi local ('config/folders/'+$Folder.id) PATCH @{paused=$paused})
    $Folder.paused=$paused;$Folder.resumeAt=''
    if($Minutes -gt 0){$Folder.resumeAt=[DateTime]::UtcNow.AddMinutes($Minutes).ToString('o')}
    Save-DiskConfig;if($script:Config.contextMenu){Set-DiskContext $true};Write-DiskLog 'folder.pause' ("id="+$Folder.id+" paused="+$paused)
}
function Add-DiskFolder([string]$FolderPath) {
    if(-not $FolderPath){$d=New-Object Windows.Forms.FolderBrowserDialog;if($d.ShowDialog() -ne 'OK'){return};$FolderPath=$d.SelectedPath;$d.Dispose()}
    $FolderPath=[IO.Path]::GetFullPath($FolderPath).TrimEnd('\')
    if(-not (Test-Path -LiteralPath $FolderPath -PathType Container)){throw 'Folder missing'}
    foreach($f in $script:Config.folders){
        if($FolderPath -eq $f.path -or $FolderPath.StartsWith($f.path+'\',[StringComparison]::OrdinalIgnoreCase) -or $f.path.StartsWith($FolderPath+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Folder already connected or overlaps'}
    }
    if((Get-Item -LiteralPath $FolderPath).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse point refused'}
    $id='disk-'+[guid]::NewGuid().ToString('N')
    # Unique server folder per attachment avoids a previously indexed folder deleting initial files.
    $name=Split-Path $FolderPath -Leaf;$name=[regex]::Replace($name,'[^A-Za-z0-9_-]','_')
    if($name -notmatch '^[A-Za-z0-9]'){$name='folder'+$name};$name=$name.Substring(0,[Math]::Min(25,$name.Length))+'-'+$id.Substring(5,12)
    $b64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($name))
    $remote=(Complete-DiskSsh (Start-DiskSsh ('bash "$HOME/.local/share/remote-disk/server-disk.sh" mkdir '+$b64)))|ConvertFrom-Json
    # Existing custom rules may unignore secrets. Refuse rather than overwrite them.
    if(Test-Path -LiteralPath (Join-Path $FolderPath '.stignore')){throw 'Existing .stignore: select another folder or review/remove it manually'}
    $ignore=Get-DiskIgnores
    [IO.File]::WriteAllLines((Join-Path $FolderPath '.stignore'),$ignore,(New-Object Text.UTF8Encoding($false)))
    $lf=New-DiskFolder $id $FolderPath $script:LocalId $script:PeerId
    $rf=New-DiskFolder $id $remote.path $script:PeerId $script:LocalId
    [void](Invoke-DiskApi local "config/folders/$id" PUT $lf)
    [void](Invoke-DiskApi remote "config/folders/$id" PUT $rf)
    [void](Invoke-DiskApi remote "db/ignores?folder=$id" POST @{ignore=$ignore})
    # Verify both sides remain paused, have correct identities and retention before first resume.
    foreach($side in @('local','remote')){
        $f=Invoke-DiskApi $side "config/folders/$id"
        if(@($f.devices|Where-Object {$_.deviceID -in @($script:LocalId,$script:PeerId)}).Count -ne 2){throw 'Folder device verification failed'}
        $applied=Invoke-DiskApi $side "db/ignores?folder=$id"
        if((@($applied.ignore) -join "`n") -ne ($ignore -join "`n")){throw 'Folder ignore verification failed'}
        if(-not $f.paused -or $f.type -ne 'sendreceive' -or $f.versioning.type -ne 'simple' -or $f.versioning.params.cleanoutDays -ne '30'){throw 'Initial configuration verification failed; folder remains paused'}
    }
    $entry=[pscustomobject]@{id=$id;path=$FolderPath;remotePath=$remote.path;paused=$true;resumeAt='';excluded=@()}
    $script:Config.folders=@($script:Config.folders)+@($entry);Save-DiskConfig
    [void](Invoke-DiskApi remote "config/folders/$id" PATCH @{paused=$false});Set-DiskPause $entry 0
    if($script:Config.contextMenu){Set-DiskContext $true}
    Write-DiskLog 'folder.add' ('id='+$id)
}
function Set-DiskExclusion($Folder,[string]$Item,[bool]$Exclude) {
    $rel=Get-DiskRelative $Folder.path $Item
    $pattern='/'+$rel
    if($Exclude){$Folder.excluded=@($Folder.excluded)+@($pattern)|Select-Object -Unique}else{$Folder.excluded=@($Folder.excluded|Where-Object {$_ -ne $pattern})}
    # Per-side ignores: exclusion is local and never creates an unignore rule overriding protection.
    $rules=@(Get-DiskIgnores)+@($Folder.excluded)
    [void](Invoke-DiskApi local ('db/ignores?folder='+$Folder.id) POST @{ignore=$rules});Save-DiskConfig;if($script:Config.contextMenu){Set-DiskContext $true}
}
function Invoke-DiskCommand($Request) {
    try{
        $f=@($script:Config.folders|Where-Object {$Request.path -eq $_.path -or ($Request.path -and $Request.path.StartsWith($_.path+'\',[StringComparison]::OrdinalIgnoreCase))})|Select-Object -First 1
        switch($Request.command){
            'add' {Add-DiskFolder $Request.path}
            'pause' {if($f){Set-DiskPause $f -1}}
            'resume' {if($f){Set-DiskPause $f 0}}
            'exclude' {if($f){Set-DiskExclusion $f $Request.path $true}}
            'include' {if($f){Set-DiskExclusion $f $Request.path $false}}
            'disconnect' {if($f){
                if([Windows.Forms.MessageBox]::Show('Отключить папку? Файлы останутся на обеих сторонах.','RemoteDisk','YesNo') -ne 'Yes'){return}
                [void](Invoke-DiskApi remote ('config/folders/'+$f.id) DELETE)
                [void](Invoke-DiskApi local ('config/folders/'+$f.id) DELETE)
                $script:Config.folders=@($script:Config.folders|Where-Object {$_.id -ne $f.id});Save-DiskConfig
                if($script:Config.contextMenu){Set-DiskContext $true}
            }}
            default {[Windows.Forms.MessageBox]::Show($script:LastStatus,'RemoteDisk')|Out-Null}
        }
    }catch{Write-DiskLog 'command.error' $_.Exception.GetType().Name;[Windows.Forms.MessageBox]::Show('Операция не выполнена. Смотрите журнал.','RemoteDisk')|Out-Null}
}
function New-DiskPipe {
    $script:Pipe=New-Object IO.Pipes.NamedPipeServerStream($script:PipeName,[IO.Pipes.PipeDirection]::In,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous)
    $script:PipeWait=$script:Pipe.BeginWaitForConnection($null,$null)
}
function Set-DiskContext([bool]$Enabled) {
    foreach($type in @('Directory','*')){
        $base="HKCU:\Software\Classes\$type\shell"
        if(Test-Path $base){Get-ChildItem $base|Where-Object {$_.PSChildName -like 'RemoteDisk*'}|Remove-Item -Recurse -Force}
    }
    if($Enabled){
        $actions=@(@('add','Синхронизировать с сервером','Directory'))
        foreach($f in $script:Config.folders){
            foreach($a in @(@('show','Показать статус'),@('pause','Приостановить'),@('resume','Возобновить'),@('disconnect','Отключить с сохранением файлов'),@('exclude','Исключить'),@('include','Вернуть'))){
                if(($a[0] -eq 'pause' -and $f.paused) -or ($a[0] -eq 'resume' -and -not $f.paused)){continue}
                foreach($type in @('Directory','*')){if($type -eq '*' -and $a[0] -in @('pause','resume','disconnect')){continue};$actions+=,@($a[0],$a[1],$type,$f.path,$f.id)}
            }
        }
        foreach($a in $actions){
            $key='HKCU:\Software\Classes\'+$a[2]+'\shell\RemoteDisk_'+$a[0]
            if($a.Count -gt 3){$key+='_'+$a[4]}
            [void](New-Item $key -Force);Set-Item $key $a[1]
            if($a.Count -gt 3){
                $query='System.ItemPathDisplay:="'+$a[3]+'"'
                if($a[0] -in @('exclude','include')){
                    $query='System.ItemPathDisplay:~<"'+$a[3]+'\"'
                    $folder=@($script:Config.folders|Where-Object {$_.id -eq $a[4]})[0]
                    $excludedQueries=@($folder.excluded|ForEach-Object {'System.ItemPathDisplay:="'+$a[3]+'\'+$_.TrimStart('/').Replace('/','\')+'"'})
                    if($a[0] -eq 'include'){
                        if(-not $excludedQueries.Count){Remove-Item $key -Recurse -Force;continue}
                        $query='(' + ($excludedQueries -join ' OR ') + ')'
                    }elseif($excludedQueries.Count){$query+=' AND NOT ('+($excludedQueries -join ' OR ')+')'}
                }
                New-ItemProperty $key AppliesTo -Value $query -Force|Out-Null
            }
            if($a[0] -eq 'add' -and $script:Config.folders.Count){$query=(@($script:Config.folders|ForEach-Object {'NOT (System.ItemPathDisplay:="'+$_.path+'" OR System.ItemPathDisplay:~<"'+$_.path+'\")'}) -join ' AND ');New-ItemProperty $key AppliesTo -Value $query -Force|Out-Null}
            [void](New-Item ($key+'\command') -Force)
            $cmd='powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File '+(Quote-Native $PSCommandPath)+' -Profile '+(Quote-Native $script:ProfileFile)+' -Command '+$a[0]+' -Path "%1"'
            Set-Item ($key+'\command') $cmd
        }
    }
    $script:Config.contextMenu=$Enabled;Save-DiskConfig
}
function New-DiskIcon([string]$State) {
    $colors=@{synced='ForestGreen';syncing='DodgerBlue';paused='Goldenrod';offline='Gray';error='Red';conflict='DarkViolet'}
    $bmp=New-Object Drawing.Bitmap(32,32);$g=[Drawing.Graphics]::FromImage($bmp);$g.Clear([Drawing.Color]::Transparent)
    $brush=New-Object Drawing.SolidBrush([Drawing.Color]::FromName($colors[$State]));$g.FillEllipse($brush,2,2,28,28)
    $g.DrawString('D',(New-Object Drawing.Font('Arial',14,[Drawing.FontStyle]::Bold)),[Drawing.Brushes]::White,5,4)
    $handle=$bmp.GetHicon();$icon=[Drawing.Icon]::FromHandle($handle);$copy=$icon.Clone();[void][DiskNative]::DestroyIcon($handle)
    $g.Dispose();$bmp.Dispose();$brush.Dispose();$copy
}
function Add-DiskMenu($Menu,[string]$Text,[scriptblock]$Action) {
    $item=New-Object Windows.Forms.ToolStripMenuItem($Text);$item.add_Click($Action);[void]$Menu.Items.Add($item);$item
}
function Update-DiskState {
    $connected=$false;$lines=@();$states=@();$details=@()
    try{
        $con=Invoke-DiskApi local 'system/connections'
        if($script:PeerId){$peer=$con.connections.PSObject.Properties[$script:PeerId];$connected=($null -ne $peer -and $peer.Value.connected)}
        foreach($f in $script:Config.folders){
            if($f.paused -and $f.resumeAt -and [DateTime]::Parse($f.resumeAt).ToUniversalTime() -le [DateTime]::UtcNow){Set-DiskPause $f 0}
            $db=Invoke-DiskApi local ('db/status?folder='+$f.id)
            $conflicts=@(Get-ChildItem -LiteralPath $f.path -Filter '*.sync-conflict-*' -Recurse -File -ErrorAction SilentlyContinue)
            $state=Get-DiskStatus $connected $f.paused $db ($conflicts.Count -gt 0);$states+=$state
            $percent=100;if($db.globalBytes -gt 0){$percent=[Math]::Max(0,[Math]::Min(100,[Math]::Round(100*(1-$db.needBytes/$db.globalBytes))))}
            $line=(Split-Path $f.path -Leaf)+': '+$state
            if($state -eq 'syncing'){$line+=" $percent% ($($db.needBytes) байт осталось)"}
            $lines+=$line
            foreach($c in $conflicts){$details+='Конфликт: '+$c.FullName}
            if($db.pullErrors){$e=Invoke-DiskApi local ('folder/errors?folder='+$f.id);$details+=($e|ConvertTo-Json -Depth 8)}
        }
    }catch{$details+='API недоступен';$connected=$false}
    $state='synced'
    foreach($s in @('syncing','paused','conflict','error')){if($states -contains $s){$state=$s}}
    if(-not $connected){$state='offline'}
    $script:LastStatus=(@($state)+$lines+$details)-join "`r`n"
    if($script:PreviousState -ne $state){Write-DiskLog 'syncthing.state' $state;$script:PreviousState=$state}
    $old=$script:Tray.Icon;$script:Tray.Icon=New-DiskIcon $state;if($old){$old.Dispose()}
    $script:Tray.Text=('RemoteDisk '+($lines -join '; ')+' '+$state).Substring(0,[Math]::Min(63,('RemoteDisk '+($lines -join '; ')+' '+$state).Length))
    $script:FolderMenu.DropDownItems.Clear()
    foreach($folder in $script:Config.folders){
        $node=New-Object Windows.Forms.ToolStripMenuItem((Split-Path $folder.path -Leaf))
        $pathToOpen=$folder.path;$entry=$folder
        $item=New-Object Windows.Forms.ToolStripMenuItem('Открыть папку');$item.Tag=$pathToOpen;$item.add_Click({param($sender,$event) Start-Process explorer.exe -ArgumentList (Quote-Native $sender.Tag)});[void]$node.DropDownItems.Add($item)
        foreach($pair in @(@('Пауза на 30 минут',30),@('Пауза на 2 часа',120),@('Пауза до включения',-1),@('Возобновить',0))){
            $minutes=$pair[1];$item=New-Object Windows.Forms.ToolStripMenuItem($pair[0]);$item.Tag=@($entry,$minutes);$item.add_Click({param($sender,$event) try{Set-DiskPause $sender.Tag[0] $sender.Tag[1]}catch{Write-DiskLog 'pause.error'}});[void]$node.DropDownItems.Add($item)
        }
        [void]$script:FolderMenu.DropDownItems.Add($node)
    }
    foreach($line in $lines){[void]$script:FolderMenu.DropDownItems.Add($line)}
}
function Start-DiskApp {
    $script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'
    $script:Queue=Join-Path $script:DiskHome 'logs\queue';[void](New-Item -ItemType Directory -Path $script:Queue -Force)
    $script:Sent=Join-Path $script:DiskHome 'logs\sent';[void](New-Item -ItemType Directory -Path $script:Sent -Force)
    $script:HostName=[regex]::Replace($env:COMPUTERNAME,'[^A-Za-z0-9_-]','_')
    $script:LogFile=Join-Path $script:DiskHome ('logs\session-'+[guid]::NewGuid().ToString('N')+'.jsonl')
    $script:LocalKey='';$script:RemoteKey='';$script:Connection=$null;$script:Upload=$null
    Write-DiskLog 'start' 'RemoteDisk starting'
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class DiskNative { [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h); }'

    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $script:PipeName='RemoteDisk-'+$sid
    $created=$false;$script:Mutex=New-Object Threading.Mutex($true,('Local\'+$script:PipeName),[ref]$created)
    if(-not $created){
        $client=New-Object IO.Pipes.NamedPipeClientStream('.', $script:PipeName,[IO.Pipes.PipeDirection]::Out)
        try{$client.Connect(4000);$writer=New-Object IO.StreamWriter($client);$writer.WriteLine((@{command=$Command;path=$Path}|ConvertTo-Json -Compress));$writer.Dispose()}finally{$client.Dispose()}
        return
    }
    Select-DiskProfile
    Write-DiskLog 'ssh.login' ('user='+$script:Connection.login)
    $script:ConfigFile=Join-Path $script:DiskHome 'config.json'
    # Legacy serverUser in config.json is ignored; commands use the SSH profile login.
    if(Test-Path $script:ConfigFile){$script:Config=Get-Content $script:ConfigFile -Raw|ConvertFrom-Json}else{
        $script:Config=[pscustomobject]@{schema=1;listen=(Get-FreeDiskPort);gui=(Get-FreeDiskPort);forward=(Get-FreeDiskPort);remoteGui=(Get-FreeDiskPort);folders=@();contextMenu=$false};Save-DiskConfig
    }
    Send-DiskLogs -First
    if($script:Upload){try{[void](Complete-DiskSsh $script:Upload 15);Move-Item $script:Pending (Join-Path $script:Sent ([IO.Path]::GetFileName($script:Pending))) -Force}catch{};$script:Upload=$null}
    Start-DiskLogWorker
    # Recover batches from prior sessions, including a crash before rotation.
    foreach($log in Get-ChildItem (Join-Path $script:DiskHome 'logs') -Filter 'session-*.jsonl'){
        if($log.FullName -ne $script:LogFile){Move-Item $log.FullName (Join-Path $script:Queue ($log.Name)) -Force}
    }
    $script:Tunnel=$null;$script:Engine=$null;$script:Remote=$null;$script:PeerId='';$script:PreviousState='';$script:LastStatus='Нет подключения'
    $script:Tray=New-Object Windows.Forms.NotifyIcon;$script:Tray.Icon=New-DiskIcon offline;$script:Tray.Text='RemoteDisk: нет подключения';$script:Tray.Visible=$true
    $menu=New-Object Windows.Forms.ContextMenuStrip
    $script:FolderMenu=Add-DiskMenu $menu 'Папки' {}
    [void](Add-DiskMenu $menu 'Добавить папку' {Invoke-DiskCommand @{command='add';path=''}})
    foreach($pair in @(@('Пауза на 30 минут',30),@('Пауза на 2 часа',120),@('Пауза до включения',-1),@('Возобновить',0))){
        $item=Add-DiskMenu $menu $pair[0] {param($sender,$event) foreach($f in $script:Config.folders){try{Set-DiskPause $f ([int]$sender.Tag)}catch{Write-DiskLog 'pause.error'}}};$item.Tag=$pair[1]
    }
    [void](Add-DiskMenu $menu 'Ошибки, конфликты и статус' {[Windows.Forms.MessageBox]::Show($script:LastStatus,'RemoteDisk')|Out-Null})
    foreach($f in $script:Config.folders){$folderPath=$f.path;$item=Add-DiskMenu $menu ('Открыть '+(Split-Path $folderPath -Leaf)) {param($sender,$event) Start-Process explorer.exe -ArgumentList (Quote-Native $sender.Tag)};$item.Tag=$folderPath}
    [void](Add-DiskMenu $menu 'Открыть журнал' {Start-Process explorer.exe (Quote-Native (Join-Path $script:DiskHome 'logs'))})
    [void](Add-DiskMenu $menu 'Собрать диагностику' {
        $target=Join-Path $script:DiskHome ('diagnostics-'+(Get-Date -Format yyyyMMdd-HHmmss)+'.zip')
        # Only redacted JSONL: no config.xml, profile, keys or Syncthing raw logs.
        Compress-Archive -Path (Join-Path $script:DiskHome 'logs\*') -DestinationPath $target -Force
        Start-Process explorer.exe -ArgumentList ('/select,'+(Quote-Native $target))
    })
    [void](Add-DiskMenu $menu 'Контекстное меню: включить / выключить' {Set-DiskContext (-not $script:Config.contextMenu)})
    [void](Add-DiskMenu $menu 'Автозапуск: включить / выключить' {
        $key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';[void](New-Item $key -Force)
        if(Get-ItemProperty $key -Name RemoteDisk -ErrorAction SilentlyContinue){Remove-ItemProperty $key RemoteDisk}else{
            New-ItemProperty $key RemoteDisk -Value ('powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File '+(Quote-Native $PSCommandPath)+' -Profile '+(Quote-Native $script:ProfileFile)) -Force|Out-Null
        }
    })
    [void](Add-DiskMenu $menu 'Выход' {$script:Context.ExitThread()})
    $script:Tray.ContextMenuStrip=$menu;$script:Tray.add_DoubleClick({[Windows.Forms.MessageBox]::Show($script:LastStatus,'RemoteDisk')|Out-Null})
    New-DiskPipe
    $script:LastUpload=[DateTime]::MinValue;$script:Retry=[DateTime]::MinValue;$script:LastTick=[DateTime]::UtcNow
    $power=Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName PowerModeChanged -SourceIdentifier 'RemoteDisk.Power' -ErrorAction SilentlyContinue
    $script:Context=New-Object Windows.Forms.ApplicationContext
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=4000
    $timer.add_Tick({
        try{
            $now=[DateTime]::UtcNow
            foreach($event in @(Get-Event -SourceIdentifier 'RemoteDisk.Power' -ErrorAction SilentlyContinue)){Write-DiskLog 'power' ([string]$event.SourceEventArgs.Mode);Remove-Event -EventIdentifier $event.EventIdentifier}
            if(($now-$script:LastTick).TotalSeconds -gt 20){Write-DiskLog 'power.resume' 'Timer gap detected'};$script:LastTick=$now
            if($script:PipeWait.IsCompleted){
                $script:Pipe.EndWaitForConnection($script:PipeWait)
                $reader=New-Object IO.StreamReader($script:Pipe);$read=$reader.ReadLineAsync()
                if($read.Wait(1000)){Invoke-DiskCommand ($read.Result|ConvertFrom-Json)}
                $reader.Dispose();$script:Pipe.Dispose();New-DiskPipe
            }
            if($script:Tunnel -and $script:Tunnel.p.HasExited){try{[void](Complete-DiskSsh $script:Tunnel 1)}catch{};$script:Tunnel=$null;$script:Retry=$now.AddSeconds(5)}
            if(-not $script:Tunnel -and $now -ge $script:Retry){
                $script:Retry=$now.AddSeconds(30)
                try{
                    $watch=[Diagnostics.Stopwatch]::StartNew()
                    try{$ips=[Net.Dns]::GetHostAddresses($script:Connection.serverAddress);Write-DiskLog 'dns' (($ips|ForEach-Object {$_.IPAddressToString}) -join ',') $watch.ElapsedMilliseconds}catch{Write-DiskLog 'dns.error' '' $watch.ElapsedMilliseconds}
                    $tcp=New-Object Net.Sockets.TcpClient;$tcpPort=22
                    $sshArgs=@($script:Connection.arguments);for($i=0;$i -lt $sshArgs.Count-1;$i++){if($sshArgs[$i] -eq '-p'){$tcpPort=[int]$sshArgs[$i+1]}}
                    try{$task=$tcp.ConnectAsync($script:Connection.serverAddress,$tcpPort);if(-not $task.Wait(1500)){throw 'timeout'};Write-DiskLog 'tcp' ("port=$tcpPort connected")}catch{Write-DiskLog 'tcp.error' ("port=$tcpPort (route may use a fallback)")}finally{$tcp.Dispose()}
                    Initialize-DiskRemote;Initialize-DiskLocal;Start-DiskTunnel
                    Start-Sleep -Milliseconds 600;Connect-DiskDevices
                    if($Command -eq 'add' -and $Path){Invoke-DiskCommand @{command='add';path=$Path};$Command='show'}
                }catch{Write-DiskLog 'initialize.error' $_.Exception.GetType().Name;if($script:Tunnel){try{$script:Tunnel.p.Kill()}catch{};$script:Tunnel=$null}}
            }
            Update-DiskState
        }catch{Write-DiskLog 'tick.error' $_.Exception.GetType().Name}
    })
    try{$timer.Start();[Windows.Forms.Application]::Run($script:Context)}finally{
        $timer.Stop();$timer.Dispose();Write-DiskLog 'exit'
        if($script:Tunnel){try{$script:Tunnel.p.Kill()}catch{}}
        try{[void](Invoke-DiskApi local 'system/shutdown' POST)}catch{}
        Stop-Job $script:LogWorker;Remove-Job $script:LogWorker;Send-DiskLogs;$script:Tray.Visible=$false;$script:Tray.Dispose();$script:Pipe.Dispose();$script:Mutex.ReleaseMutex();$script:Mutex.Dispose()
        Unregister-Event -SourceIdentifier 'RemoteDisk.Power' -ErrorAction SilentlyContinue
    }
}
if(-not $LibraryOnly){try{Start-DiskApp}catch{if($script:LogFile){Write-DiskLog 'fatal' $_.Exception.GetType().Name};throw}}
