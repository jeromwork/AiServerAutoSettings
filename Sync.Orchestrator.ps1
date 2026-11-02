# Load Workspace and Runtime first. SSHTransport owns existing profile/key/host trust.
$script:RemoteSyncModuleRoot=$PSScriptRoot
function ConvertTo-SyncShellLiteral([string]$Value) {
    if($Value -match "['\r\n\x00]") { throw 'Unsupported shell literal' }
    "'$Value'"
}
function Invoke-SyncTransport($Transport,$Request) {
    $answer=& $Transport $Request
    if($null -ne $answer -and $answer.exitCode -eq 255 -and $Request['action'] -eq 'upload'){
        # Only our transfer artifacts may be retried automatically. Executable
        # commands can have succeeded before disconnect and must never be replayed.
        Write-SyncProgress $Request['progress'] 'reconnect' 'SSH-соединение прервано; повторяем отправку из сохранённого состояния'
        Start-Sleep -Milliseconds 350
        $answer=& $Transport $Request
    }
    if($null -eq $answer -or $answer.exitCode -ne 0) {
        $stage=[string]$Request['stage'];if(!$stage){$stage=[string]$Request['action']}
        $code=if($null -eq $answer){'нет ответа'}else{[string]$answer.exitCode}
        $detail=''
        if($null -ne $answer){
            # These are fixed installer errors, never echo arbitrary SSH stderr.
            try{$failure=$answer.stdout|ConvertFrom-Json -ErrorAction Stop}catch{$failure=$null}
            if($failure -and $failure.PSObject.Properties.Name -contains 'reason'){
                $reasons=@{'Seed hash mismatch'='Контрольные суммы распакованных файлов не совпали.';'Archive size mismatch'='Размер файла в архиве не совпал с описанием.';'Seed receipt identity mismatch'='Не совпала привязка ранее подготовленной серверной копии.';'Seed destination exists; refusing overwrite'='Серверная папка уже существует; её перезапись запрещена.'}
                if($reasons.ContainsKey([string]$failure.reason)){$detail=$reasons[[string]$failure.reason]+' '}
                elseif([string]$failure.reason -like '*No space left on device*'){$detail='На сервере недостаточно свободного места. '}
            }
            if($answer.exitCode -eq 65){$detail='Контрольная сумма отправленного архива не совпала; повреждённая копия сохранена отдельно. '}
        }
        throw ('Сбой SSH на этапе «'+$stage+'», код '+$code+'. '+$detail+'Повторите пункт 13: подготовленный архив и незавершённая отправка сохранены.')
    }
    $answer
}
function Invoke-SyncRemote($Transport,[string]$Command,[int]$TimeoutSec=30,[scriptblock]$Progress,[string]$Stage='server',[string]$Message='Проверяем сервер') {
    Write-SyncProgress $Progress $Stage $Message
    (Invoke-SyncTransport $Transport @{action='exec';command=$Command;timeoutSec=$TimeoutSec;idleTimeoutSec=300;longRunning=($TimeoutSec -gt 120);progress=$Progress;stage=$Stage;message=$Message}).stdout
}
function Get-SyncRemoteArguments($Connection) {
    " --state $(ConvertTo-SyncShellLiteral $Connection.serverState) --binary $(ConvertTo-SyncShellLiteral ($Connection.serverState+'/bin/syncthing')) --project $($Connection.projectId) --host $($Connection.hostId) --workspace $(ConvertTo-SyncShellLiteral $Connection.serverPath) --listen $($Connection.serverListen) --tunnel $($Connection.remoteForward) --gui $($Connection.serverApi)"
}
function Get-RemoteSyncServerProjects {
    param([scriptblock]$SSHTransport)
    $source=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $script:RemoteSyncModuleRoot 'server-sync.py')))
    $command="python3 -c 'import base64; exec(compile(base64.b64decode(`"$source`"), `"<installer-catalog>`", `"exec`"))' projects --base /home/remoteagents/work/projects"
    (Invoke-SyncRemote $SSHTransport $command | ConvertFrom-Json).projects
}
function Connect-RemoteSyncProject {
    param([string]$DataDir,[string]$ProjectId,[string]$HostId,[scriptblock]$SSHTransport,[scriptblock]$TunnelHook,[string]$DownloadedArchive,[scriptblock]$Progress)
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
    Invoke-SyncRemote $SSHTransport "umask 077; mkdir -p $q" -Progress $Progress -Message 'Подключаемся к серверу и проверяем папку проекта' | Out-Null
    Write-SyncProgress $Progress 'helpers' 'Передаём служебные компоненты проекта'
    foreach($file in @('server-sync.py','server-sync-runtime.py','server-install-sync.sh')) {
        $staged=Join-Path $state $file
        [IO.File]::WriteAllBytes($staged,[IO.File]::ReadAllBytes((Join-Path $script:RemoteSyncModuleRoot $file)))
        Invoke-SyncTransport $SSHTransport @{action='upload';localPath=$staged;remotePath=($connection.serverState+'/'+$file);timeoutSec=30;stage='helpers';message='Передаём служебные компоненты проекта';progress=$Progress} | Out-Null
    }
    $manifest=Join-Path $state 'seed-manifest.json'
    $attached=$binding.PSObject.Properties.Name -contains 'subscription' -and $binding.subscription
    $seed=$null
    if(!$attached -and !(Test-Path -LiteralPath $manifest)) { $seed=Export-RemoteSyncSeed $DataDir $ProjectId $HostId -Progress $Progress }
    # Probe only own project binding; never merge/reseed a pre-existing workspace.
    $probe=Invoke-SyncRemote $SSHTransport "if test -f $q/configured.json; then echo configured; elif test -f $q/seed-receipt.json; then python3 $q/server-sync.py seed-status --base '/home/remoteagents/work/projects' --project $ProjectId --host $HostId --manifest $q/seed-manifest.json; elif test -e $(ConvertTo-SyncShellLiteral $connection.serverPath); then echo existing; else echo empty; fi" -Progress $Progress -Message 'Проверяем состояние предыдущего подключения'
    if($attached) {
        if($probe.Trim() -eq 'empty'){throw 'Selected shared server project is missing; refusing local seed'}
        $answer=Invoke-SyncRemote $SSHTransport "python3 $q/server-sync.py attach --base '/home/remoteagents/work/projects' --project $ProjectId --host $HostId --manifest $q/seed-manifest.json" | ConvertFrom-Json
        if(!$answer.ok -or $answer.projectId -cne $ProjectId -or $answer.hostId -cne $HostId){throw 'Subscription identity mismatch'}
        $mode='allowlist';if($answer.manifest.PSObject.Properties.Name -contains 'scopeMode'){$mode=$answer.manifest.scopeMode}
        if(($answer.manifest.allowedRoots -join '|') -cne ($binding.allowedRoots -join '|') -or $mode -cne [string]$binding.scopeMode){throw 'Subscription scope mismatch'}
        Write-SyncJson $manifest $answer.manifest
    }
    elseif($probe.Trim() -eq 'existing') { throw 'Unbound server destination exists; inspect interrupted seed before retry' }
    elseif($probe.Trim() -eq 'empty') {
        $archive=Join-Path $state 'seed.zip'
        if(!$seed){
            Write-SyncProgress $Progress 'archive-reuse' 'Используем сохранённый архив предыдущей попытки'
            $seed=Get-RemoteSyncPreparedSeed $DataDir $ProjectId $HostId -Progress $Progress
        }
        foreach($file in @('seed.zip','seed-manifest.json')) {
            $message=if($file -eq 'seed.zip'){'Отправляем архив на сервер; после обрыва продолжим с сохранённого места'}else{'Передаём описание проекта'}
            $stage=if($file -eq 'seed.zip'){'upload'}else{'upload-manifest'}
            Invoke-SyncTransport $SSHTransport @{action='upload';localPath=(Join-Path $state $file);remotePath=($connection.serverState+'/'+$file);timeoutSec=43200;idleTimeoutSec=300;longRunning=$true;resume=($file -eq 'seed.zip');sha256=$seed.sha256;stage=$stage;message=$message;progress=$Progress} | Out-Null
        }
        Invoke-SyncRemote $SSHTransport "python3 $q/server-sync.py seed --base '/home/remoteagents/work/projects' --project $ProjectId --host $HostId --manifest $q/seed-manifest.json --archive $q/seed.zip" 43200 $Progress 'extract' 'Распаковываем и проверяем проект на сервере' | Out-Null
    }
    elseif($probe.Trim() -notin @('configured','seeded')){throw 'Неизвестное состояние серверного проекта; существующие данные сохранены'}
    Invoke-SyncRemote $SSHTransport "bash $q/server-install-sync.sh $q/bin" 43200 $Progress 'sync-install' 'Подготавливаем серверную синхронизацию' | Out-Null
    Write-SyncProgress $Progress 'sync-install' 'Подготавливаем синхронизацию Windows'
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
    $nameArgument=if(!$attached){' --name-base64 '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFileName($binding.sourcePath.TrimEnd('\'))))}else{''}
    Invoke-SyncRemote $SSHTransport "python3 $q/server-sync.py register --base '/home/remoteagents/work/projects' --project $ProjectId --host $HostId --manifest $q/seed-manifest.json$nameArgument" | Out-Null
    Write-SyncProgress $Progress 'tunnel' 'Открываем защищённый канал синхронизации'
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
    Invoke-RemoteSyncBarrier -DataDir $DataDir -ProjectId $ProjectId -HostId $HostId -SSHTransport $SSHTransport -TimeoutSec 43200 -Progress $Progress -InitialConnect
}
function Invoke-RemoteSyncBarrier {
    param([string]$DataDir,[string]$ProjectId,[string]$HostId,[scriptblock]$SSHTransport,[int]$TimeoutSec=20,[scriptblock]$Progress,[switch]$InitialConnect,[int]$IdleTimeoutSec=300)
    $state=Get-SyncStatePath $DataDir $ProjectId $HostId
    try {
        $c=Get-Content -LiteralPath (Join-Path $state 'connection.json') -Raw|ConvertFrom-Json
        $q=ConvertTo-SyncShellLiteral $c.serverState
        $name='snapshot-'+[guid]::NewGuid().ToString('N')+'.json'
        $remote=$c.serverState+'/'+$name;$local=Join-Path $state $name
        $snapshot="python3 $q/server-sync.py snapshot --base '/home/remoteagents/work/projects' --project $ProjectId --host $HostId --manifest $q/seed-manifest.json --output $(ConvertTo-SyncShellLiteral $remote) --refresh-ignores"
        $operationTimeout=if($InitialConnect){43200}else{30}
        Invoke-SyncRemote $SSHTransport $snapshot $operationTimeout $Progress 'snapshot' 'Проверяем серверный снимок проекта' | Out-Null
        $scanCommand="python3 $q/server-sync-runtime.py scan"+(Get-SyncRemoteArguments $c)
        if($InitialConnect){$scanCommand+=' --operation-timeout 43200'}
        Invoke-SyncRemote $SSHTransport $scanCommand $operationTimeout $Progress 'server-scan' 'Сканируем серверную копию для синхронизации' | Out-Null
        $downloadTimeout=if($InitialConnect){43200}else{20}
        Invoke-SyncTransport $SSHTransport @{action='download';remotePath=$remote;localPath=$local;timeoutSec=$downloadTimeout;idleTimeoutSec=300;stage='snapshot-download';message='Получаем описание серверного снимка';progress=$Progress} | Out-Null
        $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSec);$lastActivity=[DateTime]::UtcNow;$lastSignature=''
        do {
            $health=Get-RemoteSyncLiveHealth $DataDir $ProjectId $HostId
            if($health.receiveOnlyTotalItems -gt 0){throw 'В принимающей Windows-копии есть локальные изменения. Проверьте копию; автоматический сброс изменений не выполнялся.'}
            if($health.pullErrors -gt 0){throw 'Syncthing сообщает об ошибке получения файлов. Проверьте доступное место и состояние принимающей Windows-копии; затем повторите пункт 13.'}
            $signature="$($health.state):$($health.needTotalItems):$($health.sequence)"
            if($health.PSObject.Properties.Name -contains 'needBytes'){$signature+=':'+$health.needBytes}
            if($health.PSObject.Properties.Name -contains 'receivedBytes'){$signature+=':'+$health.receivedBytes}
            if($signature -cne $lastSignature){$lastActivity=[DateTime]::UtcNow;$lastSignature=$signature}
            $done=-1L;$total=-1L
            if($health.PSObject.Properties.Name -contains 'globalBytes' -and $health.globalBytes -gt 0){$total=[long]$health.globalBytes;$done=[Math]::Max(0,$total-[long]$health.needBytes);if($health.needTotalItems){$done=[Math]::Min($done,$total-1)}}
            Write-SyncProgress $Progress 'receive' 'Получаем отдельную копию Windows; затем проверим совпадение файлов' $done $total
            # Hash the replica only when the live receiver has finished. Repeated
            # full hashing while bytes are still arriving is slow and misleading.
            if($health.connected -and $health.state -eq 'idle' -and $health.needTotalItems -eq 0){
                Write-SyncProgress $Progress 'verify' 'Проверяем совпадение серверных и Windows-файлов'
            $check=Test-RemoteSyncBarrier -DataDir $DataDir -ProjectId $ProjectId -HostId $HostId -SnapshotPath $local -HealthProbe {Get-RemoteSyncLiveHealth $DataDir $ProjectId $HostId} -Progress $Progress
            }else{$check=[pscustomobject]@{ready=$false;projectId=$ProjectId;hostId=$HostId;reason='Windows replica is still synchronizing';replicaPath=$null;snapshotId=$null}}
            if($check.ready -or [DateTime]::UtcNow -ge $deadline) {break}
            if($InitialConnect -and ([DateTime]::UtcNow-$lastActivity).TotalSeconds -gt $IdleTimeoutSec){throw 'Нет изменений состояния синхронизации Windows; повторите пункт 13. Архив и полученные блоки сохранены.'}
            Start-Sleep -Milliseconds 1000
        } while($true)
        $check | Add-Member -NotePropertyName fresh -NotePropertyValue ([bool]$check.ready) -PassThru
    } catch {
        $reason=if($InitialConnect){$_.Exception.Message}else{'Fresh sync barrier failed'}
        [pscustomobject]@{ready=$false;fresh=$false;projectId=$ProjectId;hostId=$HostId;reason=$reason;replicaPath=$null;snapshotId=$null}
    }
}
