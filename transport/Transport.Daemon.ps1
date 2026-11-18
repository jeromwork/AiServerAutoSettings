#requires -Version 5.1
[CmdletBinding()]
param([Alias('Home')][string]$TransportHome=(Join-Path $env:LOCALAPPDATA 'RemoteAgents'),[int]$ParentPid=0)
# Persisted pipe output has a known encoding on Windows PowerShell 5.1 too.
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
$root=(Get-TransportHome $TransportHome);$engine=$null;$tunnelChildren=@{};$probes=@{};$rows=@();$active=$null;$confirmed=$false;$errorText='Запуск';$network=$null;$memory=$null;$secret=$null
$parent=$null;$mutex=$null;$locked=$false;$settings=$null;$paths=$null;$rankPending=$false;$rankTags=@();$rankQueue=$null;$exitCode=0
$pin=[pscustomobject]@{mode='auto';tag=$null};$nextControl=[DateTime]::MinValue;$revision='';$reloadJob=$null;$reloadError=$null;$failedRevision=$null;$pendingRevision=$null;$nextReload=[DateTime]::MinValue
$portConflict=$null;$bindRetry=$null
$diagnosticContext=$null;$liveDeferred=@();$tunnelLiveAt=[DateTime]::MinValue;$daemonStarted=[DateTime]::Now;$checkingSince=[DateTime]::UtcNow;$stopping=$false
try{$daemonStarted=(Get-Process -Id $PID).StartTime}catch{}
$lastStatus=[DateTime]::MinValue;$nextActive=[DateTime]::MinValue;$nextRank=[DateTime]::MinValue;$nextNetwork=[DateTime]::MinValue;$retryAt=[DateTime]::MinValue;$nextLive=[DateTime]::MinValue
function Test-TransportStop {
    try{if([IO.File]::Exists((Join-Path $root 'stop')) -or [IO.File]::Exists((Join-Path $root 'state/transport.stop'))){return $true}}catch{}
    if($parent){try{return $parent.HasExited}catch{return $true}};return $false
}
function Stop-TransportProbes {
    foreach($probe in @($probes.Values)){Stop-TransportProbe $probe};$probes.Clear();$script:liveDeferred=@()
}
function Publish-TransportStatus {
    $speed=$null;$row=$rows|Where-Object {$_.tag -eq $active}|Select-Object -First 1
    if($confirmed -and $row){$speed=$row.kbps}
    $alive=$false;if($engine){try{$alive=-not $engine.Process.HasExited}catch{}}
    $id=$null;if($network){$id=$network.id}
    $summary='нет связи: '+$(if($errorText){$errorText}else{'нет проверенного пути'})
    if($alive -and $confirmed -and $row){$summary=$row.title;if($null -ne $speed){$summary+=' · '+([Math]::Round([double]$speed,1)).ToString([Globalization.CultureInfo]::InvariantCulture)+' КБ/с'}}
    if($settings -and $settings.LocalWeb.conflict){$summary+=' · Happier: '+$settings.LocalWeb.conflict.message}
    $isOk=[bool]($alive -and $confirmed)
    if($isOk){$script:checkingSince=$null}
    $phase=if($isOk){'ok'}elseif($stopping){'stopped'}elseif($script:checkingSince){'checking'}else{'failed'}
    Write-TransportJson (Join-Path $root 'status/transport.json') ([ordered]@{endpoints=@($paths.Outbounds|Where-Object {$_.server -and $_.server -notin @('127.0.0.1','::1')}|ForEach-Object {[string]$_.server}|Sort-Object -Unique);ports=$(if($settings){Get-TransportConfiguredPorts ([pscustomobject]$settings.Options) $settings.Profile}else{$null});localWeb=$(if($settings){$settings.LocalWeb}else{$null});lan=$(if($settings){$settings.Lan}else{$null});helper=$(if($settings){Get-TransportHelperStatus $settings $active $paths.Outbounds}else{$null});portConflict=$portConflict;retryAt=$retryAt.ToUniversalTime().ToString('o');configRevision=$revision;fatal=($exitCode -ne 0);summary=$summary;ok=[bool]($alive -and $confirmed);phase=$phase;checkingSince=$(if($script:checkingSince){$script:checkingSince.ToString('o')}else{$null});active=$active;kbps=$speed;network=$id;metered=$metered;mode=$pin.mode;pinnedTag=$pin.tag;candidates=@($rows);configError=$reloadError;updatedAt=[DateTime]::UtcNow.ToString('o');error=$errorText})
    $script:lastStatus=[DateTime]::UtcNow
}
function Set-DaemonNextActive {
    $interval=$settings.Options.activeIntervalSec;if($metered -ne $false){$interval=$settings.Options.meteredActiveIntervalSec}
    $script:nextActive=[DateTime]::UtcNow.AddSeconds([double]$interval)
}
function Switch-TransportActive([string]$Tag,[bool]$Verified) {
    if($pin.mode -eq 'pinned' -and $Tag -ne $pin.tag){return $false}
    if(-not $Tag){$script:confirmed=$false;$script:errorText='Нет проверенного пути';return $false}
    try{
        $target=$Tag;if($Tag -notin @($paths.Candidates|ForEach-Object {$_.tag})){$target='unavailable';$Verified=$false}
        Set-TransportSelector $settings.Options $secret $target
        $script:active=$Tag;$script:confirmed=$Verified
        # A successful live/rank probe already proves this path. Schedule the next health check normally.
        if($Verified){Set-DaemonNextActive}else{$script:nextActive=[DateTime]::UtcNow}
        if($Verified){$script:errorText=$null;$script:bindRetry=$null;$script:portConflict=$null}elseif($pin.mode -eq 'pinned'){$script:errorText='Закреплённый путь ещё не проверен или недоступен'}else{$script:errorText='Путь из памяти ещё не проверен'}
        Write-TransportLog $root 'switch';return $true
    }catch{$script:confirmed=$false;$script:errorText='Не удалось переключить selector';Write-TransportLog $root 'api-failed' (Get-TransportErrorDetail $_);return $false}
}
function Fail-TransportActive([bool]$RequestRank=$true) {
    $script:confirmed=$false;$script:errorText='Активный путь не прошёл пробу или завершился'
    if($pin.mode -eq 'pinned'){$script:errorText='Закреплённый путь не работает';return}
    $best=Get-TransportBest $rows
    if($best){[void](Switch-TransportActive $best.tag $true)}else{
        $best=Get-TransportBest $rows -Remembered
        if($best){[void](Switch-TransportActive $best.tag $false)}
    }
    if($RequestRank){$script:nextRank=[DateTime]::UtcNow}
}
function Write-DaemonWizardProgress([string]$Text) {
    # Explicit opt-in only for the wizard's short-lived preflight. Never forward raw subprocess output.
    if($env:REMOTEAGENTS_WIZARD_PROGRESS){try{[IO.File]::AppendAllText($env:REMOTEAGENTS_WIZARD_PROGRESS,((@{text=$Text}|ConvertTo-Json -Compress)+"`n"),(New-Object Text.UTF8Encoding($false)))}catch{}}
}
function Get-DaemonProbeKey([string]$Tag,[string]$Purpose) {
    if($Purpose -eq 'rank'){return 'rank/'+$Tag};return 'health/'+$Tag
}
function Test-DaemonHealthProbe([string]$Tag) {$probes.ContainsKey((Get-DaemonProbeKey $Tag 'active'))}
function Start-DaemonProbe($Candidate,[long]$Bytes,[string]$Purpose) {
    $key=Get-DaemonProbeKey $Candidate.tag $Purpose
    if($probes.ContainsKey($key)){return}
    Write-DaemonWizardProgress ('Проверяю вариант связи: '+$Candidate.title+'… (до '+$settings.Options.probeTimeoutSec+' с)')
    try{$probes[$key]=Start-TransportProbe $settings.Profile $Candidate $Bytes $settings.Options $Purpose}
    catch{
        $row=$rows|Where-Object {$_.tag -eq $Candidate.tag}|Select-Object -First 1;if($Purpose -eq 'rank'){$row|Add-Member -Force rankState 'fail'}else{$row.state='fail'};$row.checkedAt=[DateTime]::UtcNow.ToString('o')
        if($Candidate.tag -eq $active){if($Purpose -eq 'rank'){$script:nextActive=[DateTime]::UtcNow}else{Fail-TransportActive}}
        $detail=New-TransportDiagnostic $null $Candidate.tag 'probe-start-failed'
        $row|Add-Member -Force diagnostic $detail
        Write-TransportLog $root 'process-failed' $detail
    }
}
function Start-TransportLiveness {
    # Пока нет подтверждённого пути, короткая проба живости (activeProbeBytes) идёт по всем кандидатам сразу:
    # мёртвые пути стоят один таймаут на всех, первый ответивший становится активным. Замер скорости (rank) — после.
    # OpenSSH -D candidates need their own login after the engine start: they keep the former 1 s pause.
    $tunnels=@($paths.Tunnels|ForEach-Object {$_.tag})
    foreach($c in $paths.Candidates){if(-not (Test-DaemonHealthProbe $c.tag)){
        if($c.tag -in $tunnels -and [DateTime]::UtcNow -lt $tunnelLiveAt){$script:liveDeferred+=,$c}else{Start-DaemonProbe $c ([long]$settings.Options.activeProbeBytes) 'live'}
    }}
    $interval=$settings.Options.activeIntervalSec;if($metered -ne $false){$interval=$settings.Options.meteredActiveIntervalSec}
    $script:nextLive=[DateTime]::UtcNow.AddSeconds([double]$interval)
}
function Start-TransportRanking {
    $tags=@(Get-TransportRankTags $rows $paths.Candidates $settings.Options $metered)
    # Пути проверяются по очереди (rankConcurrency, по умолчанию 1): параллельные пробы делят один канал
    # и показывают долю канала, а не скорость пути.
    $script:rankTags=$tags;$script:rankPending=$true
    $script:rankQueue=New-Object Collections.Queue
    foreach($c in $paths.Candidates){if($c.tag -in $tags){$script:rankQueue.Enqueue($c)}}
    Start-TransportRankNext
}
function Start-TransportRankNext {
    while($script:rankQueue -and $script:rankQueue.Count -gt 0 -and @($probes.Values|Where-Object {$_.purpose -eq 'rank'}).Count -lt [int]$settings.Options.rankConcurrency){
        $c=$script:rankQueue.Dequeue()
        Start-DaemonProbe $c ([long]$settings.Options.rankProbeBytes) 'rank'
    }
    $script:nextRank=[DateTime]::UtcNow.AddSeconds([double]$settings.Options.rankIntervalSec)
}
function Wait-TransportEngineReady([int]$Port,[int]$TimeoutMs) {
    # sing-box 1.14 binds the Clash API after all inbounds: its listener means the probe ports accept connections.
    # Listener table, not a connect: no stray connection, and no ~1 s refused-connect retries of Windows loopback.
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.ElapsedMilliseconds -lt $TimeoutMs -and -not $engine.Process.HasExited){
        try{if(@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()|Where-Object {$_.Port -eq $Port}).Count){return $true}}catch{return $false}
        Start-Sleep -Milliseconds 50
    }
    return $false
}
function Reset-DaemonPorts {
    # Старые туннели тоже держат локальные порты; проверяем после их остановки.
    Stop-TransportProbes
    foreach($child in @($tunnelChildren.Values)){Stop-TransportProcess $child};$tunnelChildren.Clear()
    $before=Get-TransportConfiguredPorts ([pscustomobject]$settings.Options) $settings.Profile
    $probeCount=0;$socksCount=0
    foreach($c in $paths.AllCandidates){if($c.port -gt 0){$probeCount=[Math]::Max($probeCount,([int]$c.port-[int]$settings.Options.probePortBase+1))}}
    foreach($o in $paths.Outbounds){if($o.type -eq 'socks' -and $o.server -eq '127.0.0.1'){$socksCount=[Math]::Max($socksCount,([int]$o.server_port-[int]$settings.Options.socksPortBase+1))}}
    $inputRevision=Get-TransportRevision $root
    $script:settings=Resolve-TransportPorts $root $settings $probeCount $socksCount
    $script:paths=Get-TransportCandidates $settings $root
    # Смена HostName в сохранённых argv профиля меняет его хэш, но уже применена нами.
    if($inputRevision -ceq $revision){$script:revision=Get-TransportRevision $root;$script:observedRevision=$revision}
    return (-not (Test-TransportPortsEqual $before (Get-TransportConfiguredPorts ([pscustomobject]$settings.Options) $settings.Profile)))
}
function Get-DaemonRestartDelay($Detail) {
    if($Detail.portConflict){
        try{if(Reset-DaemonPorts){$script:bindRetry=$null}}catch{Write-TransportLog $root 'process-failed' (Get-TransportErrorDetail $_)}
    }
    Get-TransportRestartDelay ([double]$settings.Options.restartDelaySec) $(if($bindRetry){$bindRetry.failures}else{0})
}
function Start-TransportEngine {
    [void](Reset-DaemonPorts)
    $script:confirmed=$false
    $interface='';if($network -and $settings.Options.bindPhysical){$interface=[string]$network.interface}
    if($settings.Options.bindPhysical -and -not $interface){throw 'Физический интерфейс недоступен'}
    $cfg=New-TransportConfig $settings $paths $secret $active $interface
    $file=Join-Path $root 'state/transport-sing-box.json';Write-TransportJson $file $cfg -Private
    # Валидация до запуска; stdout/stderr не публикуются, т.к. могут содержать адреса и секреты.
    Test-TransportConfigFile $settings.Options.singBoxPath $file
    $script:engine=Start-TransportProcess $settings.Options.singBoxPath @('run','-c',$file)
    Save-TransportOwner $root 'transport' $engine $settings.Options.singBoxPath $file
    foreach($tunnel in $paths.Tunnels){
        if($tunnelChildren.ContainsKey($tunnel.tag)){continue}
        $a=@($tunnel.arguments)
        if($settings.Options.bindPhysical -and $tunnel.bind){if(-not $network.ip){throw 'Нет физического IPv4 для OpenSSH'};$a+=@('-b',[string]$network.ip)}
        $script:tunnelChildren[$tunnel.tag]=Start-TransportProcess $settings.Profile.sshExecutable ($a+@([string]$tunnel.target))
    }
    $script:tunnelLiveAt=[DateTime]::UtcNow.AddSeconds(1)
    # Probes start as soon as sing-box listens (was a fixed 1 s pause, plus up to one 300 ms loop turn); the pause stays
    # only when readiness is not visible within 3 s.
    $ready=Wait-TransportEngineReady ([int]$settings.Options.apiPort) 3000
    # Успешный запуск сбрасывает серию bind, даже если сеть ещё не прошла пробу.
    if($ready -and -not $engine.Process.HasExited){
        # Чужой слушатель API ещё не доказывает запуск нашего процесса. Подтверждаем API его секретом.
        try{
            $target=($cfg.outbounds|Where-Object {$_.tag -eq 'active'}|Select-Object -First 1).default
            Set-TransportSelector $settings.Options $secret $target
            $script:bindRetry=$null;$script:portConflict=$null
        }catch{}
    }
    $at=if($ready){[DateTime]::MinValue}else{[DateTime]::UtcNow.AddSeconds(1)}
    $script:nextRank=[DateTime]::UtcNow.AddSeconds(1);$script:nextActive=$at;$script:nextLive=$at;Write-TransportLog $root 'ready'
    if($ready){Write-DaemonWizardProgress ('· модуль связи готов '+[int]([DateTime]::Now-$daemonStarted).TotalMilliseconds+' мс от запуска процесса')}
}
$metered=$null
try{
    [void][IO.Directory]::CreateDirectory($root)
    # Имя mutex зависит только от Home, не от серверных адресов. Второй экземпляр не портит статус первого.
    $hash=Get-TransportFingerprint 'local' $root.ToLowerInvariant();$mutex=New-Object Threading.Mutex($false,('Global\RemoteAgentsTransport-'+$hash))
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'Транспорт уже запущен'}
    Write-TransportLog $root 'start'
    if($ParentPid -gt 0){$parent=[Diagnostics.Process]::GetProcessById($ParentPid);[void]$parent.Handle}
    # Keep the input revision even when settings/cache/candidates/network initialization fails.
    $revision=Get-TransportRevision $root
    $settings=Read-TransportSettings $root;Sync-TransportEntryCache $settings $root;$revision=Get-TransportRevision $root;$settings=Read-TransportSettings $root
    $paths=Get-TransportCandidates $settings $root;$secret=Get-TransportSecret $root;$memory=Read-TransportMemory $root
    $diagnosticContext=@(Get-TransportDiagnosticContext $settings $root)
    $network=Get-TransportNetwork;$metered=Get-TransportMetered $settings.Options
    # Just detected: the loop's 5 s network check need not repeat it before the engine starts (CIM on Windows).
    $nextNetwork=[DateTime]::UtcNow.AddSeconds(5)
    $observedRevision=$revision
    $rows=@(Get-TransportRemembered $memory $network.id $paths.AllCandidates)
    $pin=Read-TransportPin $root;$active=Get-TransportSelection $pin $rows $paths.Candidates
    Publish-TransportStatus
    while(-not (Test-TransportStop)){
        $now=[DateTime]::UtcNow
        # Короткий управляющий цикл: pin не ждёт сетевых проб или SSH -G при reload.
        if($now -ge $nextControl){
            $nextControl=$now.AddSeconds(1)
            try{$newPin=Read-TransportPin $root}catch{$newPin=[pscustomobject]@{mode='pinned';tag='invalid-pin'}; $errorText='Неверный transport-pin.json'}
            if($newPin.mode -ne $pin.mode -or $newPin.tag -ne $pin.tag -or ($newPin.mode -eq 'pinned' -and $active -ne $newPin.tag)){
                $pin=$newPin;$desired=Get-TransportSelection $pin $rows $paths.Candidates $active
                $row=$rows|Where-Object {$_.tag -eq $desired}|Select-Object -First 1
                if($engine){[void](Switch-TransportActive $desired ([bool]($row -and $row.state -eq 'ok')))}else{$active=$desired;$confirmed=$false}
                $nextActive=$now;$nextRank=$now;$checkingSince=$now
            }
            if(-not $reloadJob -and $now -ge $nextReload){
                try{
                    $newRevision=Get-TransportRevision $root
                    if($newRevision -ne $observedRevision){$bindRetry=$null;$portConflict=$null;$retryAt=$now;$observedRevision=$newRevision}
                    if($newRevision -eq $revision){$reloadError=$null}
                    if($newRevision -ne $revision){
                        $pendingRevision=$newRevision
                        $reloadJob=Start-Job -ArgumentList $PSScriptRoot,$root,$secret,$network.interface,$newRevision -ScriptBlock {
                            param($scripts,$homeRoot,$apiSecret,$nic,$rev)
                            . (Join-Path $scripts 'Transport.Common.ps1')
                            $newSettings=Read-TransportSettings $homeRoot;Sync-TransportEntryCache $newSettings $homeRoot;$stableRevision=Get-TransportRevision $homeRoot;$newSettings=Read-TransportSettings $homeRoot;$newPaths=Get-TransportCandidates $newSettings $homeRoot
                            $probeCount=@($newPaths.AllCandidates|Where-Object {$_.port -gt 0}).Count;$socksCount=$probeCount
                            $newSettings=Resolve-TransportPorts $homeRoot $newSettings $probeCount $socksCount -Preview;$newPaths=Get-TransportCandidates $newSettings $homeRoot
                            $newConfig=New-TransportConfig $newSettings $newPaths $apiSecret 'unavailable' $nic
                            $checkFile=Join-Path $homeRoot 'state/transport-pending.json';Write-TransportJson $checkFile $newConfig -Private
                            Test-TransportConfigFile $newSettings.Options.singBoxPath $checkFile
                            if((Get-TransportRevision $homeRoot) -ne $stableRevision){throw 'Конфиг изменился во время проверки'}
                            [pscustomobject]@{Settings=$newSettings;Paths=$newPaths;Revision=$stableRevision}
                        }
                    }
                }catch{$reloadError='Изменённый конфиг не прочитан; сохранена рабочая конфигурация'}
            }
        }
        if($reloadJob -and $reloadJob.State -in @('Completed','Failed','Stopped')){
            try{
                $result=Receive-Job $reloadJob -ErrorAction Stop
                if(-not $result -or $reloadJob.State -ne 'Completed'){throw 'Reload failed'}
                Stop-TransportProbes;$rankPending=$false;$rankQueue=$null
                Stop-TransportProcess $engine;$engine=$null;$settings=$result.Settings;$paths=$result.Paths;$revision=$result.Revision
                $diagnosticContext=@(Get-TransportDiagnosticContext $settings $root)
                $rows=@(Get-TransportRemembered $memory $network.id $paths.AllCandidates)
                $active=Get-TransportSelection $pin $rows $paths.Candidates $active;$confirmed=$false;$retryAt=$now
                $bindRetry=$null;$portConflict=$null
                Start-TransportEngine;$reloadError=$null;$errorText='Конфиг применён; ожидается проверка пути';$checkingSince=$now
                Write-TransportLog $root 'restart'
            }catch{$reloadError='Новый конфиг не применён; проверьте списки узлов и кэш секретов';$nextReload=[DateTime]::UtcNow.AddSeconds(5)}
            finally{Remove-Job $reloadJob -Force;$reloadJob=$null}
        }
        if($now -ge $nextNetwork){
            $nextNetwork=$now.AddSeconds(5);$newNetwork=Get-TransportNetwork;$newMetered=Get-TransportMetered $settings.Options
            $changed=($newNetwork.id -ne $network.id -or $newNetwork.interface -ne $network.interface -or $newNetwork.ip -ne $network.ip)
            $costChanged=($newMetered -ne $metered);$metered=$newMetered
            if($changed){
                Stop-TransportProbes;$rankPending=$false;$rankQueue=$null;$network=$newNetwork
                $rows=@(Get-TransportRemembered $memory $network.id $paths.AllCandidates);$confirmed=$false
                $best=Get-TransportBest $rows -Remembered
                if($best -and $pin.mode -eq 'auto'){
                    if($engine -and -not $settings.Options.bindPhysical){[void](Switch-TransportActive $best.tag $false)}
                    else{$active=$best.tag;$errorText='Путь из памяти ещё не проверен'}
                }
                $checkingSince=$now;$nextRank=$now;$nextActive=$now;$nextLive=$now;Write-TransportLog $root 'network-change'
                # bind_interface и OpenSSH -b задаются на сокете. При смене NIC нужен новый процесс;
                # обычный failover selector никогда не перезапускает sing-box.
                if($settings.Options.bindPhysical){
                    Stop-TransportProcess $engine;$engine=$null
                    foreach($child in @($tunnelChildren.Values)){Stop-TransportProcess $child};$tunnelChildren.Clear();$retryAt=$now
                }
                if(-not $newNetwork.available){$errorText='Не удалось определить физическую сеть';Write-TransportLog $root 'network-unavailable'}
            }elseif($costChanged){Stop-TransportProbes;$rankPending=$false;$rankQueue=$null;$nextRank=$now;$nextActive=$now}
        }
        if($engine -and $engine.Process.HasExited){
            $detail=New-TransportDiagnostic $engine 'sing-box' 'process-exited' $diagnosticContext
            Write-TransportLog $root 'process-failed' $detail
            foreach($row in $rows){if($row.enabled){$perRow=Copy-TransportObject $detail;$perRow.candidate=$row.tag;$row|Add-Member -Force diagnostic $perRow}}
            Stop-TransportProbes;$rankPending=$false;$rankQueue=$null;Stop-TransportProcess $engine;$engine=$null;$confirmed=$false;$errorText='sing-box завершился, ожидается перезапуск';$checkingSince=$null
            foreach($child in @($tunnelChildren.Values)){Stop-TransportProcess $child};$tunnelChildren.Clear()
            foreach($row in $rows){if($row.state -eq 'ok'){$row.state='remembered'}}
            $portConflict=$detail.portConflict
            if($portConflict){$errorText=$portConflict.message}
            $bindRetry=Get-TransportBindRetry $bindRetry $detail
            $retryAt=$now.AddSeconds((Get-DaemonRestartDelay $detail));Write-TransportLog $root 'restart'
            Publish-TransportStatus
        }
        if(-not $engine -and $now -ge $retryAt){
            try{Start-TransportEngine;$errorText='Ожидается проверка пути'}
            catch{
                $detail=$_.Exception.Data['transportDiagnostic']
                if(-not $detail){$detail=New-TransportDiagnostic $engine 'sing-box' 'engine-start-failed' $diagnosticContext}
                $detail.stderr=Protect-TransportDiagnostic $detail.stderr $diagnosticContext
                foreach($row in $rows){if($row.enabled){$perRow=Copy-TransportObject $detail;$perRow.candidate=$row.tag;$row|Add-Member -Force diagnostic $perRow}}
                Write-TransportLog $root 'process-failed' $detail
                Stop-TransportProcess $engine;$engine=$null;foreach($child in @($tunnelChildren.Values)){Stop-TransportProcess $child};$tunnelChildren.Clear()
                $confirmed=$false;$errorText='Не удалось запустить транспорт; проверьте конфиг и физическую сеть';$checkingSince=$null
                $portConflict=$detail.portConflict
                if($portConflict){$errorText=$portConflict.message}
                $bindRetry=Get-TransportBindRetry $bindRetry $detail
                $retryAt=$now.AddSeconds((Get-DaemonRestartDelay $detail))
                Publish-TransportStatus
            }
        }
        if($engine){
            foreach($tunnel in $paths.Tunnels){
                if($tunnelChildren.ContainsKey($tunnel.tag) -and $tunnelChildren[$tunnel.tag].Process.HasExited){
                    $detail=New-TransportDiagnostic $tunnelChildren[$tunnel.tag] $tunnel.tag 'process-exited' $diagnosticContext
                    Write-TransportLog $root 'process-failed' $detail
                    Stop-TransportProcess $tunnelChildren[$tunnel.tag];$tunnelChildren.Remove($tunnel.tag)
                    $row=$rows|Where-Object {$_.tag -eq $tunnel.tag}|Select-Object -First 1;$row.state='fail';$row.kbps=$null;$row|Add-Member -Force diagnostic $detail
                    if($active -eq $tunnel.tag){Fail-TransportActive}
                }
                if(-not $tunnelChildren.ContainsKey($tunnel.tag) -and $now -ge $retryAt){
                    try{$a=@($tunnel.arguments);if($settings.Options.bindPhysical -and $tunnel.bind){$a+=@('-b',[string]$network.ip)};$tunnelChildren[$tunnel.tag]=Start-TransportProcess $settings.Profile.sshExecutable ($a+@($tunnel.target))}catch{Write-TransportLog $root 'process-failed' (New-TransportDiagnostic $null $tunnel.tag 'tunnel-start-failed')}
                    $retryAt=$now.AddSeconds([double]$settings.Options.restartDelaySec)
                }
            }
            foreach($key in @($probes.Keys)){
                $probe=$probes[$key];$tag=$probe.tag
                if(Receive-TransportProbe $probe){
                    $result=$probe.state;$row=$rows|Where-Object {$_.tag -eq $tag}|Select-Object -First 1
                    # Скорость задаёт рейтинг (равные объёмы); проба активного пути меньше и только подтверждает живость.
                    $row|Add-Member -Force probeMs ([int](([Diagnostics.Stopwatch]::GetTimestamp()-$probe.sink.Started)*1000/[Diagnostics.Stopwatch]::Frequency))
                    $row|Add-Member -Force maxGapMs $result.maxGapMs
                    if($probe.purpose -eq 'rank'){$row|Add-Member -Force rankState $result.state;$row.kbps=$result.kbps}
                    else{$row.state=$result.state;if($result.state -eq 'ok' -and $null -eq $row.kbps){$row.kbps=$result.kbps}}
                    $row.checkedAt=$now.ToString('o')
                    $reason=if($result.diagnostic.reason -eq 'timeout'){'таймаут '+$settings.Options.probeTimeoutSec+' с'}elseif($result.diagnostic.reason -eq 'stalled'){'нет ответа'}else{'путь недоступен'}
                    Write-DaemonWizardProgress ('Вариант связи: '+$row.title+$(if($result.state -eq 'ok'){' ✓'}else{' ✗ ('+$reason+')'}))
                    $detail=New-TransportDiagnostic $probe.child $tag $result.diagnostic.reason $diagnosticContext
                    if($result.state -ne 'ok'){
                        $underlying=Get-TransportEngineDiagnostic $engine $tag $diagnosticContext
                        if($underlying){$detail|Add-Member engineStderr $underlying.stderr;$detail.reason=$underlying.reason}
                    }
                    $row|Add-Member -Force diagnostic $detail
                    Stop-TransportProbe $probe;$probes.Remove($key)
                    if($result.state -eq 'ok'){
                        Write-TransportLog $root 'probe-ok' $detail
                        if($probe.purpose -eq 'rank'){}
                        elseif($tag -eq $active){$confirmed=$true;$errorText=$null;$bindRetry=$null;$portConflict=$null;Set-DaemonNextActive}
                        elseif(-not $confirmed){[void](Switch-TransportActive $tag $true)}
                    }else{
                        Write-TransportLog $root 'probe-failed' $detail
                        if($tag -eq $active){
                            if($probe.purpose -eq 'rank'){if($result.bytes -eq 0){$nextActive=$now}}else{Fail-TransportActive}
                        }
                    }
                    Save-TransportMemory $root $memory $network.id $rows
                    # The result reaches status/transport.json in this turn, not up to 1 s later (Bootstrap waits on it).
                    $lastStatus=[DateTime]::MinValue
                    # Все пробы живости/активного пути этой проверки закончились без подтверждения: это свежий провал.
                    if(-not $confirmed -and $checkingSince -and $liveDeferred.Count -eq 0 -and @($probes.Values|Where-Object {$_.purpose -in @('live','active')}).Count -eq 0){$checkingSince=$null}
                }
            }
            if($rankPending){Start-TransportRankNext}
            if($rankPending -and @($probes.Values|Where-Object {$_.purpose -eq 'rank'}).Count -eq 0 -and (-not $rankQueue -or $rankQueue.Count -eq 0)){
                $rankPending=$false;$best=Get-TransportBest $rows $rankTags
                if($best -and $best.tag -ne $active){[void](Switch-TransportActive $best.tag $true)}
                Save-TransportMemory $root $memory $network.id $rows
            }
            if($liveDeferred.Count -and $now -ge $tunnelLiveAt){foreach($c in $liveDeferred){Start-DaemonProbe $c ([long]$settings.Options.activeProbeBytes) 'live'};$liveDeferred=@()}
            # Живость — параллельно и раньше rank; rank (по очереди, делит канал) ждёт окончания проб живости.
            $live=@($probes.Values|Where-Object {$_.purpose -eq 'live'}).Count
            if(-not $confirmed -and -not $live -and $pin.mode -eq 'auto' -and $now -ge $nextLive){Start-TransportLiveness;$live=@($probes.Values|Where-Object {$_.purpose -eq 'live'}).Count}
            if($confirmed -and -not $rankPending -and -not $live -and $now -ge $nextRank){Start-TransportRanking}
            if($active -and $active -in @($paths.Candidates|ForEach-Object {$_.tag}) -and $now -ge $nextActive -and -not (Test-DaemonHealthProbe $active)){
                $c=$paths.Candidates|Where-Object {$_.tag -eq $active}|Select-Object -First 1
                Start-DaemonProbe $c ([long]$settings.Options.activeProbeBytes) 'active'
                Set-DaemonNextActive
            }
        }
        if($pin.mode -eq 'pinned' -and $pin.tag -notin @($paths.Candidates|ForEach-Object {$_.tag})){$confirmed=$false;$errorText='Закреплённый путь не работает: отключён или отсутствует';$checkingSince=$null}
        if($portConflict){$errorText=$portConflict.message}
        $statusInterval=1;if($portConflict -and $now -lt $retryAt){$statusInterval=5}
        if(($now-$lastStatus).TotalSeconds -ge $statusInterval){Publish-TransportStatus}
        # While the first path is being proved, probe results are read every 100 ms instead of 300 ms.
        Start-Sleep -Milliseconds $(if(-not $confirmed -and $probes.Count){100}else{300})
    }
    $errorText='Транспорт остановлен';$stopping=$true
}catch{
    $exitCode=1;$checkingSince=$null
    # Текст чужого исключения может содержать адрес/пароль — публикуем только категорию.
    $errorText='Ошибка транспорта: проверьте настройки, файлы профиля и бинарные файлы'
    if($locked){Write-TransportLog $root 'fatal' (Get-TransportErrorDetail $_);Write-TransportLog $root 'process-failed' (New-TransportDiagnostic $null 'transport' 'initialization-failed')}else{Write-Error 'Транспорт уже запущен или блокировка недоступна' -ErrorAction Continue}
}finally{
    if($reloadJob){Stop-Job $reloadJob;Remove-Job $reloadJob -Force}
    Stop-TransportProbes
    foreach($child in @($tunnelChildren.Values)){Stop-TransportProcess $child};Stop-TransportProcess $engine;$engine=$null;$confirmed=$false
    if($locked){try{Publish-TransportStatus;Write-TransportLog $root 'stop'}finally{$mutex.ReleaseMutex()}}
    if($mutex){$mutex.Dispose()};if($parent){$parent.Dispose()}
}

exit $exitCode
