#requires -Version 5.1
[CmdletBinding()]
param([string]$Profile,[string]$Command='show',[string]$Path,[string]$Remote,[switch]$Merge,[ValidateRange(0,86400)][int]$Wait=0,[switch]$Install,[switch]$Uninstall,[switch]$LibraryOnly)
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$script:LastInitError=''
$script:ProfileFile='';$script:Tunnel=$null;$script:Safety=$null;$script:DiskHome=''
$script:RemoteState=$null;$script:EngineInstall=$null
$script:ServerJob=$null;$script:NextServerList=[DateTime]::MinValue;$script:ExitUnlock=$false;$script:PendingDisconnect=@();$script:ConflictScan=$null
. (Join-Path $PSScriptRoot 'DiskLock.ps1')

function Get-DiskIgnores {
    # server-sync.py DENIED + DENIED_EXT. Case-insensitive on both platforms.
    $names=@('.env*','env.example','.npmrc','.pypirc','.netrc','auth.json','*credential*','*token*','*secret*','*private*','id_*','.git','.tools','ssh','.ssh','.codex','.claude','node_modules','vendor','deps','dependencies','.gradle','.next','.cache','.stversions','.stfolder','.stignore','build','dist','target','obj','bin','.dart_tool','.nuxt','.output','.turbo','.cxx','coverage','logs','log','cache','caches','db','database','databases','backup','backups','*backup*','*dump*','uploads','upload','storage','android-sdk','.idea','.vscode','local.properties','google-services*.json','GoogleService-Info.plist','config.php','*.pem','*.key','*.keystore','*.jks','*.p8','*.p12','*.pfx','*.sqlite','*.sqlite3','*.db','*.db3','*.bak','*.backup','*.dump','*.log','*.zip','*.tar','*.gz','*.exe','*.dll','*.so','*.bin')
    @($names | ForEach-Object { '(?i)'+$_ })
}
function New-DiskFolder($Id,$LocalPath,$LocalId,$PeerId) {
    @{id=$Id;label=$Id;path=$LocalPath;type='sendreceive';paused=$true;rescanIntervalS=60;fsWatcherEnabled=$true;devices=@(@{deviceID=$LocalId},@{deviceID=$PeerId});versioning=@{type=''}}
}
function Get-DiskStatus($Connected,$Paused,$Db,$Conflicts) {
    if(-not $Connected){return 'offline'}
    if($Paused){return 'paused'}
    if($Conflicts){return 'conflict'}
    if($Db.state -eq 'error'){return 'error'}
    # pullErrors belongs to the last pull attempt; during a retry/conflict rename it is stale.
    if($Db.state -ne 'idle'){return 'syncing'}
    if($Db.pullErrors -gt 0){return 'error'}
    if($Db.needTotalItems -gt 0){return 'syncing'}
    'synced'
}
function Quote-Native([string]$Value) {
    '"'+([regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1'))+'"'
}
function Protect-DiskText([string]$Text) {
    # Redact known keys and named secrets before writing any diagnostic text.
    $Text=[regex]::Replace($Text,'(?i)([a-z][a-z0-9+.-]*://)[^/\s]*@','$1[redacted]@')
    $Text=[regex]::Replace($Text,'(?i)([?&](?:[^=\s&]+)=)[^&\s]+','$1[redacted]')
    $Text=[regex]::Replace($Text,'(?i)(api.?key|token|password|secret)([=: ]+)[^\s,;]+','$1$2[redacted]')
    foreach($k in @($script:LocalKey,$script:RemoteKey)){if($k){$Text=$Text.Replace($k,'[redacted]')}}
    $Text
}
function Test-DiskName([string]$Name) {
    if($Name.Length -lt 1 -or $Name.Length -gt 128 -or $Name -notmatch '^[\p{L}\p{N}_][\p{L}\p{N}_. -]*$' -or $Name.Contains('..') -or $Name -match '[ .]$' -or $Name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {throw 'Недопустимое имя серверной папки'}
    $Name
}
function Get-DiskFolderId([string]$Name) {
    $Name=Test-DiskName $Name;$sha=[Security.Cryptography.SHA256]::Create()
    try {'disk-'+([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('folder:'+$Name))).Replace('-','').ToLowerInvariant()).Substring(0,24)}finally{$sha.Dispose()}
}
function Get-DiskOrigin([string]$Value) {
    # Compare repository identity without transport, userinfo, .git, query or fragment.
    $Value=$Value.Trim()
    if($Value -match '^[a-z][a-z0-9+.-]*://') {
        try{$u=New-Object Uri($Value);$Value=$u.DnsSafeHost.ToLowerInvariant()+'/'+$u.AbsolutePath.Trim('/')}catch{return ''}
    }elseif($Value -match '^(?:[^/@:]+@)?([^/:]+):(.+)$'){$Value=$Matches[1].ToLowerInvariant()+'/'+$Matches[2]}
    $Value=($Value -split '[?#]',2)[0].TrimEnd('/') -replace '\.git$',''
    $Value
}
function Invoke-DiskGit([string]$FolderPath,[string[]]$Arguments) {
    $git=Get-Command git -ErrorAction SilentlyContinue;if(-not $git){return ''}
    # PS 5.1 treats native stderr as PowerShell errors even with 2>$null.
    $si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=$git.Source
    $si.Arguments=(@(@('-C',$FolderPath)+$Arguments|ForEach-Object {Quote-Native $_}) -join ' ')
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    $si.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
    $p=New-Object Diagnostics.Process;$p.StartInfo=$si
    try{[void]$p.Start();$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit(5000)){$p.Kill();$p.WaitForExit();throw 'Git metadata timeout'}
        if($p.ExitCode -eq 0){return (Convert-DiskRemoteText $out.Result).Trim()};return ''
    }finally{$p.Dispose()}
}
function Get-DiskLocalOrigin([string]$FolderPath) {
    Get-DiskOrigin (Invoke-DiskGit $FolderPath @('remote','get-url','origin'))
}
function Add-DiskGitExclude([string]$FolderPath) {
    $target=Invoke-DiskGit $FolderPath @('rev-parse','--git-path','info/exclude')
    if(-not $target){return}
    if(-not [IO.Path]::IsPathRooted($target)){$target=Join-Path $FolderPath $target}
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    $old='';if(Test-Path -LiteralPath $target){$old=[IO.File]::ReadAllText($target)}
    $lines=@((Convert-DiskRemoteText $old) -split "`n")
    $missing=@('.stignore','.stfolder','.stversions','*.sync-conflict-*'|Where-Object {$_ -cnotin $lines})
    if($missing.Count){$prefix='';if($old -and -not $old.EndsWith("`n")){$prefix="`n"};[IO.File]::AppendAllText($target,$prefix+($missing -join "`n")+"`n",(New-Object Text.UTF8Encoding($false)))}
}
function Test-DiskHasFiles([string]$FolderPath) {
    if(-not (Test-Path -LiteralPath $FolderPath)){return $false}
    @((Get-ChildItem -LiteralPath $FolderPath -Force)|Where-Object {$_.Name -notin @('.git','.stignore','.stfolder','.stversions')}).Count -gt 0
}
function Test-DiskIgnoreFile([string]$FolderPath) {
    $file=Join-Path $FolderPath '.stignore'
    if(Test-Path -LiteralPath $file){
        $old=@([IO.File]::ReadAllLines($file));$own=@(Get-DiskIgnores)
        if(($old -join "`n") -cne ($own -join "`n")){throw 'Existing .stignore: review/remove it manually'}
    }
}
function Invoke-DiskServer([string]$Action,$Data=$null) {
    $cmd='bash "$HOME/.local/share/remote-disk/server-disk.sh" '+$Action
    if($null -ne $Data){$cmd+=' '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Data|ConvertTo-Json -Depth 30 -Compress)))}
    $text=Convert-DiskRemoteText (Complete-DiskSsh (Start-DiskSsh $cmd))
    # Enumerate explicitly: ConvertFrom-Json in PS 5.1 returns an array as one object.
    $value=ConvertFrom-Json -InputObject $text;foreach($item in $value){$item}
}
function Get-DiskFolderName($Folder) {
    if($Folder.PSObject.Properties['name']){return $Folder.name}
    Split-Path $Folder.remotePath -Leaf
}
function Select-DiskRemote([string]$FolderPath,$Folders) {
    $name=Split-Path $FolderPath -Leaf;$origin=Get-DiskLocalOrigin $FolderPath
    $items=@($Folders|Where-Object {$null -ne $_});$selected=-1
    if($origin){for($i=0;$i -lt $items.Count;$i++){if($items[$i].origin -and (Get-DiskOrigin $items[$i].origin) -ceq $origin){$selected=$i;break}}}
    if($selected -lt 0){for($i=0;$i -lt $items.Count;$i++){if($items[$i].name -ceq $name){$selected=$i;break}}}
    $form=New-Object Windows.Forms.Form;$form.Text='Серверная папка';$form.Width=860;$form.Height=400
    $list=New-Object Windows.Forms.ListBox;$list.Dock='Fill'
    foreach($f in $items){[void]$list.Items.Add(($f.name+' | '+$f.branch+' | '+$f.origin+$(if($f.worktree){' | worktree'})))}
    [void]$list.Items.Add('Создать новую: '+$name)
    if($selected -lt 0){$selected=$items.Count};$list.SelectedIndex=$selected
    $warning=New-Object Windows.Forms.Label;$warning.Dock='Top';$warning.Height=45;$warning.Text='Если обе папки непустые, файлы могут смешаться. Перед подключением потребуется подтверждение.'
    $ok=New-Object Windows.Forms.Button;$ok.Text='Подключить';$ok.Dock='Bottom';$ok.DialogResult='OK'
    $form.Controls.Add($list);$form.Controls.Add($warning);$form.Controls.Add($ok);$form.AcceptButton=$ok
    try{if($form.ShowDialog() -ne 'OK'){return ''};if($list.SelectedIndex -lt $items.Count){return $items[$list.SelectedIndex].name};return (Test-DiskName $name)}finally{$form.Dispose()}
}
function Wait-DiskTunnel([int]$Seconds=8) {
    $deadline=[DateTime]::UtcNow.AddSeconds($Seconds)
    do{
        if($script:Tunnel.p.HasExited){throw 'SSH tunnel exited before forwarding became ready'}
        try{[void](Invoke-DiskApi remote 'system/ping');return}catch{}
        Start-Sleep -Milliseconds 150
    }while([DateTime]::UtcNow -lt $deadline)
    throw 'SSH forwarding readiness timeout'
}
function Get-DiskSnapshot([string]$RemoteName='') {
    $folders=@($script:Config.folders|Where-Object {-not $RemoteName -or (Get-DiskFolderName $_) -ceq $RemoteName})
    $con=$null;$localFolders=@();$localOk=$false;$stats=$null
    try{$con=Invoke-DiskApi local 'system/connections';$localFolders=@(Invoke-DiskApi local 'config/folders');$stats=Invoke-DiskApi local 'stats/folder';$localOk=$true}catch{}
    $metadata=@();if($script:DiskHome){$metadata=@(Read-DiskJson (Join-Path $script:DiskHome 'server-folders.json'))}
    foreach($f in $folders){
        $name=Get-DiskFolderName $f;$connected=$false;$state='offline';$bytes=$null;$files=$null;$last=$null;$message=''
        try{
            if(-not $localOk){throw 'Local Syncthing unavailable'}
            $actual=@($localFolders|Where-Object {$_.id -eq $f.id})|Select-Object -First 1
            if(-not $actual){throw 'Folder missing in local Syncthing'}
            $peerId=''
            if($script:Config.PSObject.Properties['serverId']){$peerId=$script:Config.serverId}
            if(-not $peerId){$me=(Invoke-DiskApi local 'system/status').myID;$peerId=@($actual.devices|Where-Object {$_.deviceID -ne $me}|ForEach-Object {$_.deviceID})|Select-Object -First 1}
            $peer=$con.connections.PSObject.Properties[$peerId]
            $connected=$null -ne $peer -and $peer.Value.connected
            $db=Invoke-DiskApi local ('db/status?folder='+$f.id)
            $bytes=[long]$db.needBytes;$files=[long]$db.needFiles+[long]$db.needDirectories+[long]$db.needDeletes
            $hasConflicts=$false;$conflictsKnown=$true
            if($script:Safety){
                $scan=Read-DiskJson (Join-Path $script:DiskHome 'conflict-scan.json')
                if($scan -and $scan.error){throw ('Conflict scan: '+$scan.error)}
                $item=$null;if($scan){$item=@($scan.folders|Where-Object {$_.id -eq $f.id})|Select-Object -First 1}
                $conflictsKnown=$null -ne $item;if($item){$hasConflicts=$item.conflict}
            }else{$hasConflicts=@(Get-ChildItem -LiteralPath $f.path -Filter '*.sync-conflict-*' -Recurse -Force -File -ErrorAction Stop).Count -gt 0}
            $state=Get-DiskStatus $connected $actual.paused $db $hasConflicts
            if($state -eq 'synced' -and -not $conflictsKnown){$state='syncing'}
            if($connected -and -not $actual.paused){
                $completion=Invoke-DiskApi local ('db/completion?folder='+$f.id+'&device='+$peerId)
                $bytes+=[long]$completion.needBytes;$files+=[long]$completion.needItems+[long]$completion.needDeletes
                if($state -eq 'synced' -and ($bytes -gt 0 -or $files -gt 0 -or $completion.completion -lt 100)){$state='syncing'}
            }
            $stat=$stats.PSObject.Properties[$f.id]
            if($null -ne $stat -and $stat.Value.PSObject.Properties['lastFile']){$last=$stat.Value.lastFile.at}
            if($state -eq 'synced'){$last=$db.stateChanged}
        }catch{$message=Protect-DiskText $_.Exception.Message;if($connected){$state='error'}else{$state='offline'}}
        $lockInfo=[pscustomobject]@{locked=$null;error=''};if($script:DiskHome){$lockInfo=Get-DiskLockInfo $script:DiskHome $f}
        if($lockInfo.error){$state='error';$message='ACL: '+$lockInfo.error}
        if($script:DiskHome -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){
            $safety=Read-DiskJson (Join-Path $script:DiskHome 'safety-state.json')
            if($safety -and $safety.PSObject.Properties['error'] -and $safety.error){$state='error';$message='ACL controller: '+$safety.error}
        }
        $meta=@($metadata|Where-Object {$_.name -ceq $name})|Select-Object -First 1
        $dirty=$null;$unpushed=$null
        if($meta -and $meta.PSObject.Properties['uncommittedFiles']){$dirty=$meta.uncommittedFiles;$unpushed=$meta.unpushedCommits}
        [pscustomobject]@{name=$name;path=$f.path;state=$state;locked=$lockInfo.locked;uncommittedFiles=$dirty;unpushedCommits=$unpushed;remainingBytes=$bytes;remainingFiles=$files;lastSync=$last;serverConnected=$connected;message=$message}
    }
}
function Get-DiskStatusExitCode($Rows) {
    if(@($Rows).Count -eq 0 -or @($Rows|Where-Object {$_.state -ne 'synced' -or -not $_.serverConnected -or ($_.PSObject.Properties['locked'] -and $_.locked)}).Count){return 1};0
}
function Invoke-DiskStatus([string]$RemoteName,[int]$Seconds=0) {
    $deadline=[DateTime]::UtcNow.AddSeconds($Seconds)
    do{
        $rows=@(Get-DiskSnapshot $RemoteName);$code=Get-DiskStatusExitCode $rows
        if($code -eq 0 -or [DateTime]::UtcNow -ge $deadline){break}
        Start-Sleep -Milliseconds 400
    }while($true)
    ConvertTo-Json -InputObject $rows -Depth 8
    $script:StatusExitCode=$code
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
    if(-not $Profile -and $script:Config.PSObject.Properties['profile']){$Profile=$script:Config.profile}
    if($Profile){$files=@(Get-Item -LiteralPath $Profile)}else{
        $files=@(Get-ChildItem -Path "$env:LOCALAPPDATA\RemoteAgents\ssh-profiles\*\project-connections\*\ssh-transport.json" -File)
    }
    if($files.Count -eq 0){throw 'SSH profile not found; use -Profile path'}
    if($files.Count -gt 1){
        if($Command -eq 'add' -and $Remote){throw 'Несколько SSH-профилей: передайте -Profile. Диалоги отключены с -Remote.'}
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
    $script:Config|Add-Member -NotePropertyName profile -NotePropertyValue $script:ProfileFile -Force
}
# This script has CRLF on Windows; bash treats a stray CR as part of the command.
function Convert-DiskRemoteText([string]$Text) { $Text.TrimStart([char]0xFEFF).Replace("`r`n","`n").Replace("`r","`n") }
function Start-DiskSsh([string]$RemoteCommand,[string]$InputText='', [string[]]$Extra=@(),[switch]$KeepOpen) {
    $RemoteCommand=Convert-DiskRemoteText $RemoteCommand;$InputText=Convert-DiskRemoteText $InputText
    $c=$script:Connection
    $base=@($c.arguments)
    if ($Extra.Count -gt 0) {
        $base=@(for($i=0;$i -lt $base.Count;$i++) {
            if ($base[$i] -ieq '-o' -and $i+1 -lt $base.Count -and $base[$i+1] -ieq 'ClearAllForwardings=yes') {$i++;continue}
            $base[$i]
        })
    }
    $args=@('-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=3')+ $Extra + $base + @($RemoteCommand)
    $si=New-Object Diagnostics.ProcessStartInfo
    $si.FileName=$c.sshExecutable;$si.Arguments=(@($args|ForEach-Object {Quote-Native ([string]$_)}) -join ' ')
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true
    $si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    $p=New-Object Diagnostics.Process;$p.StartInfo=$si
    [void]$p.Start()
    $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
    if($InputText){
        $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($InputText)
        $p.StandardInput.BaseStream.Write($bytes,0,$bytes.Length)
        $p.StandardInput.BaseStream.Flush()
    }
    if(-not $KeepOpen){$p.StandardInput.Close()}
    Write-DiskLog 'ssh.start' ('pid='+$p.Id)
    @{p=$p;out=$out;err=$err;started=[DateTime]::UtcNow}
}
function Complete-DiskSsh($Job,[int]$Timeout=30) {
    if(-not $Job.p.WaitForExit($Timeout*1000)){$Job.p.Kill();$Job.p.WaitForExit();Write-DiskLog 'ssh.timeout';throw 'SSH timeout'}
    $stderr=Protect-DiskText $Job.err.Result
    Write-DiskLog 'ssh.exit' ('code='+$Job.p.ExitCode+' stderr='+$stderr) ([long]([DateTime]::UtcNow-$Job.started).TotalMilliseconds)
    if($Job.p.ExitCode -ne 0){throw 'SSH failed; inspect journal'}
    Convert-DiskRemoteText $Job.out.Result
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
        param($WorkerSource,$WorkerConnection,$WorkerHome,$WorkerHost,$WorkerMainLog)
        . $WorkerSource -LibraryOnly
        $script:Connection=$WorkerConnection;$script:DiskHome=$WorkerHome;$script:HostName=$WorkerHost
        $script:LocalKey='';$script:RemoteKey=''
        $script:Queue=Join-Path $WorkerHome 'logs\queue'
        $script:LogFile=Join-Path $WorkerHome 'logs\delivery.jsonl'
        while($true){
            try{
                # Atomic remote replacement makes whole-session retries idempotent.
                foreach($f in @(Get-ChildItem (Join-Path $WorkerHome 'logs') -Filter '*.jsonl')){
                    if($f.Length){Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $script:Queue $f.Name) -Force}
                }
                foreach($f in @(Get-ChildItem $script:Queue -Filter '*.jsonl'|Sort-Object LastWriteTimeUtc)){
                    try{
                        $deliveryCommand='umask 077; d="$HOME/.local/share/remote-disk/logs/'+$WorkerHost+'"; mkdir -p "$d" && cat > "$d/'+$f.Name+'.tmp" && mv "$d/'+$f.Name+'.tmp" "$d/'+$f.Name+'"'
                        [void](Complete-DiskSsh (Start-DiskSsh $deliveryCommand ([IO.File]::ReadAllText($f.FullName))) 15)
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
    if((Get-Variable ApiTimeout -Scope Script -ErrorAction SilentlyContinue)){$params.TimeoutSec=$script:ApiTimeout}
    if($null -ne $Body){$params.Body=ConvertTo-Json -InputObject $Body -Depth 30 -Compress;$params.ContentType='application/json; charset=utf-8'}
    $r=Invoke-WebRequest @params
    if($r.Content){$value=ConvertFrom-Json -InputObject (Convert-DiskRemoteText $r.Content);foreach($item in $value){$item}}
}
function Get-FreeDiskPort {
    $s=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$s.Start();$v=$s.LocalEndpoint.Port;$s.Stop();$v
}
function Set-DiskEngineConfig([string]$Path,[string]$Listen,[string]$Gui,[bool]$First) {
    $xml=New-Object Xml.XmlDocument
    $xml.PreserveWhitespace=$true
    $xml.LoadXml([IO.File]::ReadAllText($Path))
    $options=$xml.SelectSingleNode('/configuration/options')
    $guiNode=$xml.SelectSingleNode('/configuration/gui')
    if($null -eq $options -or $null -eq $guiNode){throw 'Syncthing config.xml must contain configuration/options and configuration/gui; engine not started'}
    $changed=New-Object 'System.Collections.Generic.List[string]'
    # Repair whitespace introduced by earlier indented saves; retain attributes.
    foreach($node in $xml.SelectNodes('//encryptionPassword | //*[not(*) and not(@value)]')){
        $value=$node.InnerText
        if($value.Length -gt 0 -and [string]::IsNullOrWhiteSpace($value) -and
            ($node.Name -eq 'encryptionPassword' -or
                (-not $node.HasAttribute('value') -and $value -match '[\r\n]'))){
            $node.InnerText=''
            if(-not $changed.Contains($node.Name)){$changed.Add($node.Name)}
        }
    }
    $values=[ordered]@{globalAnnounceEnabled='false';localAnnounceEnabled='false';relaysEnabled='false';natEnabled='false';startBrowser='false';crashReportingEnabled='false';autoUpgradeIntervalH='0';urAccepted='-1';listenAddress="tcp://127.0.0.1:$Listen"}
    foreach($key in $values.Keys){
        $nodes=$options.SelectNodes($key)
        if($nodes.Count -ne 1 -or $nodes[0].InnerText -cne $values[$key]){
            foreach($node in $nodes){[void]$options.RemoveChild($node)}
            $node=$xml.CreateElement($key);$node.InnerText=$values[$key];[void]$options.AppendChild($node)
            $changed.Add("options/$key")
        }
    }
    $address=$guiNode.SelectSingleNode('address')
    if($null -eq $address){$address=$xml.CreateElement('address');[void]$guiNode.AppendChild($address)}
    if($address.InnerText -cne "127.0.0.1:$Gui"){$address.InnerText="127.0.0.1:$Gui";$changed.Add('gui/address')}
    if($First){
        $folders=$xml.SelectNodes('/configuration/folder')
        foreach($folder in $folders){[void]$folder.ParentNode.RemoveChild($folder)}
        if($folders.Count){$changed.Add('folder')}
    }
    if($changed.Count){
        $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        try {
            $xml.Save($temp)
            [IO.File]::Replace($temp,$Path,[NullString]::Value)
        } finally {if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
        Write-DiskLog 'engine.config.applied' ($changed -join ', ')
    }
    if($First){[IO.File]::WriteAllText((Join-Path ([IO.Path]::GetDirectoryName($Path)) 'remote-disk-configured'),'configured')}
}
function Initialize-DiskLocal {
    $binary=Join-Path $script:DiskHome 'bin\syncthing.exe'
    if(-not (Test-Path -LiteralPath $binary)){throw 'Engine not installed'}
    $state=Join-Path $script:DiskHome 'state';$xmlPath=Join-Path $state 'config.xml'
    if(-not (Test-Path $xmlPath)){
        & $binary generate --home $state --no-port-probing *> $null
        if($LASTEXITCODE){throw 'Syncthing generate failed'}
    }
    [xml]$xml=[IO.File]::ReadAllText($xmlPath)
    $keyNode=$xml.SelectSingleNode('/configuration/gui/apikey')
    $script:LocalKey='';if($null -ne $keyNode){$script:LocalKey=$keyNode.InnerText}
    try{[void](Invoke-DiskApi local 'system/ping');return}catch{}
    $first=-not (Test-Path -LiteralPath (Join-Path $state 'remote-disk-configured'))
    Set-DiskEngineConfig $xmlPath ([string]$script:Config.listen) ([string]$script:Config.gui) $first
    if($script:Safety){
        $document=New-Object Xml.XmlDocument;$document.PreserveWhitespace=$true;$document.Load($xmlPath)
        foreach($folder in $document.SelectNodes('/configuration/folder')){$folder.SetAttribute('paused','true');$v=$folder.SelectSingleNode('versioning');if($v){[void]$folder.RemoveChild($v)}}
        $document.Save($xmlPath)
    }
    [xml]$xml=[IO.File]::ReadAllText($xmlPath)
    $keyNode=$xml.SelectSingleNode('/configuration/gui/apikey')
    if($null -eq $keyNode){throw 'Syncthing config.xml has no gui/apikey; engine not started'}
    $script:LocalKey=$keyNode.InnerText
    $script:Engine=Start-Process $binary -ArgumentList @('serve','--home',(Quote-Native $state),'--no-browser','--no-restart','--no-upgrade') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $script:DiskHome 'syncthing.stdout.log') -RedirectStandardError (Join-Path $script:DiskHome 'syncthing.stderr.log')
    for($i=0;$i -lt 60;$i++){try{[void](Invoke-DiskApi local 'system/ping');Write-DiskLog 'syncthing.ready';return}catch{Start-Sleep -Milliseconds 200}}
    throw 'Local Syncthing unavailable'
}
function Initialize-DiskRemote {
    if($script:RemoteState){return $true}
    if(-not $script:RemoteInstall){
        $scriptText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'server-disk.sh'))
        $upload='server-disk-'+[guid]::NewGuid().ToString('N')+'.tmp'
        $cmd='set -eu; umask 077; d="$HOME/.local/share/remote-disk"; mkdir -p "$d"; cat > "$d/'+$upload+'"; mv "$d/'+$upload+'" "$d/server-disk.sh"; bash "$d/server-disk.sh" bootstrap'
        $script:RemoteInstall=Start-DiskSsh $cmd $scriptText
        return $false
    }
    if(-not $script:RemoteInstall.p.HasExited -or -not $script:RemoteInstall.out.IsCompleted -or -not $script:RemoteInstall.err.IsCompleted){return $false}
    $job=$script:RemoteInstall;$script:RemoteInstall=$null
    $r=((Complete-DiskSsh $job 1).Replace("`r",''))|ConvertFrom-Json
    $script:RemoteKey=$r.apiKey;$script:RemoteState=$r
    return $true
}
function Step-DiskInitialization {
    if(-not (Test-DiskSafetyReady)){return $false}
    if(-not $script:RemoteState){if(-not (Initialize-DiskRemote)){return $false}}
    return (Step-DiskEngine)
}
function Get-DiskCurl { Join-Path $env:SystemRoot 'System32\curl.exe' }
function Get-DiskPartSize {
    if(Test-Path -LiteralPath $script:EngineInstall.part){return [long](Get-Item -LiteralPath $script:EngineInstall.part).Length}
    return [long]0
}
function Set-DiskInstallStatus {
    $i=$script:EngineInstall;$size=Get-DiskPartSize
    $route='напрямую';if($i.route -eq 'server'){$route='через сервер'}
    $culture=[Globalization.CultureInfo]::GetCultureInfo('ru-RU')
    if(-not $script:LastInitError){
    $script:LastStatus='Установка Syncthing: '+($size/1000000).ToString('0.0',$culture)+' из 14,3 МБ ('+$route+')'
    if($script:Tray){$script:Tray.Text=$script:LastStatus.Substring(0,[Math]::Min(63,$script:LastStatus.Length))}
    }
    $now=[DateTime]::UtcNow
    if(($now-$i.progress).TotalSeconds -ge 30){
        Write-DiskLog 'engine.download.progress' ('path='+$i.route+' bytes='+$size+' bytesPerSecond='+[long](($size-$i.bytes)/[Math]::Max(1,($now-$i.progress).TotalSeconds)))
        $i.progress=$now;$i.bytes=$size
    }
}
function Set-DiskEngineFallback([string]$Reason) {
    $script:EngineInstall.route='server';$script:EngineInstall.prepared=$false
    Write-DiskLog 'engine.download.fallback' $Reason
    Write-DiskLog 'engine.download.start' 'path=server'
}
function Get-DiskFileSha256([string]$Path) {
    $sha=$null;$stream=$null
    try {
        $sha=[Security.Cryptography.SHA256]::Create()
        $stream=[IO.File]::OpenRead($Path)
        ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','')
    }finally{if($stream){$stream.Dispose()};if($sha){$sha.Dispose()}}
}
function Expand-DiskEngineArchive([string]$Archive,[string]$Binary) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=$null;$inputStream=$null;$outputStream=$null;$temp=$null
    try {
        $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
        $entry=$null
        foreach($candidate in $zip.Entries){
            if($candidate.FullName -ceq 'syncthing-windows-amd64-v2.1.7/syncthing.exe'){$entry=$candidate;break}
        }
        if(-not $entry){throw 'В архиве нет syncthing-windows-amd64-v2.1.7/syncthing.exe'}
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Binary))
        $temp=$Binary+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        $inputStream=$entry.Open()
        $outputStream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
        $inputStream.CopyTo($outputStream)
        $outputStream.Dispose();$outputStream=$null
        $inputStream.Dispose();$inputStream=$null
        # .NET Framework has no Move overwrite overload. Replace only the fixed destination.
        if([IO.File]::Exists($Binary)){[IO.File]::Delete($Binary)}
        [IO.File]::Move($temp,$Binary)
        Write-DiskLog 'engine.extract.done' ('path='+$Binary)
    }finally{
        if($outputStream){$outputStream.Dispose()};if($inputStream){$inputStream.Dispose()}
        if($zip){$zip.Dispose()}
        if($temp -and [IO.File]::Exists($temp)){[IO.File]::Delete($temp)}
    }
}
function Test-DiskEngineArchive {
    $i=$script:EngineInstall
    if((Get-DiskPartSize) -ne $i.size){return $false}
    if((Get-DiskFileSha256 $i.part) -ne $i.hash){
        Remove-Item -LiteralPath $i.part -Force
        Write-DiskLog 'engine.hash.error' 'SHA256 mismatch; partial archive removed'
        return $false
    }
    Write-DiskLog 'engine.hash.ok' ('path='+$i.part+' size='+$i.size)
    return $true
}
function Step-DiskEngine {
    $binary=Join-Path $script:DiskHome 'bin\syncthing.exe'
    if((Test-Path -LiteralPath $binary) -and (-not $script:EngineInstall -or -not $script:EngineInstall.job)){
        Initialize-DiskLocal
        $script:EngineInstall=$null
        return $true
    }
    if(-not $script:EngineInstall){
        $script:EngineInstall=@{part=(Join-Path $script:DiskHome 'syncthing.zip.part');size=14281765L;hash='3CE7DA770F546A8D02B65B2E7EE31F2A3B8B7C3F990EDE045590CCA4172ECFE1';route='direct';job=$null;failures=0;before=0L;prepared=$false;offset=0L;length=0;started=[DateTime]::UtcNow;progress=[DateTime]::UtcNow;bytes=0L}
        Write-DiskLog 'engine.download.start' 'path=direct'
    }
    $i=$script:EngineInstall
    Set-DiskInstallStatus
    if($i.job){
        if(-not $i.job.p.HasExited -or -not $i.job.out.IsCompleted -or -not $i.job.err.IsCompleted){return $false}
        $j=$i.job;$i.job=$null
        if($i.route -eq 'direct'){
            $code=$j.p.ExitCode;$stderr=Protect-DiskText ([string]$j.err.Result)
            $stderr=$stderr.Substring(0,[Math]::Min(500,$stderr.Length))
            $size=Get-DiskPartSize
            # A complete resumed file can yield curl 33/HTTP 416: verify before retrying.
            if($size -eq $i.size){if(Test-DiskEngineArchive){$i.prepared=$true};return $false}
            Write-DiskLog 'engine.download.retry' ('code='+$code+' stderr='+$stderr)
            if($size -le $i.before){$i.failures++}else{$i.failures=0}
            if($i.failures -ge 2){Set-DiskEngineFallback 'two attempts without growth'}
        }else{
            try{
                $output=(Complete-DiskSsh $j 1).Replace("`r",'')
                if(-not $i.prepared){
                    $meta=$output|ConvertFrom-Json
                    if([long]$meta.size -ne $i.size){throw 'Unexpected archive size'}
                    $i.prepared=$true
                }else{
                    $chunk=[Convert]::FromBase64String($output)
                    if($chunk.Length -ne $i.length){throw 'Short engine chunk'}
                    if((Get-DiskPartSize) -ne $i.offset){throw 'Engine offset changed'}
                    $f=[IO.File]::Open($i.part,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::Write)
                    try{[void]$f.Seek($i.offset,[IO.SeekOrigin]::Begin);$f.Write($chunk,0,$chunk.Length)}catch{$f.SetLength($i.offset);throw}finally{$f.Dispose()}
                }
            }catch{Write-DiskLog 'engine.download.retry' ('path=server '+$_.Exception.GetType().Name+': '+$_.Exception.Message)}
        }
        return $false
    }
    if(Test-DiskEngineArchive){
        # Keep the engine process owned by the main application, not a disposable job.
        $zip=Join-Path $script:DiskHome 'syncthing.zip'
        Move-Item -LiteralPath $i.part -Destination $zip -Force
        Expand-DiskEngineArchive $zip $binary
        Initialize-DiskLocal
        Write-DiskLog 'engine.download.done' ('path='+$i.route) ([long]([DateTime]::UtcNow-$i.started).TotalMilliseconds)
        $script:EngineInstall=$null
        return $true
    }
    if((Get-DiskPartSize) -gt $i.size){Remove-Item -LiteralPath $i.part -Force;Write-DiskLog 'engine.hash.error' 'Oversized partial archive removed'}
    if($i.route -eq 'direct'){
        $curl=Get-DiskCurl
        if(-not (Test-Path -LiteralPath $curl)){Set-DiskEngineFallback 'System32 curl.exe unavailable';return $false}
        $i.before=Get-DiskPartSize
        $si=New-Object Diagnostics.ProcessStartInfo
        $si.FileName=$curl;$si.Arguments='-sS -fL --connect-timeout 15 --speed-time 30 --speed-limit 1024 -C - -o '+(Quote-Native $i.part)+' https://github.com/syncthing/syncthing/releases/download/v2.1.7/syncthing-windows-amd64-v2.1.7.zip'
        $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardError=$true;$si.RedirectStandardOutput=$true
        $p=New-Object Diagnostics.Process;$p.StartInfo=$si
        try{[void]$p.Start();$i.job=@{p=$p;err=$p.StandardError.ReadToEndAsync();out=$p.StandardOutput.ReadToEndAsync()}}catch{Set-DiskEngineFallback $_.Exception.Message}
    }else{
        $cmd='bash "$HOME/.local/share/remote-disk/server-disk.sh" engine-windows '
        if(-not $i.prepared){$cmd+='prepare'}else{
            $i.offset=Get-DiskPartSize;$i.length=[int][Math]::Min(2097152,$i.size-$i.offset)
            $cmd+='chunk '+$i.offset+' '+$i.length
        }
        $i.job=Start-DiskSsh $cmd
    }
    return $false
}
function Stop-DiskInstall {
    $jobs=@($script:RemoteInstall);if($script:EngineInstall){$jobs+=@($script:EngineInstall.job)}
    foreach($j in $jobs){if($j -and -not $j.p.HasExited){try{$j.p.Kill()}catch{}}}
}
function Start-DiskTunnel {
    $c=$script:Config;$r=$script:RemoteState
    if($c.deviceName -notmatch '^[A-Za-z0-9_-]{1,128}$'){throw 'Invalid device name in config.json'}
    $portInfo=ConvertFrom-Json -InputObject (Complete-DiskSsh (Start-DiskSsh ('bash "$HOME/.local/share/remote-disk/server-disk.sh" device-port '+$c.deviceName)))
    $r.reverse=$portInfo.reverse
    $extra=@('-o','ExitOnForwardFailure=yes','-L',"127.0.0.1:$($c.forward):127.0.0.1:$($r.listen)",'-L',"127.0.0.1:$($c.remoteGui):127.0.0.1:$($r.gui)",'-R',"127.0.0.1:$($r.reverse):127.0.0.1:$($c.listen)")
    $script:Tunnel=Start-DiskSsh 'cat >/dev/null' '' $extra -KeepOpen
    # stdin must remain open for long-lived tunnel.
}
function Connect-DiskDevices {
    $l=Invoke-DiskApi local 'system/status';$r=Invoke-DiskApi remote 'system/status'
    $script:LocalId=$l.myID;$script:PeerId=$r.myID
    if($script:Safety){Write-DiskJson (Join-Path $script:DiskHome 'safety-channel.json') @{localId=$script:LocalId;serverId=$script:PeerId;remoteKey=$script:RemoteKey;tunnelPid=$script:Tunnel.p.Id;tunnelStarted=$script:Tunnel.p.StartTime.ToUniversalTime().ToString('o')}}
    $script:Config|Add-Member -NotePropertyName serverId -NotePropertyValue $script:PeerId -Force;Save-DiskConfig
    foreach($side in @('local','remote')){
        $id=$script:PeerId;$port=$script:Config.forward
        if($side -eq 'remote'){$id=$script:LocalId;$port=$script:RemoteState.reverse}
        [void](Invoke-DiskApi $side "config/devices/$id" 'PUT' @{deviceID=$id;name='RemoteDisk';addresses=@("tcp://127.0.0.1:$port");autoAcceptFolders=$false})
    }
    foreach($folder in $script:Config.folders){[void](Invoke-DiskApi local ('config/folders/'+$folder.id) PATCH @{versioning=@{type=''}});[void](Invoke-DiskApi remote ('config/folders/'+$folder.id) PATCH @{versioning=@{type=''}});Add-DiskGitExclude $folder.path;[void](Invoke-DiskServer 'exclude' @{name=(Get-DiskFolderName $folder)})}
}
function Set-DiskPause($Folder,[int]$Minutes) {
    $paused=$Minutes -ne 0
    [void](Invoke-DiskApi local ('config/folders/'+$Folder.id) PATCH @{paused=($paused -or $null -ne $script:Safety)})
    $Folder.paused=$paused;$Folder.resumeAt=''
    if($Minutes -gt 0){$Folder.resumeAt=[DateTime]::UtcNow.AddMinutes($Minutes).ToString('o')}
    Save-DiskConfig;if($script:Config.contextMenu){Set-DiskContext $true};Write-DiskLog 'folder.pause' ("id="+$Folder.id+" paused="+$paused)
}
function Add-DiskFolder([string]$FolderPath,[string]$RemoteName='',[bool]$AllowMerge=$false) {
    $interactive=-not $RemoteName
    if(-not $FolderPath){
        if($RemoteName){$FolderPath=Join-Path (Join-Path $env:USERPROFILE 'RemoteDisk') (Test-DiskName $RemoteName)}else{
            $d=New-Object Windows.Forms.FolderBrowserDialog;try{if($d.ShowDialog() -ne 'OK'){return};$FolderPath=$d.SelectedPath}finally{$d.Dispose()}
        }
    }
    $FolderPath=[IO.Path]::GetFullPath($FolderPath)
    if($FolderPath -eq [IO.Path]::GetPathRoot($FolderPath)){throw 'Нельзя подключить корень файловой системы'}
    $FolderPath=$FolderPath.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    # Check local policy before any remote creation, including bootstrap on headless add.
    Test-DiskIgnoreFile $FolderPath
    if(Test-Path -LiteralPath $FolderPath){if((Get-Item -LiteralPath $FolderPath).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse point refused'}}
    if(-not $RemoteName){$folders=@(Invoke-DiskServer 'list');$RemoteName=Select-DiskRemote $FolderPath $folders;if(-not $RemoteName){return}}
    $RemoteName=Test-DiskName $RemoteName;$id=Get-DiskFolderId $RemoteName
    foreach($f in $script:Config.folders){
        if($f.id -ceq $id -or (Get-DiskFolderName $f) -ceq $RemoteName){throw ('Серверная папка уже подключена: '+$f.path)}
        $separator=[IO.Path]::DirectorySeparatorChar
        if($FolderPath -eq $f.path -or $FolderPath.StartsWith($f.path+$separator,[StringComparison]::OrdinalIgnoreCase) -or $f.path.StartsWith($FolderPath+$separator,[StringComparison]::OrdinalIgnoreCase)){throw 'Folder already connected or overlaps'}
    }
    $ignore=@(Get-DiskIgnores);$localHas=Test-DiskHasFiles $FolderPath
    $info=Invoke-DiskServer 'inspect' @{name=$RemoteName;ignores=$ignore}
    if($info.id){$id=$info.id} # Legacy server indices are preserved.
    if($localHas -and $info.hasFiles -and -not $AllowMerge){
        if(-not $interactive){throw 'Обе папки непустые: файлы могут смешаться. Для подтверждения передайте -Merge.'}
        if([Windows.Forms.MessageBox]::Show('Обе папки непустые. Файлы могут смешаться. Подключить?','RemoteDisk','YesNo','Warning') -ne 'Yes'){return}
        $AllowMerge=$true
    }
    $lf=New-DiskFolder $id $FolderPath $script:LocalId $script:PeerId
    # Server repeats the nonempty check under its lock, closing races between clients.
    $remote=Invoke-DiskServer 'attach' @{name=$RemoteName;ignores=$ignore;folder=$lf;deviceId=$script:LocalId;deviceName=$script:Config.deviceName;localHasFiles=$localHas;merge=$AllowMerge}
    if($remote.id -cne $id){throw 'Server folder identity changed during attachment; retry'}
    [void][IO.Directory]::CreateDirectory($FolderPath);Add-DiskGitExclude $FolderPath
    [IO.File]::WriteAllLines((Join-Path $FolderPath '.stignore'),$ignore,(New-Object Text.UTF8Encoding($false)))
    [void](Invoke-DiskApi local "config/folders/$id" PUT $lf)
    $applied=Invoke-DiskApi local "config/folders/$id"
    if(-not $applied.paused -or $applied.type -ne 'sendreceive' -or $applied.versioning.type -ne ''){throw 'Local folder verification failed; folder remains paused'}
    $entry=[pscustomobject]@{id=$id;name=$RemoteName;path=$FolderPath;remotePath=$remote.path;paused=$true;resumeAt='';excluded=@()}
    $script:Config.folders=@($script:Config.folders)+@($entry);Save-DiskConfig
    Set-DiskPause $entry 0
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
            'unlock' {
                $name='';if($Request.PSObject.Properties['remote']){$name=$Request.remote}
                Request-DiskUnlock $script:DiskHome @($script:Config.folders|Where-Object {-not $name -or (Get-DiskFolderName $_) -ceq $name})
            }
            'context-on' {Set-DiskContext $true}
            'context-off' {Set-DiskContext $false}
            'exit' {$script:Context.ExitThread()}
            'exit-unlock' {$script:ExitUnlock=$true;$script:Context.ExitThread()}
            'pause' {if($f){Set-DiskPause $f -1}}
            'resume' {if($f){Set-DiskPause $f 0}}
            'exclude' {if($f){Set-DiskExclusion $f $Request.path $true}}
            'include' {if($f){Set-DiskExclusion $f $Request.path $false}}
            'disconnect' {if($f){
                if([Windows.Forms.MessageBox]::Show('Отключить папку? Файлы останутся на обеих сторонах.','RemoteDisk','YesNo') -ne 'Yes'){return}
                Request-DiskUnlock $script:DiskHome @($f)
                $script:PendingDisconnect=@($script:PendingDisconnect)+@($f)
            }}
            default {[Windows.Forms.MessageBox]::Show($(if($f){(@(Get-DiskSnapshot (Get-DiskFolderName $f))|ConvertTo-Json -Depth 8)}else{$script:LastStatus}),'RemoteDisk')|Out-Null}
        }
    }catch{Write-DiskLog 'command.error' $_.Exception.GetType().Name;[Windows.Forms.MessageBox]::Show((Protect-DiskText $_.Exception.Message),'RemoteDisk')|Out-Null}
}
function New-DiskPipe {
    $script:Pipe=New-Object IO.Pipes.NamedPipeServerStream($script:PipeName,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous)
    $script:PipeWait=$script:Pipe.BeginWaitForConnection($null,$null)
}
function Set-DiskContext([bool]$Enabled) {
    foreach($type in @('Directory','*')){
        $base="HKCU:\Software\Classes\$type\shell"
        if(Test-Path $base){Get-ChildItem $base|Where-Object {$_.PSChildName -like 'RemoteDisk*'}|Remove-Item -Recurse -Force}
    }
    if($Enabled){
        $actions=,@('add','Синхронизировать с сервером','Directory')
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
            $cmd=(Get-DiskLaunchCommand)+' -Command '+$a[0]+' -Path "%1"'
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
    if($script:Safety -and $script:Safety.HasExited){$script:LastInitError='Контроллер ACL остановился; запись не разрешена. Смотрите logs/safety.jsonl.'}
    if($script:LastInitError){
        $script:LastStatus='Ошибка запуска: '+$script:LastInitError
        if($script:Tray){
            $old=$script:Tray.Icon;$script:Tray.Icon=New-DiskIcon error;if($old){$old.Dispose()}
            $script:Tray.Text=$script:LastStatus.Substring(0,[Math]::Min(63,$script:LastStatus.Length))
        }
        return
    }
    if($script:EngineInstall){Set-DiskInstallStatus;return}
    foreach($f in $script:Config.folders){
        if($f.paused -and $f.resumeAt -and ([DateTime]$f.resumeAt).ToUniversalTime() -le [DateTime]::UtcNow){Set-DiskPause $f 0}
    }
    if($script:Safety){Step-DiskConflictScan}
    $rows=@(Get-DiskSnapshot)
    if($script:Safety){Step-DiskServerJobs $rows}
    $states=@($rows|ForEach-Object {$_.state})
    $connected=$rows.Count -gt 0 -and @($rows|Where-Object {-not $_.serverConnected}).Count -eq 0
    $lines=@($rows|ForEach-Object {$_.name+': '+$_.state+$(if($_.locked){' locked'})+' ('+$_.remainingBytes+' байт, '+$_.remainingFiles+' файлов осталось)'})
    $details=@($rows|Where-Object {$_.message}|ForEach-Object {$_.message})
    $state='synced'
    foreach($s in @('syncing','paused','conflict','error')){if($states -contains $s){$state=$s}}
    if(-not $connected){$state='offline'}
    $script:LastStatus=(@($state)+$lines+$details)-join "`r`n"
    if($script:PreviousState -ne $state){Write-DiskLog 'syncthing.state' $state;$script:PreviousState=$state}
    $old=$script:Tray.Icon;$script:Tray.Icon=New-DiskIcon $state;if($old){$old.Dispose()}
    $script:Tray.Text=('RemoteDisk '+($lines -join '; ')+' '+$state).Substring(0,[Math]::Min(63,('RemoteDisk '+($lines -join '; ')+' '+$state).Length))
    $script:FolderMenu.DropDownItems.Clear()
    foreach($folder in $script:Config.folders){
        $row=@($rows|Where-Object {$_.path -eq $folder.path})|Select-Object -First 1
        $node=New-Object Windows.Forms.ToolStripMenuItem(((Get-DiskFolderName $folder)+': '+$row.state+$(if($row.locked){' locked'})))
        $pathToOpen=$folder.path;$entry=$folder
        $item=New-Object Windows.Forms.ToolStripMenuItem('Открыть папку');$item.Tag=$pathToOpen;$item.add_Click({param($sender,$event) Start-Process explorer.exe -ArgumentList (Quote-Native $sender.Tag)});[void]$node.DropDownItems.Add($item)
        foreach($pair in @(@('Пауза на 30 минут',30),@('Пауза на 2 часа',120),@('Пауза до включения',-1),@('Возобновить',0))){
            $minutes=$pair[1];$item=New-Object Windows.Forms.ToolStripMenuItem($pair[0]);$item.Tag=@($entry,$minutes);$item.add_Click({param($sender,$event) try{Set-DiskPause $sender.Tag[0] $sender.Tag[1]}catch{Write-DiskLog 'pause.error'}});[void]$node.DropDownItems.Add($item)
        }
        $item=New-Object Windows.Forms.ToolStripMenuItem('Снять блокировку');$item.Tag=$entry;$item.add_Click({param($sender,$event) Request-DiskUnlock $script:DiskHome @($sender.Tag)});[void]$node.DropDownItems.Add($item)
        [void]$script:FolderMenu.DropDownItems.Add($node)
    }
}
function Initialize-DiskRuntime {
    $script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'
    $script:Queue=Join-Path $script:DiskHome 'logs/queue';[void][IO.Directory]::CreateDirectory($script:Queue)
    $script:Sent=Join-Path $script:DiskHome 'logs/sent';[void][IO.Directory]::CreateDirectory($script:Sent)
    $script:HostName=[regex]::Replace([string]$env:COMPUTERNAME,'[^A-Za-z0-9_-]','_')
    if(-not $script:HostName){$script:HostName='device'}
    $script:LogFile=Join-Path $script:DiskHome ('logs/session-'+[guid]::NewGuid().ToString('N')+'.jsonl')
    $script:LocalKey='';$script:RemoteKey='';$script:Connection=$null;$script:Upload=$null;$script:LogWorker=$null;$script:EngineInstall=$null;$script:RemoteInstall=$null
    $script:ConfigFile=Join-Path $script:DiskHome 'config.json'
    Write-DiskLog 'start' ('command='+$Command)
    if(Test-Path -LiteralPath $script:ConfigFile){$script:Config=Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding UTF8|ConvertFrom-Json}else{
        $script:Config=[pscustomobject]@{schema=1;listen=(Get-FreeDiskPort);gui=(Get-FreeDiskPort);forward=(Get-FreeDiskPort);remoteGui=(Get-FreeDiskPort);folders=@();contextMenu=$false}
    }
    if(-not $script:Config.PSObject.Properties['deviceName']){$script:Config|Add-Member -NotePropertyName deviceName -NotePropertyValue ($script:HostName+'-'+[guid]::NewGuid().ToString('N'))}
    $xmlPath=Join-Path $script:DiskHome 'state/config.xml'
    if(Test-Path -LiteralPath $xmlPath){[xml]$xml=[IO.File]::ReadAllText($xmlPath);$script:LocalKey=$xml.configuration.gui.apikey}
}
function Get-DiskAppPath {
    $app=Join-Path $script:DiskHome 'app';[void][IO.Directory]::CreateDirectory($app)
    foreach($name in @('RemoteDisk.ps1','server-disk.sh','DiskLock.ps1','Set-DiskAcl.ps1','Watch-Disk.ps1')){
        $source=Join-Path $PSScriptRoot $name;$target=Join-Path $app $name
        if([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($target)){Copy-Item -LiteralPath $source -Destination $target -Force}
    }
    Join-Path $app 'RemoteDisk.ps1'
}
function Get-DiskLaunchCommand {
    $cmd='powershell.exe -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File '+(Quote-Native (Get-DiskAppPath))
    if($script:ProfileFile){$cmd+=' -Profile '+(Quote-Native $script:ProfileFile)}
    $cmd
}
function Send-DiskRequest($Request) {
    $client=New-Object IO.Pipes.NamedPipeClientStream('.', $script:PipeName,[IO.Pipes.PipeDirection]::InOut)
    try{
        $client.Connect(4000);$writer=New-Object IO.StreamWriter($client);$writer.AutoFlush=$true
        $reader=New-Object IO.StreamReader($client)
        $writer.WriteLine(($Request|ConvertTo-Json -Compress));$read=$reader.ReadLineAsync()
        if(-not $read.Wait(60000)){throw 'RemoteDisk command timeout'}
        $reply=ConvertFrom-Json -InputObject $read.Result
        if(-not $reply.ok){throw $reply.error}
    }finally{$client.Dispose()}
}
function Invoke-DiskHeadlessAdd {
    # A running app owns its config and tunnel; ask it to perform the same operation.
    $sid=(Get-DiskAclIdentity).User.Value;$script:PipeName='RemoteDisk-'+$sid
    $created=$false;$lock=New-Object Threading.Mutex($true,('Local\'+$script:PipeName),[ref]$created)
    try{
        if(-not $created){Send-DiskRequest @{command='add';path=$Path;remote=$Remote;merge=[bool]$Merge};return}
        $folderPath=$Path
        if(-not $folderPath){$folderPath=Join-Path (Join-Path $env:USERPROFILE 'RemoteDisk') (Test-DiskName $Remote)}
        Test-DiskIgnoreFile $folderPath
        # Duplicate path/identity and policy checks happen before contacting the server.
        $id=Get-DiskFolderId $Remote
        foreach($f in $script:Config.folders){if($f.id -ceq $id -or (Get-DiskFolderName $f) -ceq $Remote){throw ('Серверная папка уже подключена: '+$f.path)}}
        Start-DiskSafety
        Select-DiskProfile;Save-DiskConfig
        Write-DiskLog 'ssh.login' ('user='+$script:Connection.login)
        Send-DiskLogs -First;Start-DiskLogWorker
        $script:RemoteState=$null;$script:RemoteInstall=$null;$script:EngineInstall=$null;$script:Tray=$null
        while(-not (Step-DiskInitialization)){Start-Sleep -Milliseconds 150}
        Start-DiskTunnel;Wait-DiskTunnel;Connect-DiskDevices
        Add-DiskFolder $folderPath $Remote ([bool]$Merge)
    }finally{
        if($created){
            Stop-DiskSafety
            if($script:Tunnel){try{$script:Tunnel.p.Kill()}catch{}}
            Stop-DiskInstall
            if($script:LogWorker){Stop-Job $script:LogWorker;Remove-Job $script:LogWorker}
            if($script:Connection){try{Send-DiskLogs;if($script:Upload){[void](Complete-DiskSsh $script:Upload 15);Send-DiskLogs -DrainOnly}}catch{}}
            $lock.ReleaseMutex()
        };$lock.Dispose()
    }
    if($created){
        $started=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=(Get-DiskLaunchCommand)}
        if($started.ReturnValue -ne 0){throw ('Папка подключена, запуск трея не удался: '+$started.ReturnValue)}
    }
}
function Install-DiskApp {
    Select-DiskProfile
    $key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';[void](New-Item $key -Force)
    $command=Get-DiskLaunchCommand
    New-ItemProperty $key RemoteDisk -Value $command -Force|Out-Null
    # Gracefully stop an earlier copy before starting the installed app.
    $sid=(Get-DiskAclIdentity).User.Value;$script:PipeName='RemoteDisk-'+$sid
    $existing=$null
    if([Threading.Mutex]::TryOpenExisting(('Local\'+$script:PipeName),[ref]$existing)){
        try{Send-DiskRequest @{command='exit';path=''};if(-not $existing.WaitOne(10000)){throw 'RemoteDisk is still shutting down'};$existing.ReleaseMutex()}finally{$existing.Dispose()}
    }
    if(Test-Path -LiteralPath $script:ConfigFile){$script:Config=Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding UTF8|ConvertFrom-Json}
    Set-DiskContext $true
    $started=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=($command+' -Command context-on')}
    if($started.ReturnValue -ne 0){throw ('RemoteDisk start failed: '+$started.ReturnValue)}
    Write-DiskLog 'install';'RemoteDisk установлен в '+(Join-Path $script:DiskHome 'app')
}
function Start-DiskSafety {
    Save-DiskConfig
    foreach($name in @('safety-stop.json','safety-channel.json','safety-state.json','conflict-scan.json')){Remove-Item -LiteralPath (Join-Path $script:DiskHome $name) -Force -ErrorAction SilentlyContinue}
    foreach($f in $script:Config.folders){Remove-Item -LiteralPath ((Get-DiskLockRecord $script:DiskHome $f)+'.unlock') -Force -ErrorAction SilentlyContinue}
    $si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=Join-Path $PSHOME 'powershell.exe'
    $si.Arguments=(@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Watch-Disk.ps1'),'-HomePath',$script:DiskHome,'-ParentId',[string]$PID)|ForEach-Object {Quote-Native $_}) -join ' '
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true
    $script:Safety=New-Object Diagnostics.Process;$script:Safety.StartInfo=$si;[void]$script:Safety.Start()
}
function Test-DiskSafetyReady {
    if(-not $script:Safety){return $true} # Library/isolated engine tests do not run NTFS.
    if($script:Safety.HasExited){throw 'Контроллер ACL остановился; подключение запрещено. Смотрите logs/safety.jsonl.'}
    $state=Read-DiskJson (Join-Path $script:DiskHome 'safety-state.json')
    $null -ne $state -and $state.pid -eq $script:Safety.Id -and $state.startupReady
}
function Stop-DiskSafety([bool]$Unlock=$false) {
    if(-not $script:Safety){return}
    $mode='exit';if($Unlock){$mode='unlock'}
    Write-DiskJson (Join-Path $script:DiskHome 'safety-stop.json') @{mode=$mode}
    while(-not $script:Safety.WaitForExit(100)){
        if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){[Windows.Forms.Application]::DoEvents()}
    }
    if($script:Safety.ExitCode -ne 0){throw 'ACL controller failed; inspect logs/safety.jsonl and use -Command unlock'}
    $script:Safety.Dispose();$script:Safety=$null
}
function Invoke-DiskUnlock([string]$RemoteName='') {
    $folders=@($script:Config.folders|Where-Object {-not $RemoteName -or (Get-DiskFolderName $_) -ceq $RemoteName})
    if(-not $folders.Count){throw 'Нет подключённых папок для разблокировки'}
    Request-DiskUnlock $script:DiskHome $folders
    $jobs=@()
    $sid=(Get-DiskAclIdentity).User.Value;$script:PipeName='RemoteDisk-'+$sid
    $existing=$null
    if([Threading.Mutex]::TryOpenExisting(('Local\'+$script:PipeName),[ref]$existing)){
        try{Send-DiskRequest @{command='unlock';path='';remote=$RemoteName}}finally{$existing.Dispose()}
    }else{foreach($f in $folders){$jobs+=Start-DiskAclProcess $script:DiskHome $f $false}}
    foreach($job in $jobs){while(-not $job.WaitForExit(100)){};if($job.ExitCode -ne 0){throw 'ACL unlock failed'};$job.Dispose()}
    do{
        $pending=$false
        foreach($f in $folders){
            $info=Get-DiskLockInfo $script:DiskHome $f
            if($info.error){throw $info.error}
            if($info.locked -ne $false -or (Test-Path -LiteralPath (Get-DiskLockRecord $script:DiskHome $f))){$pending=$true}
        }
        if($pending){Start-Sleep -Milliseconds 100}
    }while($pending)
    Write-DiskLog 'acl.unlock' ('folders='+$folders.Count)
}
function Complete-DiskDisconnects {
    foreach($folder in @($script:PendingDisconnect)){
        $info=Get-DiskLockInfo $script:DiskHome $folder
        if($info.error){Write-DiskLog 'disconnect.acl.error' $info.error;continue}
        if($info.locked -ne $false -or (Test-Path -LiteralPath (Get-DiskLockRecord $script:DiskHome $folder))){continue}
        [void](Invoke-DiskServer 'detach' @{name=(Get-DiskFolderName $folder);id=$folder.id;deviceId=$script:LocalId})
        [void](Invoke-DiskApi local ('config/folders/'+$folder.id) DELETE)
        $script:Config.folders=@($script:Config.folders|Where-Object {$_.id -ne $folder.id});Save-DiskConfig
        $script:PendingDisconnect=@($script:PendingDisconnect|Where-Object {$_.id -ne $folder.id})
        if($script:Config.contextMenu){Set-DiskContext $true}
    }
}
function Step-DiskConflictScan {
    if($script:ConflictScan -and $script:ConflictScan.State -in @('Completed','Failed','Stopped')){
        try{
            $items=@(Receive-Job $script:ConflictScan -ErrorAction Stop)
            Write-DiskJson (Join-Path $script:DiskHome 'conflict-scan.json') @{folders=$items;error=''}
        }catch{
            Write-DiskJson (Join-Path $script:DiskHome 'conflict-scan.json') @{folders=@();error=$_.Exception.Message}
            Write-DiskLog 'conflict.scan.error' $_.Exception.Message
        }finally{Remove-Job $script:ConflictScan;$script:ConflictScan=$null}
    }
    if(-not $script:ConflictScan){
        $script:ConflictScan=Start-Job -ArgumentList (,@($script:Config.folders)) -ScriptBlock {
            param($Folders)
            foreach($f in $Folders){
                $copies=@(Get-ChildItem -LiteralPath $f.path -Filter '*.sync-conflict-*' -Recurse -Force -File -ErrorAction Stop)
                [pscustomobject]@{id=$f.id;conflict=($copies.Count -gt 0)}
            }
        }
    }
}
function Step-DiskServerJobs($Rows) {
    if($script:ServerJob){
        $job=$script:ServerJob
        if(-not $job.ssh.p.HasExited){return}
        try{
            $value=ConvertFrom-Json -InputObject (Complete-DiskSsh $job.ssh 1)
            if($job.action -eq 'list'){Write-DiskJson (Join-Path $script:DiskHome 'server-folders.json') @($value)}
            Write-DiskLog ('server.'+$job.action) 'completed'
        }catch{Write-DiskLog ('server.'+$job.action+'.error') $_.Exception.Message}
        $script:ServerJob=$null
    }
    $conflict=@($Rows|Where-Object {$_.state -eq 'conflict'})|Select-Object -First 1
    $action='list';$data=$null
    if($conflict){$action='resolve';$data=@{name=$conflict.name}}
    elseif([DateTime]::UtcNow -lt $script:NextServerList){return}
    $cmd='bash "$HOME/.local/share/remote-disk/server-disk.sh" '+$action
    if($data){$cmd+=' '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($data|ConvertTo-Json -Compress)))}
    $script:ServerJob=@{action=$action;ssh=(Start-DiskSsh $cmd)};$script:NextServerList=[DateTime]::UtcNow.AddSeconds(30)
}
function Start-DiskApp {
    $sid=(Get-DiskAclIdentity).User.Value
    $script:PipeName='RemoteDisk-'+$sid
    $created=$false;$script:Mutex=New-Object Threading.Mutex($true,('Local\'+$script:PipeName),[ref]$created)
    if(-not $created){
        Send-DiskRequest @{command=$Command;path=$Path}
        return
    }
    Start-DiskSafety
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class DiskNative { [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h); }'

    Select-DiskProfile
    Write-DiskLog 'ssh.login' ('user='+$script:Connection.login)
    # Legacy serverUser in config.json is ignored; commands use the SSH profile login.
    Save-DiskConfig
    if($Command -eq 'context-on'){Set-DiskContext $true;$Command='show'}
    Send-DiskLogs -First
    if($script:Upload){try{[void](Complete-DiskSsh $script:Upload 15);Move-Item $script:Pending (Join-Path $script:Sent ([IO.Path]::GetFileName($script:Pending))) -Force}catch{};$script:Upload=$null}
    Start-DiskLogWorker
    # Recover batches from prior sessions, including a crash before rotation.
    foreach($log in Get-ChildItem (Join-Path $script:DiskHome 'logs') -Filter 'session-*.jsonl'){
        if($log.FullName -ne $script:LogFile){Move-Item $log.FullName (Join-Path $script:Queue ($log.Name)) -Force}
    }
    $script:EngineInstall=$null;$script:RemoteInstall=$null
    $script:Tunnel=$null;$script:Engine=$null;$script:RemoteState=$null;$script:PeerId='';$script:PreviousState='';$script:LastInitError='';$script:LastStatus='Нет подключения'
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
            New-ItemProperty $key RemoteDisk -Value (Get-DiskLaunchCommand) -Force|Out-Null
        }
    })
    [void](Add-DiskMenu $menu 'Выход' {$script:Context.ExitThread()})
    $script:Tray.ContextMenuStrip=$menu;$script:Tray.add_DoubleClick({[Windows.Forms.MessageBox]::Show($script:LastStatus,'RemoteDisk')|Out-Null})
    New-DiskPipe
    $script:LastUpload=[DateTime]::MinValue;$script:Retry=[DateTime]::MinValue;$script:LastTick=[DateTime]::UtcNow
    $script:Context=New-Object Windows.Forms.ApplicationContext
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=4000
    $timer.add_Tick({
        try{
            $now=[DateTime]::UtcNow
            if(($now-$script:LastTick).TotalSeconds -gt 20){Write-DiskLog 'power.resume' 'Timer gap detected'};$script:LastTick=$now
            if($script:PipeWait.IsCompleted){
                $script:Pipe.EndWaitForConnection($script:PipeWait)
                $reader=New-Object IO.StreamReader($script:Pipe);$read=$reader.ReadLineAsync()
                if($read.Wait(1000)){
                    $request=$read.Result|ConvertFrom-Json;$reply=@{ok=$true;error=''}
                    try{
                        if($request.command -eq 'add' -and $request.PSObject.Properties['remote'] -and $request.remote){Add-DiskFolder $request.path $request.remote ([bool]$request.merge)}else{Invoke-DiskCommand $request}
                    }catch{$reply.ok=$false;$reply.error=Protect-DiskText $_.Exception.Message;Write-DiskLog 'command.error' $reply.error}
                    $writer=New-Object IO.StreamWriter($script:Pipe);$writer.AutoFlush=$true;$writer.WriteLine(($reply|ConvertTo-Json -Compress))
                }
                $reader.Dispose();$script:Pipe.Dispose();New-DiskPipe
            }
            if($script:Tunnel -and $script:Tunnel.p.HasExited){try{[void](Complete-DiskSsh $script:Tunnel 1)}catch{};$script:Tunnel=$null;$script:RemoteState=$null;$script:Retry=$now.AddSeconds(5)}
            if(-not $script:Tunnel -and $now -ge $script:Retry){
                $script:Retry=$now.AddSeconds(30)
                try{
                    if(-not (Step-DiskInitialization)){$script:Retry=$now;return}
                    $watch=[Diagnostics.Stopwatch]::StartNew()
                    try{$ips=[Net.Dns]::GetHostAddresses($script:Connection.serverAddress);Write-DiskLog 'dns' (($ips|ForEach-Object {$_.IPAddressToString}) -join ',') $watch.ElapsedMilliseconds}catch{Write-DiskLog 'dns.error' '' $watch.ElapsedMilliseconds}
                    $tcp=New-Object Net.Sockets.TcpClient;$tcpPort=22
                    $sshArgs=@($script:Connection.arguments);for($argIndex=0;$argIndex -lt $sshArgs.Count-1;$argIndex++){if($sshArgs[$argIndex] -eq '-p'){$tcpPort=[int]$sshArgs[$argIndex+1]}}
                    try{$task=$tcp.ConnectAsync($script:Connection.serverAddress,$tcpPort);if(-not $task.Wait(1500)){throw 'timeout'};Write-DiskLog 'tcp' ("port=$tcpPort connected")}catch{Write-DiskLog 'tcp.error' ("port=$tcpPort (route may use a fallback)")}finally{$tcp.Dispose()}
                    Start-DiskTunnel
                    Wait-DiskTunnel;Connect-DiskDevices
                    $script:LastInitError=''
                    if($Command -eq 'add' -and $Path){Invoke-DiskCommand @{command='add';path=$Path};$Command='show'}
                }catch{$script:LastInitError=Protect-DiskText $_.Exception.Message;$script:LastStatus='Ошибка запуска: '+$script:LastInitError;$script:RemoteState=$null;Write-DiskLog 'initialize.error' ($_.Exception.GetType().Name+': '+$_.Exception.Message);if($script:Tunnel){try{$script:Tunnel.p.Kill()}catch{};$script:Tunnel=$null}}
            }
            Complete-DiskDisconnects
            Update-DiskState
        }catch{Write-DiskLog 'tick.error' ($_.Exception.GetType().Name+': '+$_.Exception.Message)}
    })
    try{$timer.Start();[Windows.Forms.Application]::Run($script:Context)}finally{
        $timer.Stop();$timer.Dispose();$aclFailure=$null
        try{Stop-DiskSafety $script:ExitUnlock}catch{$aclFailure=$_;Write-DiskLog 'acl.exit.error' $_.Exception.Message}
        Stop-DiskInstall;Write-DiskLog 'exit'
        if($script:Tunnel){try{$script:Tunnel.p.Kill()}catch{}}
        try{[void](Invoke-DiskApi local 'system/shutdown' POST)}catch{}
        if($script:ConflictScan){Stop-Job $script:ConflictScan;Remove-Job $script:ConflictScan}
        Stop-Job $script:LogWorker;Remove-Job $script:LogWorker;Send-DiskLogs;$script:Tray.Visible=$false;$script:Tray.Dispose();$script:Pipe.Dispose();$script:Mutex.ReleaseMutex();$script:Mutex.Dispose()
        if($aclFailure){throw $aclFailure}
    }
}
if(-not $LibraryOnly){
    try{
        Initialize-DiskRuntime
        if($Command -eq 'status'){Invoke-DiskStatus $Remote $Wait;exit $script:StatusExitCode}
        if($Command -eq 'unlock'){Invoke-DiskUnlock $Remote;return}
        if($Uninstall){
            Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' RemoteDisk -ErrorAction SilentlyContinue
            $sid=(Get-DiskAclIdentity).User.Value;$script:PipeName='RemoteDisk-'+$sid
            $existing=$null
            if([Threading.Mutex]::TryOpenExisting(('Local\'+$script:PipeName),[ref]$existing)){try{Send-DiskRequest @{command='context-off';path=''};Send-DiskRequest @{command='exit-unlock';path=''};if(-not $existing.WaitOne(30000)){throw 'RemoteDisk is still unlocking'};$existing.ReleaseMutex()}finally{$existing.Dispose()}}else{Set-DiskContext $false}
            if(@($script:Config.folders).Count){Invoke-DiskUnlock};Write-DiskLog 'uninstall';return
        }
        if($Install){Install-DiskApp;return}
        if($Command -eq 'add' -and $Remote){Invoke-DiskHeadlessAdd;return}
        Start-DiskApp
    }catch{if($script:LogFile){Write-DiskLog 'fatal' ($_.Exception.GetType().Name+': '+$_.Exception.Message)};throw}
}
