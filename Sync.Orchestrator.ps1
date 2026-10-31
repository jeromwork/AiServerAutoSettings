# Load Workspace and Runtime first. SSHTransport owns existing profile/key/host trust.
$script:RemoteSyncModuleRoot=$PSScriptRoot
function ConvertTo-SyncShellLiteral([string]$Value) {
    if($Value -match "['\r\n\x00]") { throw 'Unsupported shell literal' }
    "'$Value'"
}
function Invoke-SyncTransport($Transport,$Request) {
    $answer=& $Transport $Request
    if($null -eq $answer -or $answer.exitCode -ne 0) { throw 'Sync SSH transport failed; inspect sanitized transport status' }
    $answer
}
function Invoke-SyncRemote($Transport,[string]$Command) {
    (Invoke-SyncTransport $Transport @{action='exec';command=$Command;timeoutSec=30}).stdout
}
function Get-SyncRemoteArguments($Connection) {
    " --state $(ConvertTo-SyncShellLiteral $Connection.serverState) --binary $(ConvertTo-SyncShellLiteral ($Connection.serverState+'/bin/syncthing')) --project $($Connection.projectId) --host $($Connection.hostId) --workspace $(ConvertTo-SyncShellLiteral $Connection.serverPath) --listen $($Connection.serverListen) --tunnel $($Connection.remoteForward) --gui $($Connection.serverApi)"
}
function Connect-RemoteSyncProject {
    param([string]$DataDir,[string]$ProjectId,[string]$HostId,[scriptblock]$SSHTransport,[scriptblock]$TunnelHook,[string]$DownloadedArchive)
    $binding=Get-SyncBinding $DataDir $ProjectId $HostId
    $state=Get-SyncStatePath $DataDir $ProjectId $HostId
    $connectionFile=Join-Path $state 'connection.json'
    if(Test-Path -LiteralPath $connectionFile) {
        $connection=Get-Content -LiteralPath $connectionFile -Raw|ConvertFrom-Json
    } else {
        # Persist allocation before remote mutations so retries use identical paths/ports.
        $port=Get-Random -Minimum 30000 -Maximum 50000
        $connection=[pscustomobject]@{projectId=$ProjectId;hostId=$HostId;serverState="/home/remoteagents/.local/share/remote-agents-sync/$ProjectId/$HostId";serverPath="/home/remoteagents/work/projects/$ProjectId";windowsListen=$port;localForward=($port+1);windowsApi=($port+2);serverListen=($port+3);remoteForward=($port+4);serverApi=($port+5)}
        Write-SyncJson $connectionFile $connection
    }
    $q=ConvertTo-SyncShellLiteral $connection.serverState
    Invoke-SyncRemote $SSHTransport "umask 077; mkdir -p $q" | Out-Null
    foreach($file in @('server-sync.py','server-sync-runtime.py','server-install-sync.sh')) {
        $staged=Join-Path $state $file
        [IO.File]::WriteAllBytes($staged,[IO.File]::ReadAllBytes((Join-Path $script:RemoteSyncModuleRoot $file)))
        Invoke-SyncTransport $SSHTransport @{action='upload';localPath=$staged;remotePath=($connection.serverState+'/'+$file);timeoutSec=30} | Out-Null
    }
    $manifest=Join-Path $state 'seed-manifest.json'
    if(!(Test-Path -LiteralPath $manifest)) { Export-RemoteSyncSeed $DataDir $ProjectId $HostId | Out-Null }
    # Probe only own project binding; never merge/reseed a pre-existing workspace.
    $probe=Invoke-SyncRemote $SSHTransport "if test -f $q/configured.json; then echo configured; elif test -e $(ConvertTo-SyncShellLiteral $connection.serverPath); then echo existing; else echo empty; fi"
    if($probe.Trim() -eq 'existing') { throw 'Unbound server destination exists; inspect interrupted seed before retry' }
    if($probe.Trim() -eq 'empty') {
        foreach($file in @('seed.zip','seed-manifest.json')) {
            Invoke-SyncTransport $SSHTransport @{action='upload';localPath=(Join-Path $state $file);remotePath=($connection.serverState+'/'+$file);timeoutSec=120} | Out-Null
        }
        Invoke-SyncRemote $SSHTransport "python3 $q/server-sync.py seed --base '/home/remoteagents/work/projects' --project $ProjectId --host $HostId --manifest $q/seed-manifest.json --archive $q/seed.zip" | Out-Null
    }
    Invoke-SyncRemote $SSHTransport "bash $q/server-install-sync.sh $q/bin" | Out-Null
    $exe=Install-RemoteSyncBinary -DataDir $DataDir -DownloadedArchive $DownloadedArchive
    $runtimePath=Join-Path $state 'runtime.json'
    $remoteArgs=Get-SyncRemoteArguments $connection
    if(!(Test-Path -LiteralPath $runtimePath)) {
        $win=Initialize-RemoteSyncWorker -DataDir $DataDir -ProjectId $ProjectId -HostId $HostId -Executable $exe -ListenPort $connection.windowsListen -PeerTunnelPort $connection.localForward -GuiPort $connection.windowsApi
        $remote=(Invoke-SyncRemote $SSHTransport "python3 $q/server-sync-runtime.py identity$remoteArgs"|ConvertFrom-Json)
        if($probe.Trim() -ne 'configured') {
            Invoke-SyncRemote $SSHTransport "python3 $q/server-sync-runtime.py configure$remoteArgs --manifest $q/seed-manifest.json --peer $($win.deviceId)" | Out-Null
        }
        Initialize-RemoteSyncWorker -DataDir $DataDir -ProjectId $ProjectId -HostId $HostId -Executable $exe -PeerDeviceId $remote.deviceId -ListenPort $connection.windowsListen -PeerTunnelPort $connection.localForward -GuiPort $connection.windowsApi | Out-Null
    }
    $tunnel=& $TunnelHook @{projectId=$ProjectId;hostId=$HostId;localForwardPort=$connection.localForward;serverListenPort=$connection.serverListen;remoteForwardPort=$connection.remoteForward;windowsListenPort=$connection.windowsListen}
    if(!$tunnel.ok) { throw 'Private sync tunnel not confirmed' }
    # Server own service is long-lived; API health makes repeated connect a no-op.
    $launch="python3 $q/server-sync-runtime.py health$remoteArgs >/dev/null 2>&1 || (nohup python3 $q/server-sync-runtime.py start$remoteArgs >$q/worker.log 2>&1 </dev/null &); echo started"
    Invoke-SyncRemote $SSHTransport $launch | Out-Null
    try { Get-RemoteSyncLiveHealth $DataDir $ProjectId $HostId | Out-Null } catch { Start-RemoteSyncWorker $DataDir $ProjectId $HostId | Out-Null }
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    do {
        try {
            Invoke-SyncRemote $SSHTransport "python3 $q/server-sync-runtime.py resume$remoteArgs" | Out-Null
            Resume-RemoteSyncFolder $DataDir $ProjectId $HostId
            break
        } catch { if([DateTime]::UtcNow -gt $deadline){throw};Start-Sleep -Milliseconds 400 }
    } while($true)
    Invoke-RemoteSyncBarrier -DataDir $DataDir -ProjectId $ProjectId -HostId $HostId -SSHTransport $SSHTransport
}
function Invoke-RemoteSyncBarrier {
    param([string]$DataDir,[string]$ProjectId,[string]$HostId,[scriptblock]$SSHTransport,[int]$TimeoutSec=20)
    $state=Get-SyncStatePath $DataDir $ProjectId $HostId
    try {
        $c=Get-Content -LiteralPath (Join-Path $state 'connection.json') -Raw|ConvertFrom-Json
        $q=ConvertTo-SyncShellLiteral $c.serverState
        $name='snapshot-'+[guid]::NewGuid().ToString('N')+'.json'
        $remote=$c.serverState+'/'+$name;$local=Join-Path $state $name
        $snapshot="python3 $q/server-sync.py snapshot --base '/home/remoteagents/work/projects' --project $ProjectId --host $HostId --manifest $q/seed-manifest.json --output $(ConvertTo-SyncShellLiteral $remote) --refresh-ignores"
        Invoke-SyncRemote $SSHTransport $snapshot | Out-Null
        Invoke-SyncRemote $SSHTransport ("python3 $q/server-sync-runtime.py scan"+(Get-SyncRemoteArguments $c)) | Out-Null
        Invoke-SyncTransport $SSHTransport @{action='download';remotePath=$remote;localPath=$local;timeoutSec=20} | Out-Null
        $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSec)
        do {
            $check=Test-RemoteSyncBarrier -DataDir $DataDir -ProjectId $ProjectId -HostId $HostId -SnapshotPath $local -HealthProbe {Get-RemoteSyncLiveHealth $DataDir $ProjectId $HostId}
            if($check.ready -or [DateTime]::UtcNow -ge $deadline) {break}
            Start-Sleep -Milliseconds 300
        } while($true)
        $check | Add-Member -NotePropertyName fresh -NotePropertyValue ([bool]$check.ready) -PassThru
    } catch {
        [pscustomobject]@{ready=$false;fresh=$false;projectId=$ProjectId;hostId=$HostId;reason='Fresh sync barrier failed';replicaPath=$null;snapshotId=$null}
    }
}
