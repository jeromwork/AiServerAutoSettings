# Dot-source Sync.Workspace.ps1 first. All endpoints are private localhost.
$script:SyncVersion='2.1.7'
$script:SyncWindowsSHA='3ce7da770f546a8d02b65b2e7ee31f2a3b8b7c3f990ede045590cca4172ecfe1'
function Install-RemoteSyncBinary {
    param([Parameter(Mandatory)][string]$DataDir,[string]$DownloadedArchive)
    $base=Join-Path $DataDir 'sync\bin\2.1.7'
    $exe=Join-Path $base 'syncthing.exe'
    if(Test-Path -LiteralPath $exe) { return $exe }
    $archive=$DownloadedArchive; $temporary=$false
    if(!$archive) {
        $archive=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N')+'.zip');$temporary=$true
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/syncthing/syncthing/releases/download/v2.1.7/syncthing-windows-amd64-v2.1.7.zip' -OutFile $archive
    }
    try {
        if((Get-SyncSHA256 $archive) -cne $script:SyncWindowsSHA) { throw 'Syncthing archive SHA256 mismatch' }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip=[IO.Compression.ZipFile]::OpenRead($archive)
        try {
            $entry=@($zip.Entries | Where-Object { $_.FullName -eq 'syncthing-windows-amd64-v2.1.7/syncthing.exe' })
            if($entry.Count -ne 1) { throw 'Unexpected release layout' }
            New-Item -ItemType Directory -Path $base -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry[0],$exe,$false)
        } finally { $zip.Dispose() }
    } finally { if($temporary -and (Test-Path -LiteralPath $archive)) { Remove-Item -LiteralPath $archive -Force } }
    $exe
}
function Set-SyncXmlText($Document,$Parent,$Name,$Text) {
    $node=$Parent.SelectSingleNode($Name)
    if(!$node) { $node=$Document.CreateElement($Name);[void]$Parent.AppendChild($node) }
    $node.InnerText=[string]$Text
}
function Initialize-RemoteSyncWorker {
    param([string]$DataDir,[string]$ProjectId,[string]$HostId,[string]$Executable,[string]$PeerDeviceId,[int]$ListenPort,[int]$PeerTunnelPort,[int]$GuiPort)
    foreach($port in @($ListenPort,$PeerTunnelPort,$GuiPort)) { if($port -lt 1024 -or $port -gt 65535) { throw 'Invalid private port' } }
    if(@($ListenPort,$PeerTunnelPort,$GuiPort | Select-Object -Unique).Count -ne 3) { throw 'Ports must differ' }
    if($PeerDeviceId -and $PeerDeviceId -notmatch '^[A-Z2-7-]{63}$') { throw 'Invalid peer device ID' }
    $binding=Get-SyncBinding $DataDir $ProjectId $HostId
    $state=Get-SyncStatePath $DataDir $ProjectId $HostId
    $workerHome=Join-Path $state 'worker'
    if(Test-Path -LiteralPath (Join-Path $state 'runtime.json')) { throw 'Worker configured; use connect, do not overwrite configuration' }
    New-Item -ItemType Directory -Path $workerHome -Force | Out-Null
    # Runtime-generated identity/API state is private, never output or copied to the model.
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule=New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule);([IO.DirectoryInfo]$workerHome).SetAccessControl($acl)
    $config=Join-Path $workerHome 'config.xml'
    if(!(Test-Path -LiteralPath $config)) {
        $generate= & $Executable generate --home $workerHome 2>&1
        if($LASTEXITCODE -ne 0) { throw 'Syncthing generate failed' }
    }
    [xml]$xml=[IO.File]::ReadAllText((ConvertTo-RemoteAgentsIOPath $config))
    $localId=$xml.configuration.SelectSingleNode('device').GetAttribute('id')
    if(!$PeerDeviceId) { return [pscustomobject]@{deviceId=$localId;home=$workerHome;configured=$false} }
    foreach($folder in @($xml.configuration.SelectNodes('folder'))) { [void]$xml.configuration.RemoveChild($folder) }
    $options=$xml.configuration.options
    foreach($name in @('globalAnnounceEnabled','localAnnounceEnabled','relaysEnabled','natEnabled','startBrowser','crashReportingEnabled','autoUpgradeIntervalH')) {
        $value='false';if($name -eq 'autoUpgradeIntervalH'){$value='0'}
        Set-SyncXmlText $xml $options $name $value
    }
    Set-SyncXmlText $xml $options 'listenAddress' "tcp://127.0.0.1:$ListenPort"
    Set-SyncXmlText $xml $options 'urAccepted' '-1'
    Set-SyncXmlText $xml $xml.configuration.gui 'address' "127.0.0.1:$GuiPort"
    $localId=$xml.configuration.SelectSingleNode('device').GetAttribute('id')
    $peer=$xml.CreateElement('device');$peer.SetAttribute('id',$PeerDeviceId);$peer.SetAttribute('name','approved-peer')
    Set-SyncXmlText $xml $peer 'address' "tcp://127.0.0.1:$PeerTunnelPort"
    Set-SyncXmlText $xml $peer 'autoAcceptFolders' 'false'
    [void]$xml.configuration.AppendChild($peer)
    $folder=$xml.CreateElement('folder');$folder.SetAttribute('id',$binding.folderId);$folder.SetAttribute('path',$binding.replicaPath);$folder.SetAttribute('type','receiveonly');$folder.SetAttribute('paused','true');$folder.SetAttribute('rescanIntervalS','3600');$folder.SetAttribute('fsWatcherEnabled','true')
    foreach($id in @($localId,$PeerDeviceId)){$dev=$xml.CreateElement('device');$dev.SetAttribute('id',$id);[void]$folder.AppendChild($dev)}
    $versioning=$xml.CreateElement('versioning');$versioning.SetAttribute('type','simple');$param=$xml.CreateElement('param');$param.SetAttribute('key','keep');$param.SetAttribute('val','10');[void]$versioning.AppendChild($param);[void]$folder.AppendChild($versioning)
    [void]$xml.configuration.AppendChild($folder)
    New-Item -ItemType Directory -Path $binding.replicaPath | Out-Null
    # Deny all by default, allow only explicit roots; deny rules precede inclusions.
    $ignores=@('(?i).env*','(?i)env.example','(?i)*credential*','(?i)*token*','(?i)*secret*','(?i)*private*','(?i)*.pem','(?i)*.key','(?i)*.keystore','(?i)*.jks','(?i)*.p8','(?i)*.p12','(?i)google-services*.json','(?i)GoogleService-Info.plist','auth.json','.git','.tools','.ssh','.codex','.claude','node_modules','vendor','.gradle','.next','.cache','build','dist','target','coverage','logs','log','cache','caches','uploads','storage','android-sdk','local.properties','config.php','*.db','*.sqlite*','*.log')
    $wholeRootMode=$binding.PSObject.Properties.Name -contains 'scopeMode' -and $binding.scopeMode -in @('git','folder')
    if($wholeRootMode){$ignores+='!/**'}else{
        foreach($root in $binding.allowedRoots) { $relative=$root.Replace('\','/').Replace('[','|[').Replace(']','|]');$ignores+='!/'+$relative;$ignores+='!/'+$relative+'/**' }
    }
    $ignores+='*'
    [IO.File]::WriteAllLines((ConvertTo-RemoteAgentsIOPath (Join-Path $binding.replicaPath '.stignore')),$ignores,(New-Object Text.UTF8Encoding($false)))
    $xml.Save((ConvertTo-RemoteAgentsIOPath $config))
    Write-SyncJson (Join-Path $state 'runtime.json') @{guiPort=$GuiPort;home=$workerHome;peerDeviceId=$PeerDeviceId;localDeviceId=$localId;executable=$Executable;listenPort=$ListenPort;peerTunnelPort=$PeerTunnelPort}
    [pscustomobject]@{deviceId=$localId;home=$workerHome;paused=$true;replicaPath=$binding.replicaPath}
}
function Invoke-SyncLocalApi {
    param($Runtime,[string]$Method,[string]$Route,$Body)
    # Only generated worker config owned by this module; never existing agent auth/credentials.
    [xml]$config=[IO.File]::ReadAllText((Join-Path $Runtime.home 'config.xml'))
    $parameters=@{Uri="http://127.0.0.1:$($Runtime.guiPort)/rest/$Route";Method=$Method;Headers=@{'X-API-Key'=[string]$config.configuration.gui.apikey};TimeoutSec=10;UseBasicParsing=$true;ErrorAction='Stop'}
    if($null -ne $Body){$parameters.Body=($Body|ConvertTo-Json -Depth 12 -Compress);$parameters.ContentType='application/json'}
    try { Invoke-RestMethod @parameters } catch { throw 'Private Syncthing API unavailable or request rejected' }
}
function Get-RemoteSyncLiveHealth {
    param([string]$DataDir,[string]$ProjectId,[string]$HostId)
    $state=Get-SyncStatePath $DataDir $ProjectId $HostId
    $runtime=Get-Content -LiteralPath (Join-Path $state 'runtime.json') -Raw|ConvertFrom-Json
    $binding=Get-SyncBinding $DataDir $ProjectId $HostId
    $status=Invoke-SyncLocalApi $runtime GET ('db/status?folder='+$binding.folderId) $null
    $connections=Invoke-SyncLocalApi $runtime GET 'system/connections' $null
    $peer=$connections.connections.PSObject.Properties[$runtime.peerDeviceId]
    $result=[ordered]@{connected=($null -ne $peer -and $peer.Value.connected);state=$status.state;sequence=$status.sequence;needTotalItems=$status.needTotalItems;pullErrors=$status.pullErrors;receiveOnlyTotalItems=$status.receiveOnlyTotalItems}
    foreach($name in @('globalBytes','needBytes','localBytes','globalFiles','needFiles')){if($status.PSObject.Properties.Name -contains $name){$result[$name]=[long]$status.$name}}
    if($null -ne $peer -and $peer.Value.PSObject.Properties.Name -contains 'inBytesTotal'){$result.receivedBytes=[long]$peer.Value.inBytesTotal}
    [pscustomobject]$result
}
function Start-RemoteSyncWorker {
    param([string]$DataDir,[string]$ProjectId,[string]$HostId)
    $state=Get-SyncStatePath $DataDir $ProjectId $HostId
    $runtime=Get-Content -LiteralPath (Join-Path $state 'runtime.json') -Raw|ConvertFrom-Json
    $process=Start-Process -FilePath $runtime.executable -ArgumentList @('serve','--home',('"'+$runtime.home+'"'),'--no-browser','--no-restart','--no-upgrade') -WindowStyle Hidden -PassThru
    [pscustomobject]@{process=$process;processId=$process.Id;projectId=$ProjectId;hostId=$HostId;ready=$false;reason='Worker started; tunnel and barrier still required'}
}
function Stop-RemoteSyncWorker {
    param([string]$DataDir,[string]$ProjectId,[string]$HostId)
    $state=Get-SyncStatePath $DataDir $ProjectId $HostId
    $runtime=Get-Content -LiteralPath (Join-Path $state 'runtime.json') -Raw|ConvertFrom-Json
    Invoke-SyncLocalApi $runtime POST 'system/shutdown' @{} | Out-Null
}
function Resume-RemoteSyncFolder {
    param([string]$DataDir,[string]$ProjectId,[string]$HostId)
    $state=Get-SyncStatePath $DataDir $ProjectId $HostId
    $runtime=Get-Content -LiteralPath (Join-Path $state 'runtime.json') -Raw|ConvertFrom-Json
    $binding=Get-SyncBinding $DataDir $ProjectId $HostId
    Invoke-SyncLocalApi $runtime PATCH ('config/folders/'+$binding.folderId) @{paused=$false;rescanIntervalS=3600;fsWatcherEnabled=$true} | Out-Null
}
