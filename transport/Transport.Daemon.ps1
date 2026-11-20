#requires -Version 5.1
[CmdletBinding()]
param([Alias('Home')][string]$TransportHome=(Join-Path $env:LOCALAPPDATA 'RemoteAgents'),[int]$ParentPid=0)
# Persisted pipe output has a known encoding on Windows PowerShell 5.1 too.
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
. (Join-Path $PSScriptRoot 'Transport.Decide.ps1')
. (Join-Path $PSScriptRoot 'Transport.Events.ps1')
$root=(Get-TransportHome $TransportHome);$engine=$null;$tunnelChildren=@{};$probes=@{};$rows=@();$active=$null;$confirmed=$false;$errorText='Запуск';$network=$null;$memory=$null;$secret=$null
$parent=$null;$mutex=$null;$locked=$false;$settings=$null;$paths=$null;$exitCode=0
$pin=[pscustomobject]@{mode='auto';tag=$null};$nextControl=[DateTime]::MinValue;$revision='';$reloadJob=$null;$reloadError=$null;$failedRevision=$null;$pendingRevision=$null;$nextReload=[DateTime]::MinValue
$portConflict=$null;$bindRetry=$null;$startFailures=0;$bindState=@{failures=0;none=$false};$nextBindRetry=[DateTime]::MinValue;$liveRound=$false;$initialRound=$false
$reader=$null;$directCheck=$null;$pathChecks=@{};$gateOkUntil=@{};$decision=$null;$verdict=$null;$eventQueue=@();$lastRecoveryAt=$null;$pathCheckStartedAt=@{}
$diagnosticContext=$null;$liveDeferred=@();$tunnelReadyUntil=@{};$daemonStarted=[DateTime]::Now;$checkingSince=[DateTime]::UtcNow;$stopping=$false
try{$daemonStarted=(Get-Process -Id $PID).StartTime}catch{}
$script:engineAttempted=$false;$checkingSince=$daemonStarted.ToUniversalTime()
$lastStatus=[DateTime]::MinValue;$nextNetwork=[DateTime]::MinValue;$retryAt=[DateTime]::MinValue
function Test-TransportStop {
    try{if([IO.File]::Exists((Join-Path $root 'stop')) -or [IO.File]::Exists((Join-Path $root 'state/transport.stop'))){return $true}}catch{}
    if($parent){try{return $parent.HasExited}catch{return $true}};return $false
}
function Get-DaemonTime { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function New-DaemonEvent([string]$Kind,[string]$Tag,[string]$Code,[bool]$Local=$false) {
    @{at=(Get-DaemonTime);kind=$Kind;tag=$Tag;code=$Code;local=$Local;detail=''}
}
function Stop-TransportProbes {
    foreach($probe in @($probes.Values)){Stop-TransportProbe $probe};$probes.Clear()
    $script:liveDeferred=@();$script:liveRound=$false;$script:initialRound=$false
    foreach($r in $rows){$r.suspect=$false}
}
function Reset-DaemonDecision {
    $previous=$decision
    $script:decision=New-TransportDecisionState -Now (Get-DaemonTime) -CurrentTag $active
    if($previous){$decision.switches=$previous.switches;$decision.lastSwitchAt=$previous.lastSwitchAt}
    $script:verdict=$null;$script:lastRecoveryAt=$null
    foreach($r in $rows){$r.penaltyStep=0;$r.penaltyUntil=$null;$r.suspect=$false}
}
function Stop-DaemonObservation([switch]$EngineRestart) {
    Stop-TransportEvents $reader;$script:reader=$null
    # Engine failure keeps the direct proof and reducer history; configuration/network/pin
    # generations discard ALL outstanding results, rather than manufacturing failures.
    if($EngineRestart){
        $script:eventQueue=@($eventQueue|Where-Object {$_.kind -in @('net-up','net-down')})
    }else{
        if($directCheck){try{Stop-TransportDirectCheck $directCheck.handle}catch{};$script:directCheck=$null}
        $script:eventQueue=@()
    }
    foreach($ticket in @($pathChecks.Values)){
        try{Stop-TransportPathCheck $ticket.handle}catch{}
        if($EngineRestart){$script:eventQueue+=@(New-DaemonEvent 'path-check' $ticket.tag 'cancelled')}
    }
    $pathChecks.Clear();$gateOkUntil.Clear();$pathCheckStartedAt.Clear()
    if(-not $EngineRestart){Reset-DaemonDecision}
}
function Start-DaemonReader([switch]$NewEngine) {
    Stop-TransportEvents $reader;$script:reader=$null
    $tags=@($paths.Candidates|Where-Object {$pin.mode -ne 'pinned' -or $_.tag -eq $pin.tag}|ForEach-Object {[string]$_.tag})
    # Never pass an empty allowlist to the event subscription.
    if($tags.Count){$script:reader=Start-TransportEvents -ApiPort $settings.Options.apiPort -Secret $secret -Tags $tags -StallSeconds $settings.Options.switchStallSeconds -StallConns $settings.Options.switchStallConns}
}
function Start-DaemonDirectCheck {
    # Test-only endpoints must ALL be literal loopback IPv4; malformed/mixed lists
    # are ignored as a whole. The normal wrapper retains B's physical binding.
    $targets=@();$valid=[bool]$env:REMOTEAGENTS_TEST_DIRECT_TARGETS
    if($valid){
        foreach($part in $env:REMOTEAGENTS_TEST_DIRECT_TARGETS.Split(',')){
            $ip=$null;$port=0
            if($part -notmatch '^(127\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)$'){$valid=$false;break}
            if(-not [Net.IPAddress]::TryParse($Matches[1],[ref]$ip) -or -not [int]::TryParse($Matches[2],[ref]$port) -or $port -lt 1 -or $port -gt 65535){$valid=$false;break}
            $targets+=New-Object Net.IPEndPoint $ip,$port
        }
    }
    if($valid -and $targets.Count){
        Initialize-TransportEvents
        $bindIP='';$index=0
        if($network){$bindIP=[string]$network.ip;$index=[int]$network.ifIndex}
        return New-Object RemoteAgents.TransportCheck -ArgumentList $bindIP,$index,([Net.IPEndPoint[]]$targets),3000
    }
    Start-TransportDirectCheck -Network $network
}
function Start-DaemonDirect {
    if($directCheck){return}
    $script:directCheck=@{handle=$null;until=((Get-DaemonTime)+3000)}
    try{$directCheck.handle=Start-DaemonDirectCheck}catch{$directCheck.until=Get-DaemonTime}
}
function Start-DaemonPath([string]$Tag,[switch]$Gate) {
    if($pathChecks.ContainsKey($Tag)){return}
    $c=$paths.Candidates|Where-Object {$_.tag -eq $Tag}|Select-Object -First 1
    if(-not $Gate){$pathCheckStartedAt[$Tag]=Get-DaemonTime}
    $seconds=12;if($Gate){$seconds=6}
    $ticket=@{handle=$null;until=((Get-DaemonTime)+[long]($seconds*1000));tag=$Tag;gate=[bool]$Gate};$pathChecks[$Tag]=$ticket
    try{
        if(-not $c){throw 'Missing path'}
        if($Gate){$ticket.handle=Start-TransportPathCheck -Candidate $c -Profile $settings.Profile -TimeoutSeconds 6}
        else{$ticket.handle=Start-TransportPathCheck -Candidate $c -Profile $settings.Profile -ConfirmStall -StallSeconds $settings.Options.switchStallSeconds -TimeoutSeconds 12}
    }catch{$ticket.until=Get-DaemonTime}
}
function Receive-DaemonChecks {
    if($directCheck){
        $event=$null
        try{if($directCheck.handle){$event=Receive-TransportDirectCheck $directCheck.handle}}catch{$directCheck.until=Get-DaemonTime}
        if(-not $event -and (Get-DaemonTime) -ge $directCheck.until){$event=New-DaemonEvent 'net-down' '' 'timeout' $true}
        if($event){
            try{Stop-TransportDirectCheck $directCheck.handle}catch{};$script:directCheck=$null
            # Timestamp delivery after the reducer's direct-check request.
            $event.at=Get-DaemonTime
            $script:eventQueue+=@($event)
        }
    }
    foreach($tag in @($pathChecks.Keys)){
        $ticket=$pathChecks[$tag];$event=$null
        try{if($ticket.handle){$event=Receive-TransportPathCheck $ticket.handle}}catch{$ticket.until=Get-DaemonTime}
        if(-not $event -and (Get-DaemonTime) -ge $ticket.until){$event=New-DaemonEvent 'path-check' $tag 'timeout'}
        if($event){
            try{Stop-TransportPathCheck $ticket.handle}catch{};$pathChecks.Remove($tag)
            if($ticket.gate -and $event.code -eq 'ok'){$gateOkUntil[$tag]=(Get-DaemonTime)+30000}
            Add-DaemonEvent $event
        }
    }
}
function Add-DaemonEvent($Event) {
    $e=@{};foreach($name in @('at','kind','tag','code','local','detail')){$e[$name]=$Event.$name}
    if($e.kind -in @('dial-fail','conn-closed-error') -and -not $e.local){
        if(-not $e.tag){$e.tag=$active}
        if($e.tag -notin @($paths.Candidates.tag) -or ($pin.mode -eq 'pinned' -and $e.tag -ne $pin.tag)){return}
        if($pathChecks.ContainsKey($e.tag) -or ($decision -and $decision.pending.ContainsKey($e.tag))){return}
        if($gateOkUntil.ContainsKey($e.tag) -and (Get-DaemonTime) -lt $gateOkUntil[$e.tag]){return}
        if(@($pathChecks.Values|Where-Object {$_.gate}).Count -ge 2){return}
        Start-DaemonPath $e.tag -Gate;return
    }
    if($e.kind -eq 'path-check' -and $e.code -eq 'ok'){
        $r=$rows|Where-Object {$_.tag -eq $e.tag}|Select-Object -First 1
        if($r){$r.state='ok';$r.checkedAt=[DateTime]::UtcNow.ToString('o');$r.lastOkAt=$r.checkedAt;Save-TransportMemory $root $memory $network.id $rows}
    }
    $script:eventQueue+=@($e)
}
function Invoke-DaemonDecision {
    Receive-DaemonChecks
    $eligible=@($rows|Where-Object {$_.tag -in @($paths.Candidates.tag) -and ($pin.mode -ne 'pinned' -or $_.tag -eq $pin.tag)})
    $result=Invoke-TransportDecision -State $decision -Candidates $eligible -CurrentTag $active -Now (Get-DaemonTime) -Events $eventQueue
    $script:eventQueue=@()
    $script:decision=$result.state;$script:verdict=$result.verdict
    if($verdict.localNet -eq 'down'){
        Stop-TransportProbes;$script:confirmed=$false;$script:errorText=$verdict.reason.text
    }
    if($active -and $decision.paths.ContainsKey($active) -and $decision.paths[$active].failed){
        $script:confirmed=$false;$script:errorText=$verdict.reason.text
        $failedRow=$rows|Where-Object {$_.tag -eq $active}|Select-Object -First 1
        if($failedRow){$failedRow.state='fail'}
    }
    switch($verdict.action){
        'check-direct' {Start-DaemonDirect}
        'check-path' {Start-DaemonPath $verdict.tag}
        'switch' {
            $targetTag=[string]$verdict.tag
            $row=$eligible|Where-Object {$_.tag -eq $targetTag}|Select-Object -First 1
            if($pin.mode -eq 'auto' -and $engine -and -not $engine.Process.HasExited){
                if(Switch-TransportActive $targetTag $false){
                    $script:confirmed=[bool]($row -and $row.state -eq 'ok')
                    if(-not $confirmed){Start-DaemonPath $targetTag;Start-DaemonRecovery}
                }
            }
        }
        'searching' {if($verdict.reason.code -like 'path-*'){Start-DaemonRecovery}}
    }
    foreach($r in $rows){
        $step=0;$until=$null
        if($verdict.penalties.ContainsKey($r.tag)){$penalty=$verdict.penalties[$r.tag];$step=$penalty.step;if($null -ne $penalty.until){$until=([DateTime]::SpecifyKind([DateTime]'1970-01-01',[DateTimeKind]::Utc)).AddMilliseconds([long]$penalty.until).ToString('o')}}
        $r|Add-Member -Force penaltyStep $step;$r|Add-Member -Force penaltyUntil $until
    }
    if($verdict.localNet -eq 'ok' -and $active -and $decision.paths.ContainsKey($active) -and -not $decision.paths[$active].failed -and -not $decision.pending.ContainsKey($active)){
        $r=$rows|Where-Object {$_.tag -eq $active}|Select-Object -First 1
        if($r -and $r.state -eq 'ok'){$script:confirmed=$true;$script:errorText=$null}
    }
    # A selector acknowledgement clears reducer failure, but is not proof of traffic.
    # Retry only an unconfirmed active path; healthy paths never receive timed probes.
    if($engine -and -not $engine.Process.HasExited -and $verdict.localNet -eq 'ok' -and -not $confirmed -and $active -in @($eligible.tag) -and
        -not $pathChecks.ContainsKey($active) -and -not $probes.ContainsKey($active) -and $active -notin @($liveDeferred.tag) -and -not $decision.pending.ContainsKey($active)){
        $nowMs=Get-DaemonTime
        if(-not $pathCheckStartedAt.ContainsKey($active) -or ($nowMs-$pathCheckStartedAt[$active]) -ge 15000){Start-DaemonPath $active}
    }
}
function Publish-TransportStatus {
    $script:rows=@(Get-TransportOrdered $rows);$order=0;foreach($r in $rows){$order++;$r|Add-Member -Force order $order}
    $speed=$null;$row=$rows|Where-Object {$_.tag -eq $active}|Select-Object -First 1
    if($confirmed -and $row){$speed=$row.kbps}
    $alive=$false;if($engine){try{$alive=-not $engine.Process.HasExited}catch{}}
    $id=$null;if($network){$id=$network.id}
    $starting=(-not $script:engineAttempted -and $exitCode -eq 0 -and -not $reloadError -and -not $portConflict -and -not $stopping)
    $summary='нет связи: '+$(if($errorText){$errorText}else{'нет проверенного пути'})
    if($alive -and $confirmed -and $row){$summary=$row.title;if($null -ne $speed){$summary+=' · '+([Math]::Round([double]$speed,1)).ToString([Globalization.CultureInfo]::InvariantCulture)+' КБ/с'}}
    if($starting){$summary='запуск модуля связи'}
    if($settings -and $settings.LocalWeb.conflict){$summary+=' · Happier: '+$settings.LocalWeb.conflict.message}
    $searching=[bool]($verdict -and ($verdict.action -in @('searching','rollback-penalties') -or $verdict.localNet -eq 'down' -or (-not $confirmed -and -not $initialRound)))
    $degraded=[bool]($confirmed -and $decision -and $active -and $decision.pending.ContainsKey($active))
    $isOk=[bool]($alive -and $confirmed -and -not $degraded -and -not $searching -and -not $reloadError -and -not $portConflict -and $exitCode -eq 0 -and -not $stopping)
    if($isOk){$script:checkingSince=$null}
    if($starting){
        $isOk=$false
        if(-not $script:checkingSince){$script:checkingSince=$daemonStarted.ToUniversalTime()}
    }
    $phase=if($starting){'checking'}elseif($stopping){'stopped'}elseif($exitCode -ne 0 -or $reloadError -or $portConflict -or -not $alive){'failed'}elseif($initialRound -and -not $confirmed){'checking'}elseif($searching){'searching'}elseif($degraded){'degraded'}elseif($isOk){'ok'}elseif($script:checkingSince){'checking'}else{'failed'}
    Write-TransportJson (Join-Path $root 'status/transport.json') ([ordered]@{endpoints=@($paths.Outbounds|Where-Object {$_.server -and $_.server -notin @('127.0.0.1','::1')}|ForEach-Object {[string]$_.server}|Sort-Object -Unique);ports=$(if($settings){Get-TransportConfiguredPorts ([pscustomobject]$settings.Options) $settings.Profile}else{$null});localWeb=$(if($settings){$settings.LocalWeb}else{$null});lan=$(if($settings){$settings.Lan}else{$null});helper=$(if($settings){Get-TransportHelperStatus $settings $active $paths.Outbounds}else{$null});portConflict=$portConflict;retryAt=$retryAt.ToUniversalTime().ToString('o');configRevision=$revision;fatal=($exitCode -ne 0);summary=$summary;reason=$(if($verdict){@{code=$verdict.reason.code;text=$(if($verdict.reason.code -eq 'ok'){''}else{$verdict.reason.text});since=([DateTime]::SpecifyKind([DateTime]'1970-01-01',[DateTimeKind]::Utc)).AddMilliseconds([long]$verdict.reason.since).ToString('o')}}else{@{code='ok';text='';since=[DateTime]::UtcNow.ToString('o')}});localNet=$(if($verdict){$verdict.localNet}else{'unknown'});switches=@($(if($decision){foreach($item in $decision.switches){@{at=([DateTime]::SpecifyKind([DateTime]'1970-01-01',[DateTimeKind]::Utc)).AddMilliseconds([long]$item.at).ToString('o');from=$item.from;to=$item.to;why=$item.why}}}));ok=$isOk;phase=$phase;checkingSince=$(if($script:checkingSince){$script:checkingSince.ToString('o')}else{$null});active=$active;kbps=$speed;network=$id;metered=$metered;mode=$pin.mode;pinnedTag=$pin.tag;candidates=@($rows);configError=$reloadError;updatedAt=[DateTime]::UtcNow.ToString('o');error=$errorText})
    $script:lastStatus=[DateTime]::UtcNow
}
function Confirm-DaemonSelection([string]$Tag) {
    if(-not $decision -or $Tag -eq $decision.currentTag){return}
    # Pinning a paused path changes the selector, not the known failure/backoff.
    $pinnedFailure=($pin.mode -eq 'pinned' -and $decision.paths.ContainsKey($Tag) -and ($decision.paths[$Tag].failed -or $null -ne $decision.paths[$Tag].until))
    # A selector change is acknowledged before publishing or starting another round.
    $ack=Invoke-TransportDecision -State $decision -Candidates @($rows|Where-Object {$_.tag -in @($paths.Candidates.tag) -and ($pin.mode -ne 'pinned' -or $_.tag -eq $pin.tag)}) -CurrentTag $Tag -Now (Get-DaemonTime)
    $script:decision=$ack.state;$script:verdict=$ack.verdict
    if($pinnedFailure){$decision.paths[$Tag].failed=$true}
    if($verdict.action -eq 'check-direct'){Start-DaemonDirect}
    elseif($verdict.action -eq 'check-path'){Start-DaemonPath $verdict.tag}
}
function Switch-TransportActive([string]$Tag,[bool]$Verified) {
    if($pin.mode -eq 'pinned' -and $Tag -ne $pin.tag){return $false}
    if($pin.mode -eq 'auto' -and $Tag -ne $active -and $decision -and $null -ne $decision.lastSwitchAt -and ((Get-DaemonTime)-$decision.lastSwitchAt) -lt 10000){return $false}
    if(-not $Tag){$script:confirmed=$false;$script:errorText='Нет проверенного пути';return $false}
    try{
        $target=$Tag;if($Tag -notin @($paths.Candidates.tag)){$target='unavailable';$Verified=$false}
        Set-TransportSelector $settings.Options $secret $target
        $changed=($Tag -ne $active)
        $script:active=$Tag;$script:confirmed=$Verified
        if($changed){Confirm-DaemonSelection $Tag}
        if($Verified){foreach($r in $rows){$r.suspect=$false};$script:errorText=$null;$script:bindRetry=$null;$script:portConflict=$null}
        elseif($pin.mode -eq 'pinned'){$script:errorText='Закреплённый путь ещё не проверен или недоступен'}else{$script:errorText='Путь из памяти ещё не проверен'}
        Write-TransportLog $root 'switch';return $true
    }catch{$script:confirmed=$false;$script:errorText='Не удалось переключить selector';Write-TransportLog $root 'api-failed' (Get-TransportErrorDetail $_);return $false}
}
function Write-DaemonWizardProgress([string]$Text) {
    # Explicit opt-in only for the wizard's short-lived preflight. Never forward raw subprocess output.
    if($env:REMOTEAGENTS_WIZARD_PROGRESS){try{[IO.File]::AppendAllText($env:REMOTEAGENTS_WIZARD_PROGRESS,((@{text=$Text}|ConvertTo-Json -Compress)+"`n"),(New-Object Text.UTF8Encoding($false)))}catch{}}
}
function Start-DaemonProbe($Candidate) {
    if($probes.ContainsKey($Candidate.tag)){return}
    $pathCheckStartedAt[$Candidate.tag]=Get-DaemonTime
    Write-DaemonWizardProgress ('Проверяю вариант связи: '+$Candidate.title+'… (до '+$settings.Options.probeTimeoutSec+' с)')
    try{$probes[$Candidate.tag]=Start-TransportProbe $settings.Profile $Candidate 65536 $settings.Options 'live'}
    catch{Add-DaemonEvent (New-DaemonEvent 'path-check' $Candidate.tag 'process-exited')}
}
function Start-DaemonRecovery {
    $nowMs=Get-DaemonTime
    if($liveRound -or ($decision -and $decision.localNet -eq 'down') -or -not $engine -or $engine.Process.HasExited){return}
    if($null -ne $lastRecoveryAt -and ($nowMs-$lastRecoveryAt) -lt 60000){return}
    $script:lastRecoveryAt=$nowMs
    Start-TransportLiveness -Recovery
}
function Start-TransportLiveness([switch]$Recovery) {
    if($liveRound){return}
    $script:liveRound=$true;$script:initialRound=(-not $Recovery)
    # Counter initialization (Add-Type on Windows) can block before the first probe.
    Publish-TransportStatus
    foreach($c in $paths.Candidates){
        if($pin.mode -eq 'pinned' -and $c.tag -ne $pin.tag){continue}
        if($pathChecks.ContainsKey($c.tag)){continue}
        if($c.tag -in @($paths.Tunnels.tag) -and -not (Test-DaemonTunnelReady $c.tag)){$script:liveDeferred+=,$c}else{Start-DaemonProbe $c}
    }
}
function Test-DaemonTunnelReady([string]$Tag) {
    if(-not $tunnelReadyUntil.ContainsKey($Tag)){return $true}
    if([DateTime]::UtcNow -ge $tunnelReadyUntil[$Tag]){return $true}
    if($tunnelChildren.ContainsKey($Tag) -and $tunnelChildren[$Tag].Process.HasExited){return $true}
    $outbound=$paths.Outbounds|Where-Object {$_.tag -eq $Tag}|Select-Object -First 1
    try{if(@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()|Where-Object {$_.Port -eq [int]$outbound.server_port}).Count){$script:tunnelReadyUntil.Remove($Tag);return $true}}catch{}
    return $false
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
    Stop-TransportEvents $reader;$script:reader=$null
    [void](Reset-DaemonPorts)
    $script:confirmed=$false
    if($script:engineAttempted){$script:checkingSince=[DateTime]::UtcNow}
    $interface='';$cfgSettings=$settings
    if($settings.Options.bindPhysical){
        $bind=Resolve-TransportBind $bindState $network (Test-TransportVpnOff $root)
        if($bind.event){Write-TransportLog $root 'bind-mode' ([pscustomobject]@{message=$bind.event})}
        if($bind.mode -eq 'fail'){throw 'Физический интерфейс недоступен'}
        if($bind.mode -eq 'physical'){$interface=[string]$network.interface}
        else{
            # Резервный режим: без bind_interface/auto_detect_interface и без -b у OpenSSH; трафик идёт по маршрутам ОС.
            $cfgSettings=Copy-TransportObject $settings;$cfgSettings.Options.bindPhysical=$false;$script:nextBindRetry=[DateTime]::UtcNow.AddSeconds(60)
        }
    }
    $cfg=New-TransportConfig $cfgSettings $paths $secret $active $interface
    $file=Join-Path $root 'state/transport-sing-box.json';Write-TransportJson $file $cfg -Private
    # Валидация до запуска; stdout/stderr не публикуются, т.к. могут содержать адреса и секреты.
    Publish-TransportStatus
    Test-TransportConfigFile $settings.Options.singBoxPath $file
    $script:engine=Start-TransportProcess $settings.Options.singBoxPath @('run','-c',$file)
    Publish-TransportStatus
    Save-TransportOwner $root 'transport' $engine $settings.Options.singBoxPath $file
    foreach($tunnel in $paths.Tunnels){
        if($tunnelChildren.ContainsKey($tunnel.tag)){continue}
        $a=@($tunnel.arguments)
        if($cfgSettings.Options.bindPhysical -and $tunnel.bind){if(-not $network.ip){throw 'Нет физического IPv4 для OpenSSH'};$a+=@('-b',[string]$network.ip)}
        $script:tunnelChildren[$tunnel.tag]=Start-TransportProcess $settings.Profile.sshExecutable ($a+@([string]$tunnel.target))
        $script:tunnelReadyUntil[$tunnel.tag]=[DateTime]::UtcNow.AddSeconds(3)
    }
    # Start health probes as soon as the listener is ready; no fixed post-start pause.
    $ready=Wait-TransportEngineReady ([int]$settings.Options.apiPort) 3000
    # Успешный запуск сбрасывает серию bind, даже если сеть ещё не прошла пробу.
    if($ready -and -not $engine.Process.HasExited){
        # Чужой слушатель API ещё не доказывает запуск нашего процесса. Подтверждаем API его секретом.
        try{
            $target=($cfg.outbounds|Where-Object {$_.tag -eq 'active'}|Select-Object -First 1).default
            Set-TransportSelector $settings.Options $secret $target
            if($target -eq $active){Confirm-DaemonSelection $active}
            $script:bindRetry=$null;$script:portConflict=$null
        }catch{}
    }
    $script:startFailures=0;Write-TransportLog $root 'ready'
    if($ready -and -not $engine.Process.HasExited){
        Start-DaemonReader -NewEngine
        Write-DaemonWizardProgress ('· модуль связи готов '+[int]([DateTime]::Now-$daemonStarted).TotalMilliseconds+' мс от запуска процесса')
        Start-TransportLiveness
    }
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
    $decision=New-TransportDecisionState (Get-DaemonTime) $active
    Publish-TransportStatus
    while(-not (Test-TransportStop)){
        Receive-DaemonChecks
        $now=[DateTime]::UtcNow
        # Короткий управляющий цикл: pin не ждёт сетевых проб или SSH -G при reload.
        if($now -ge $nextControl){
            $nextControl=$now.AddSeconds(1)
            try{$newPin=Read-TransportPin $root}catch{$newPin=[pscustomobject]@{mode='pinned';tag='invalid-pin'}; $errorText='Неверный transport-pin.json'}
            if($newPin.mode -ne $pin.mode -or $newPin.tag -ne $pin.tag -or ($newPin.mode -eq 'pinned' -and $active -ne $newPin.tag)){
                Stop-TransportProbes;Stop-DaemonObservation
                $pin=$newPin;$desired=Get-TransportSelection $pin $rows $paths.Candidates $active
                $row=$rows|Where-Object {$_.tag -eq $desired}|Select-Object -First 1
                if($engine){[void](Switch-TransportActive $desired ([bool]($row -and $row.state -eq 'ok')))}else{$active=$desired;$confirmed=$false}
                $checkingSince=$now
                if($engine){Start-DaemonReader;Start-TransportLiveness}
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
        # A completed reload cancels outstanding work; it must never wait for check deadlines.
        if($reloadJob -and $reloadJob.State -in @('Completed','Failed','Stopped')){
            try{
                $result=Receive-Job $reloadJob -ErrorAction Stop
                if(-not $result -or $reloadJob.State -ne 'Completed'){throw 'Reload failed'}
                Stop-TransportProbes;Stop-DaemonObservation
                Stop-TransportProcess $engine;$engine=$null;$settings=$result.Settings;$paths=$result.Paths;$revision=$result.Revision
                $diagnosticContext=@(Get-TransportDiagnosticContext $settings $root)
                $rows=@(Get-TransportRemembered $memory $network.id $paths.AllCandidates)
                $desired=Get-TransportSelection $pin $rows $paths.Candidates $active
                if($pin.mode -ne 'auto' -or -not $decision -or $null -eq $decision.lastSwitchAt -or ((Get-DaemonTime)-$decision.lastSwitchAt) -ge 10000){$active=$desired}
                $confirmed=$false;$retryAt=$now
                $bindRetry=$null;$portConflict=$null
                Start-TransportEngine;$reloadError=$null;$errorText='Конфиг применён; ожидается проверка пути';$checkingSince=$now
                Write-TransportLog $root 'restart'
            }catch{$reloadError='Новый конфиг не применён; проверьте списки узлов и кэш секретов';$nextReload=[DateTime]::UtcNow.AddSeconds(5)}
            finally{Remove-Job $reloadJob -Force;$reloadJob=$null}
        }
        if($now -ge $nextNetwork){
            $nextNetwork=$now.AddSeconds(5);$newNetwork=Get-TransportNetwork;$newMetered=Get-TransportMetered $settings.Options
            $changed=Test-TransportNetworkChanged $network $newNetwork
            $metered=$newMetered
            if($changed){
                Stop-TransportProbes;Stop-DaemonObservation;$network=$newNetwork
                $rows=@(Get-TransportRemembered $memory $network.id $paths.AllCandidates);$confirmed=$false
                $best=Get-TransportBest $rows -Remembered
                if($best -and $pin.mode -eq 'auto' -and ($null -eq $decision.lastSwitchAt -or ((Get-DaemonTime)-$decision.lastSwitchAt) -ge 10000)){
                    if($engine -and -not $settings.Options.bindPhysical){[void](Switch-TransportActive $best.tag $false)}
                    else{$active=$best.tag;$errorText='Путь из памяти ещё не проверен'}
                }
                $checkingSince=$now;Write-TransportLog $root 'network-change'
                # bind_interface и OpenSSH -b задаются на сокете. При смене NIC нужен новый процесс;
                # обычный failover selector никогда не перезапускает sing-box.
                if($settings.Options.bindPhysical){
                    Stop-TransportProcess $engine;$engine=$null
                    foreach($child in @($tunnelChildren.Values)){Stop-TransportProcess $child};$tunnelChildren.Clear();$retryAt=$now
                }
                if(-not $newNetwork.available){$errorText='Не удалось определить физическую сеть';Write-TransportLog $root 'network-unavailable'}
            }
            if($changed -and $engine){Start-DaemonReader;Start-TransportLiveness}
        }
        if($engine -and $bindState.none -and $now -ge $nextBindRetry -and -not $directCheck -and -not $pathChecks.Count -and -not $eventQueue.Count){
            # Резервный режим: раз в 60 с пробуем вернуть привязку; при появлении интерфейса или включении VPN движок пересоздаётся.
            $nextBindRetry=$now.AddSeconds(60);$probeNet=Get-TransportNetwork
            if($probeNet.interface -or -not (Test-TransportVpnOff $root)){
                $network=$probeNet;Stop-TransportProbes;Stop-DaemonObservation;$confirmed=$false
                Stop-TransportProcess $engine;$engine=$null;foreach($child in @($tunnelChildren.Values)){Stop-TransportProcess $child};$tunnelChildren.Clear();$retryAt=$now
            }
        }
        if($engine -and $engine.Process.HasExited){
            $detail=New-TransportDiagnostic $engine 'sing-box' 'process-exited' $diagnosticContext
            Write-TransportLog $root 'process-failed' $detail
            foreach($row in $rows){if($row.enabled){$perRow=Copy-TransportObject $detail;$perRow.candidate=$row.tag;$row|Add-Member -Force diagnostic $perRow}}
            Stop-TransportProbes;Stop-DaemonObservation -EngineRestart;if(-not $detail.portConflict){Add-DaemonEvent (New-DaemonEvent 'engine-exit' '' 'exited')};Stop-TransportProcess $engine;$engine=$null;$confirmed=$false;$errorText='sing-box завершился, ожидается перезапуск';$checkingSince=$now
            foreach($child in @($tunnelChildren.Values)){Stop-TransportProcess $child};$tunnelChildren.Clear()
            foreach($row in $rows){if($row.state -eq 'ok'){$row.state='remembered'}}
            $portConflict=$detail.portConflict
            if($portConflict){$errorText=$portConflict.message}
            $bindRetry=Get-TransportBindRetry $bindRetry $detail
            $retryAt=$now.AddSeconds((Get-DaemonRestartDelay $detail));Write-TransportLog $root 'restart'
            Publish-TransportStatus
        }
        if(-not $engine -and $now -ge $retryAt -and -not $directCheck -and -not $pathChecks.Count -and -not $eventQueue.Count){
            try{
                # После неудачи сеть определяется заново, а не ждёт 5-секундной проверки смены сети.
                if($startFailures -gt 0 -and $settings.Options.bindPhysical){$network=Get-TransportNetwork;$nextNetwork=$now.AddSeconds(5)}
                try{Start-TransportEngine}finally{$script:engineAttempted=$true}
                $errorText='Ожидается проверка пути'
            }
            catch{
                $startError=Format-TransportStartError $_ $diagnosticContext
                $detail=$_.Exception.Data['transportDiagnostic']
                if(-not $detail){$detail=New-TransportDiagnostic $engine 'sing-box' 'engine-start-failed' $diagnosticContext}
                $detail.stderr=Protect-TransportDiagnostic $detail.stderr $diagnosticContext
                $detail|Add-Member -Force error $startError
                foreach($row in $rows){if($row.enabled){$perRow=Copy-TransportObject $detail;$perRow.candidate=$row.tag;$row|Add-Member -Force diagnostic $perRow}}
                Write-TransportLog $root 'process-failed' $detail
                Stop-TransportProcess $engine;$engine=$null;foreach($child in @($tunnelChildren.Values)){Stop-TransportProcess $child};$tunnelChildren.Clear()
                $confirmed=$false;$errorText='Не удалось запустить транспорт: '+$startError;$checkingSince=$now
                $portConflict=$detail.portConflict
                if($portConflict){$errorText=$portConflict.message}
                $bindRetry=Get-TransportBindRetry $bindRetry $detail
                $startFailures++
                $retryAt=$now.AddSeconds((Get-DaemonRestartDelay $detail))
                if(-not $portConflict){$retryAt=$now.AddSeconds((Get-TransportStartPause $startFailures))}
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
                    Add-DaemonEvent (New-DaemonEvent 'engine-exit' $tunnel.tag 'process-exited')
                }
                if(-not $tunnelChildren.ContainsKey($tunnel.tag) -and $now -ge $retryAt){
                    try{
                        $a=@($tunnel.arguments);if($settings.Options.bindPhysical -and -not $bindState.none -and $tunnel.bind -and $network.ip){$a+=@('-b',[string]$network.ip)}
                        $tunnelChildren[$tunnel.tag]=Start-TransportProcess $settings.Profile.sshExecutable ($a+@($tunnel.target))
                        $tunnelReadyUntil[$tunnel.tag]=[DateTime]::UtcNow.AddSeconds(3)
                    }catch{Write-TransportLog $root 'process-failed' (New-TransportDiagnostic $null $tunnel.tag 'tunnel-start-failed')}
                    $retryAt=$now.AddSeconds([double]$settings.Options.restartDelaySec)
                }
            }
            if($reader){foreach($e in @(Receive-TransportEvents $reader)){Add-DaemonEvent $e}}
            foreach($key in @($probes.Keys)){
                $probe=$probes[$key]
                try{$done=Receive-TransportProbe $probe}catch{$done=$true;$probe.state.state='fail'}
                if(-not $done){continue}
                $r=$rows|Where-Object {$_.tag -eq $key}|Select-Object -First 1;$r.state=$probe.state.state
                $r.latencyMs=$probe.state.latencyMs;$r.kbps=$probe.state.kbps;$r.checkedAt=[DateTime]::UtcNow.ToString('o')
                $r|Add-Member -Force maxGapMs $probe.state.maxGapMs
                $code=switch($r.state){'ok' {'ok'} 'frozen' {'stalled'} 'slow' {'timeout'} default {'process-exited'}};if($r.state -eq 'ok'){$r.lastOkAt=$r.checkedAt}else{$r.lastFailAt=$r.checkedAt}
                $detail=New-TransportDiagnostic $probe.child $key $code $diagnosticContext;$r|Add-Member -Force diagnostic $detail
                Stop-TransportProbe $probe;$probes.Remove($key)
                Add-DaemonEvent (New-DaemonEvent 'path-check' $key $code)
                Write-DaemonWizardProgress ('Вариант связи: '+$r.title+$(if($code -eq 'ok'){' ✓'}else{' ✗'}))
                if($code -eq 'ok' -and $initialRound -and -not $confirmed -and -not ($decision -and $decision.localNet -eq 'down')){[void](Switch-TransportActive $key $true)}
                Save-TransportMemory $root $memory $network.id $rows;$lastStatus=[DateTime]::MinValue
            }
            if($liveDeferred.Count){
                $deferred=@($liveDeferred);$liveDeferred=@()
                foreach($c in $deferred){if(Test-DaemonTunnelReady $c.tag){Start-DaemonProbe $c}else{$liveDeferred+=,$c}}
            }
            if($liveRound -and -not $probes.Count -and -not $liveDeferred.Count){$liveRound=$false;$initialRound=$false;$checkingSince=$null}
        }
        Invoke-DaemonDecision
        if($pin.mode -eq 'pinned' -and $pin.tag -notin @($paths.Candidates|ForEach-Object {$_.tag})){$confirmed=$false;$errorText='Закреплённый путь не работает: отключён или отсутствует';$checkingSince=$null}
        if($portConflict){$errorText=$portConflict.message}
        $statusInterval=1;if($portConflict -and $now -lt $retryAt){$statusInterval=5}
        if(($now-$lastStatus).TotalSeconds -ge $statusInterval){Publish-TransportStatus}
        # While the first path is being proved, probe results are read every 100 ms instead of 300 ms.
        Start-Sleep -Milliseconds $(if($liveDeferred.Count){50}elseif(-not $confirmed -and $probes.Count){100}else{300})
    }
    $errorText='Транспорт остановлен';$stopping=$true
}catch{
    $exitCode=1;$checkingSince=$null
    # Текст чужого исключения может содержать адрес/пароль — публикуем только категорию.
    $errorText='Ошибка транспорта: проверьте настройки, файлы профиля и бинарные файлы'
    if($locked){Write-TransportLog $root 'fatal' (Get-TransportErrorDetail $_);Write-TransportLog $root 'process-failed' (New-TransportDiagnostic $null 'transport' 'initialization-failed')}else{Write-Error 'Транспорт уже запущен или блокировка недоступна' -ErrorAction Continue}
}finally{
    if($reloadJob){Stop-Job $reloadJob;Remove-Job $reloadJob -Force}
    Stop-TransportProbes;Stop-DaemonObservation
    foreach($child in @($tunnelChildren.Values)){Stop-TransportProcess $child};Stop-TransportProcess $engine;$engine=$null;$confirmed=$false
    if($locked){try{Publish-TransportStatus;Write-TransportLog $root 'stop'}finally{$mutex.ReleaseMutex()}}
    if($mutex){$mutex.Dispose()};if($parent){$parent.Dispose()}
}

exit $exitCode
