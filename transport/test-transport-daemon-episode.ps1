#requires -Version 5.1
# T2: daemon functions, fake clock and manually delivered results; no network/process/VPN or waiting.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
. (Join-Path $PSScriptRoot 'Transport.Decide.ps1')
. (Join-Path $PSScriptRoot 'Transport.Quality.ps1')
. (Join-Path $PSScriptRoot 'Transport.Events.ps1')
$script:realSendBus=${function:Send-TransportBusEvent}
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Transport.Daemon.ps1'),[ref]$null,[ref]$errors)
if($errors){throw ($errors|Out-String)}
foreach($fn in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
    . ([scriptblock]::Create($fn.Extent.Text))
}
$script:testEngineApiReady=${function:Test-TransportEngineApiReady}
$script:testPublishStatus=${function:Publish-TransportStatus}
$script:testPublishBusStatus=${function:Publish-DaemonBusStatus}
$count=0
function Assert($Value,[string]$Text){if(-not $Value){throw ('T2: '+$Text)};$script:count++}
function Get-DaemonTime {$script:clockMs}
function Send-TransportBusEvent($Bus,$Topic,$Fields){$script:published+=@{topic=$Topic;fields=$Fields}}
function Write-TransportLog($Root,$Name,$Fields){$script:logged+=@{name=$Name;fields=$Fields}}
function Write-DaemonPathCheck {}
function Save-TransportMemory {}
function Save-TransportQualityMemory {}
function Publish-DaemonBusReady {}
function Publish-TransportStatus {}
function Publish-DaemonBusStatus {}
function Stop-TransportEvents {}
function Set-TransportSelector($Options,$Secret,$Tag){$script:selectorCalls+=,$Tag;$script:actualSelector=$Tag}
function Start-TransportProbe {throw 'Unexpected full legacy probe'}
function Stop-TransportProbe {}
function Start-TransportPathCheck {
    param($Candidate,$Profile,[switch]$ConfirmStall,$TimeoutSeconds,$StallSeconds)
    $script:started+=@{tag=$Candidate.tag;verify=[bool]$ConfirmStall;timeout=$TimeoutSeconds}
    @{event=$null;stopped=$false}
}
function Receive-TransportPathCheck($Check){$Check.event}
function Stop-TransportPathCheck($Check){if($Check){$Check.stopped=$true}}
function Start-DaemonDirectCheck { $script:directStarts++;@{event=$null;stopped=$false} }
function Receive-TransportDirectCheck($Check){$Check.event}
function Stop-TransportDirectCheck($Check){if($Check){$Check.stopped=$true}}
# Keep the real start/stop/loop functions; replace only process/config/API boundaries.
$script:writeTransportJson=${function:Write-TransportJson}
function Write-TransportJson {
    param([string]$Path,$Value,[switch]$Private,[switch]$Durable,[switch]$System)
    if($script:fakeEngineIO){return}
    & $script:writeTransportJson @PSBoundParameters
}
function Reset-DaemonPorts {$false}
function New-TransportConfig {
    param($Settings,$Paths,$Secret,$Tag,$Interface)
    $script:configBinds+=,[bool]$Settings.Options.bindPhysical
    @{outbounds=@(@{tag='active';default=(Get-DaemonSelectorTarget $Tag)})}
}
function Test-TransportConfigFile {}
function Set-TransportProcessPriority {$true}
function Save-TransportOwner {}
function Start-TransportProcess {
    $script:engineStarts++;$script:actualSelector=Get-DaemonSelectorTarget $active
    @{Process=@{HasExited=$false;ExitCode=1};stopped=$false}
}
function Stop-TransportProcess($Child){if($Child){$Child.stopped=$true;$script:engineStops++}}
function Wait-TransportEngineReady([int]$Port,[int]$TimeoutMs){
    $script:initialWaits++
    Assert ($TimeoutMs -eq 3000) 'startup readiness wait changed'
    # Simulate the existing wait returning false at 3 s, without sleeping.
    $script:clockMs+=$TimeoutMs
    return $false
}
function Test-TransportEngineApiReady {
    $script:apiChecks++
    if($script:realApiObserver){return (& $script:testEngineApiReady)}
    if($script:apiChecks -gt $script:apiFalseChecks){return @{target=$engineApiTarget;active=$active;generation=$checkGeneration}}
    return $false
}
# External HTTP boundary: tasks finish only when the test supplies an answer.
# All request selection, generation checks, JSON parsing and completion remain real.
function Test-TransportEngineListener {param([int]$Port) return $true}
function New-TransportEngineApiClient {
    $completion=New-Object 'Threading.Tasks.TaskCompletionSource[string]'
    $client=[pscustomobject]@{disposed=$false;completion=$completion;method=$null;uri=$null}
    $client|Add-Member ScriptMethod GetStringAsync {
        param($Uri)
        $this.method='GET';$this.uri=$Uri
        return $this.completion.Task
    }
    $client|Add-Member ScriptMethod Dispose {$this.disposed=$true}
    $script:apiClients+=,$client
    return $client
}
function Test-TransportVpnOff {return $script:vpnOff}
function Get-TransportNetworkSnapshot {param($Options,[switch]$Force) $script:networkRefreshes++;@{network=$network;metered=$false}}
function Start-DaemonReader {param([switch]$NewEngine) $script:readerStarts++}
function Write-DaemonWizardProgress {}
function New-TransportDiagnostic($Child,$Candidate,$Reason){
    [pscustomobject]@{reason=$Reason;portConflict=$null;stderr='';candidate=$Candidate}
}
function Engine-Step {
    # The real production loop step, including readiness, fuse, exit and restart.
    Update-DaemonEngine ([DateTime]'2026-01-01Z').AddMilliseconds($script:clockMs)
}
function Fixture([int]$Candidates=3){
    $script:TransportTestBuild=$false;$script:transportFaults=@{};$script:faultRejectedSeen=0L;$script:FaultClearFuseMs=2000;$script:TransportFaultLimit=32
    $script:clockMs=100;$script:root='/unused';$script:network=@{id='test-net';available=$true;interface='fake';ip='192.0.2.1'}
    $script:settings=@{Transport=@{};Profile=@{};Options=@{switchStallSeconds=8;switchStallConns=2;apiPort=29095;restartDelaySec=3}}
    $script:paths=@{Candidates=@();Tunnels=@();Outbounds=@()};$script:rows=@()
    for($i=0;$i -lt $Candidates;$i++){
        $tag='p'+$i
        $script:paths.Candidates+=@{tag=$tag;port=(10000+$i);title=$tag}
        $script:rows+=@{tag=$tag;state='remembered';enabled=$true;latencyMs=(100+$i*10);kbps=$null;checkedAt=$null;lastOkAt=$null;lastFailAt=$null}
    }
    $script:active='p0';$script:pin=@{mode='auto';tag=$null};$script:memory=@{networks=@{}}
    $script:engine=@{Process=@{HasExited=$false}};$script:secret=''
    $script:busEngineReady=$true;$script:networkRefreshPending=$false;$script:engineWait=$null;$script:EngineReadyFuseMs=20000
    $script:decision=New-TransportDecisionState 0 'p0' -SwitchEpisode:$true
    $script:verdict=$null;$script:eventQueue=@();$script:pathChecks=@{};$script:gateOkUntil=@{};$script:pathCheckStartedAt=@{}
    $script:probes=@{};$script:liveDeferred=@();$script:liveRound=$false;$script:initialRound=$false;$script:directCheck=$null
    $script:episodeDeferred=@();$script:lightProof=@{};$script:tunnelReadyUntil=@{};$script:tunnelChildren=@{}
    $script:checkGeneration=0;$script:checkRequest=0;$script:episodeSerial=0;$script:episodeId=''
    $script:q=$null;$script:qualitySnapshot=$null;$script:qualityClass='unknown';$script:qualityNotice=''
    $script:qualityInputId=$null;$script:qualityInputClass=$null
    $script:confirmed=$true;$script:holdActive=$true;$script:lastRecoveryAt=99;$script:reader=$null
    $script:DaemonEventLimit=512;$script:daemonEventsQueued=0;$script:daemonEventsDropped=0;$script:daemonCheckPolls=0;$script:daemonProbesStarted=0
    $script:LightProbeFuseMs=3000;$script:VerifyProbeFuseMs=12000;$script:published=@();$script:logged=@();$script:started=@();$script:selectorCalls=@();$script:directStarts=0
    $script:fakeEngineIO=$true;$script:engineStarts=0;$script:engineStops=0;$script:initialWaits=0;$script:readerStarts=0
    $script:apiChecks=0;$script:apiFalseChecks=0;$script:engineApiCheck=$null;$script:engineApiTarget='p0'
    $script:realApiObserver=$false;$script:apiClients=@();$script:actualSelector='p0';$script:configBinds=@();$script:vpnOff=$true;$script:networkRefreshes=0
    $script:startFailures=0;$script:engineReadyTimeouts=0;$script:EngineReadyFailureLimit=2;$script:engineAttempted=$false
    $script:retryAt=[DateTime]::MinValue;$script:bindRetry=$null;$script:portConflict=$null;$script:errorText=$null
    $script:daemonStarted=[DateTime]::Now;$script:bindState=@{failures=0;none=$false}
    Initialize-DaemonQuality
}
function Open-Episode {
    Add-DaemonEvent (New-DaemonEvent 'dial-fail' 'p0' 'timeout')
    Invoke-DaemonDecision
}
function Deliver([string]$Tag,[string]$Code){
    Assert ($pathChecks.ContainsKey($Tag)) ('missing request '+$Tag)
    $pathChecks[$Tag].handle.event=New-DaemonEvent 'path-check' $Tag $Code
}
function Answer-Round {
    $script:clockMs=200
    Deliver 'p0' 'refused';Deliver 'p1' 'ok';Deliver 'p2' 'ok'
    $directCheck.handle.event=New-DaemonEvent 'net-up' '' 'ok'
    Invoke-DaemonDecision
}
function Select-Second {
    $script:clockMs=3100;Invoke-DaemonDecision
    Assert ($active -eq 'p1' -and $decision.episode.status -eq 'verifying') 'selector acknowledgement did not start verification'
}
# Actual asynchronous observer: pending/401/empty or invalid body/wrong selector,
# faults and cancellation never prove readiness; successful GET proves current now.
foreach($outcome in @('401','204','invalid','foreign','wrong-target','fault','cancelled','ok')){
    Fixture
    Assert (-not (& $script:testEngineApiReady)) 'new API request was accepted immediately'
    $client=$apiClients[-1]
    Assert ($client.method -eq 'GET' -and $client.uri -eq 'http://127.0.0.1:29095/proxies/active') 'readiness request changed selector or used wrong endpoint'
    Assert (-not (& $script:testEngineApiReady) -and $engineApiCheck -and -not $client.disposed) 'pending API request was awaited or accepted'
    switch($outcome){
        '401' {$client.completion.SetException([Net.Http.HttpRequestException]::new('401'))}
        '204' {$client.completion.SetResult('')}
        'invalid' {$client.completion.SetResult('{')}
        'foreign' {$client.completion.SetResult('{"name":"foreign","now":"p0"}')}
        'wrong-target' {$client.completion.SetResult('{"name":"active","now":"p1"}')}
        'fault' {$client.completion.SetException([InvalidOperationException]::new('fake fault'))}
        'cancelled' {[void]$client.completion.SetCanceled()}
        'ok' {$client.completion.SetResult('{"name":"active","now":"p0"}')}
    }
    $ready=& $script:testEngineApiReady
    Assert ([bool]$ready -eq ($outcome -eq 'ok') -and -not $engineApiCheck -and $client.disposed) ('API result/cleanup lost: '+$outcome)
}
# Stopping an in-flight request does not read its unfinished Result.
Fixture
[void](& $script:testEngineApiReady);$client=$apiClients[-1]
Stop-DaemonEngineApiCheck
Assert (-not $engineApiCheck -and $client.disposed -and -not $client.completion.Task.IsCompleted) 'engine stop retained pending API request or read Result'
# All production creation/invocation sites explicitly opt in, including startup/reset/ack.
$sites=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('New-TransportDecisionState','Invoke-TransportDecision')},$true))
Assert ($sites.Count -eq 4) 'decision call sites changed; audit all opt-ins'
foreach($site in $sites){
    Assert ($site.Extent.Text -match '-SwitchEpisode:\$true') 'legacy decision site in daemon'
    if($site.GetCommandName() -eq 'Invoke-TransportDecision'){
        Assert ($site.Extent.Text -match '-AllowImprovement:' -and $site.Extent.Text -match '-SwitchConfig') 'Q/improvement not forwarded to reducer'
    }
}
Fixture
Reset-DaemonDecision
Assert $decision.episodeEnabled 'reset lost episode mode'
# bindPhysical network transition: no local probes or Q failures while stopped.
Fixture
Add-DaemonQueuedEvent (New-DaemonEvent 'net.change' 'p0' 'network-change')
Start-DaemonEpisodeCheck 'p0'
Assert ($started.Count -eq 0 -and $qualitySnapshot.budgetUsedKiB -eq 0) 'queued network change started/reserved a local probe'
Fixture
$script:settings.Options.bindPhysical=$true
Stop-DaemonObservation
Add-DaemonQueuedEvent (New-DaemonEvent 'net.change' 'p0' 'network-change')
$script:engine=$null
Invoke-DaemonDecision
Assert ($started.Count -eq 0 -and $pathChecks.Count -eq 0 -and $engineWait) 'stopped engine started a network round'
$script:clockMs=4000;Invoke-DaemonDecision
Assert ($verdict.reason.code -ne 'server-unavailable' -and $q.networks[$network.id].banner.Count -eq 0) 'absent probe listeners produced path/Q failures'
$script:networkRefreshPending=$false
# Real Start-TransportEngine sees the 3 s false wait; the API stays false for
# three 300 ms loop iterations, then is ready ~4 s after launch.
$script:clockMs=4100;$script:apiFalseChecks=3
Engine-Step
Assert ($engineStarts -eq 1 -and $initialWaits -eq 1 -and -not $busEngineReady -and $engineWait) 'false startup wait did not defer live engine'
for($i=1;$i -le 4;$i++){
    $before=$apiChecks;$script:clockMs=7100+$i*300
    Engine-Step
    Assert ($apiChecks -eq $before+1) 'loop did not make exactly one readiness observation'
    if($i -le 3){Assert ($started.Count -eq 0 -and -not $busEngineReady -and $engineWait) 'unready API started probes'}
}
Assert ($busEngineReady -and -not $engineWait -and @($eventQueue|Where-Object {$_.kind -eq 'engine-ready'}).Count -eq 1) 'late API readiness did not generate engine-ready/resume'
Invoke-DaemonDecision
Assert ($started.Count -eq 3 -and $decision.episode.status -eq 'open' -and $readerStarts -eq 1) 'engine-ready lost the deferred network round'
$before=$apiChecks;Engine-Step
Assert ($apiChecks -eq $before -and $readerStarts -eq 1) 'ready engine kept polling or repeated engine-ready'
$script:clockMs=8400;Deliver 'p0' 'ok';Invoke-DaemonDecision
Assert ($confirmed -and $decision.episode.status -eq 'closed' -and $verdict.reason.code -ne 'server-unavailable') 'network round did not recover after engine-ready'
# Missing physical interface + VPN off: two real Resolve-TransportBind errors,
# the third attempt must reach its normal unbound fallback despite engineWait.
Fixture
$script:settings.Options.bindPhysical=$true;$script:network.interface='';$script:network.ip='';$script:engine=$null
for($attempt=1;$attempt -le 2;$attempt++){
    Engine-Step;Invoke-DaemonDecision
    Assert (-not $engine -and $startFailures -eq $attempt -and $bindState.failures -eq $attempt -and $engineReadyTimeouts -eq 0) 'bind error consumed readiness allowance or lost normal retries'
    $delay=Get-TransportStartPause $attempt
    Assert ($retryAt -eq ([DateTime]'2026-01-01Z').AddMilliseconds($clockMs).AddSeconds($delay)) 'ordinary start retry pause changed'
    $script:clockMs+=$delay*1000
}
Engine-Step
Assert ($engine -and $bindState.none -and $bindState.failures -eq 3 -and $engineStarts -eq 1 -and $networkRefreshes -eq 2) 'third bind attempt never reached mode=none/process creation'
Assert ($configBinds.Count -eq 1 -and -not $configBinds[0] -and $startFailures -eq 0 -and $engineReadyTimeouts -eq 0) 'unbound config/start counter differs from original successful-start behavior'
Engine-Step
Assert ($busEngineReady -and -not $engineWait) 'fallback process could not become ready'
# An already open episode resumes with fresh clocks/tickets; stale refused is discarded.
Fixture;Open-Episode
$old=$pathChecks.p0.handle;$oldGeneration=$checkGeneration;$oldEpisode=$episodeId
$script:engine=$null;$old.event=New-DaemonEvent 'path-check' 'p0' 'refused'
Receive-DaemonChecks
Assert ($old.stopped -and $q.networks[$network.id].banner.Count -eq 0 -and $eventQueue.Count -eq 0) 'stopped-engine refused reached Q/reducer'
$script:clockMs=15000;Invoke-DaemonDecision
Assert ($decision.episode.status -eq 'open' -and $verdict.reason.code -ne 'server-unavailable') 'waiting episode expired as path failure'
$script:busEngineReady=$false
Start-TransportEngine;Engine-Step;Invoke-DaemonDecision
Assert ($started.Count -eq 6 -and $checkGeneration -gt $oldGeneration -and $episodeId -ne $oldEpisode -and $decision.episode.openedAt -eq 18000) 'open episode did not resume with a fresh generation/clock'
$script:clockMs=18100;Deliver 'p0' 'ok';Invoke-DaemonDecision
Assert ($confirmed -and $decision.episode.status -eq 'closed') 'resumed episode hung'
# API never comes up: real stop/start once, then no further restart or success.
Fixture;Open-Episode
$script:apiFalseChecks=[int]::MaxValue
Start-TransportEngine
$firstEngine=$engine
$script:clockMs=$engineWait.at+$EngineReadyFuseMs;Engine-Step
Assert ($firstEngine.stopped -and -not $engine -and $engineWait.expired -and $engineReadyTimeouts -eq 1) 'fuse did not stop hung engine/count failure'
Assert ($decision.episode.status -eq 'closed' -and -not $confirmed -and -not $busEngineReady -and $errorText -match 'engine-ready-timeout') 'readiness timeout announced success or left episode open'
Assert (@($logged|Where-Object {$_.name -eq 'restart' -and $_.fields.why -eq 'engine-ready-timeout'}).Count -eq 1) 'timeout restart reason not logged exactly once'
Engine-Step
Assert ($engineStarts -eq 1) 'timeout bypassed existing restart backoff'
$script:clockMs+=3000;Engine-Step
Assert ($engineStarts -eq 2 -and $initialWaits -eq 2 -and $engineReadyTimeouts -eq 1 -and -not $engineWait.expired) 'real restart reset failures before readiness or failed to rearm fuse'
$script:clockMs=$engineWait.at+$EngineReadyFuseMs;Engine-Step
Assert (-not $engine -and $engineReadyTimeouts -eq $EngineReadyFailureLimit -and -not $confirmed -and -not $checkingSince) 'restart exhaustion did not leave failed status'
for($i=0;$i -lt 5;$i++){$script:clockMs+=30000;Engine-Step;Invoke-DaemonDecision}
Assert ($engineStarts -eq 2 -and $engineStops -eq 2 -and -not $confirmed -and $decision.episode.status -eq 'closed') 'readiness failure caused an endless restart/success loop'
Assert (@($logged|Where-Object {$_.name -eq 'ready'}).Count -eq 0) 'unready process was logged ready'
# A retry that really becomes ready resets the readiness timeout series.
Fixture;Open-Episode;$script:apiFalseChecks=1
Start-TransportEngine
$script:clockMs=$engineWait.at+$EngineReadyFuseMs;Engine-Step
$script:clockMs+=3000;Engine-Step;Engine-Step
Assert ($busEngineReady -and -not $engineWait -and $engineReadyTimeouts -eq 0 -and -not $confirmed) 'authenticated readiness did not reset failures without claiming path success'
# Dead process takes the original exit path, never the API/fuse path.
Fixture;Open-Episode;Answer-Round;Select-Second
$dead=$engine;$dead.Process.HasExited=$true;$before=$apiChecks
Engine-Step
Assert ($dead.stopped -and -not $engine -and $apiChecks -eq $before) 'dead process entered API readiness path'
Assert (@($eventQueue|Where-Object {$_.kind -eq 'post-switch-verify' -and $_.code -eq 'process-exited'}).Count -eq 1) 'engine exit lost pending verification failure'
Assert (@($eventQueue|Where-Object {$_.kind -eq 'engine-exit'}).Count -eq 1 -and @($logged|Where-Object {$_.name -eq 'restart' -and $_.fields.why -eq 'process-failed'}).Count -eq 1) 'original exit/restart handling changed'
# Verify is deferred too, without spending its single Q reservation before readiness.
Fixture;Open-Episode;Answer-Round
$script:clockMs=3100
# Simulate selector acknowledgement arriving as engine readiness is invalidated.
$script:busEngineReady=$false
Assert (Switch-TransportActive 'p1' $false 'verdict-test') 'real switch failed during deferred verification'
$decision.currentTag='p1';$decision.episode.open=$false;$decision.episode.status='verifying';$decision.episode.verifyAt=3100
$script:busEngineReady=$false;Start-DaemonVerification 'p1'
Assert (-not $q.verified -and @($started|Where-Object {$_.verify}).Count -eq 0) 'unready verification consumed Q or started I/O'
$script:clockMs=6000
Engine-Step
Assert ($pathChecks.p1.purpose -eq 'post-switch-verify' -and $pathChecks.p1.generation -eq $checkGeneration -and $decision.episode.verifyAt -eq 6000) 'engine-ready did not resume deferred verification'
$script:clockMs=6100;Deliver 'p1' 'ok';Invoke-DaemonDecision
Assert ($confirmed -and $decision.episode.status -eq 'closed') 'resumed verification did not close on its real result'
# Execute the real control-pass pin branch and real switch, without assigning its target.
$pinControl=$ast.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if($newPin.mode -ne $pin.mode')},$true)
$pinControlBlock=[scriptblock]::Create($pinControl.Extent.Text)
foreach($tag in @('p1','disabled')){
    Fixture
    $script:realApiObserver=$true
    Start-TransportEngine
    Assert ($initialWaits -eq 1 -and -not $busEngineReady -and $engineApiTarget -eq 'p0') 'pin fixture did not start p0 with false initial wait'
    Engine-Step;$oldClient=$apiClients[-1]
    $newPin=@{mode='pinned';tag=$tag};$now=([DateTime]'2026-01-01Z').AddMilliseconds($clockMs)
    . $pinControlBlock
    $expected=if($tag -eq 'disabled'){'unavailable'}else{'p1'}
    Assert ($active -eq $tag -and $engineApiTarget -eq $expected -and $actualSelector -eq $expected -and $oldClient.disposed) 'control pin did not update selector/target or cancel old check'
    # A late old HTTP result cannot undo the pin, even after cancellation.
    $oldClient.completion.SetResult('{"name":"active","now":"p0"}')
    Engine-Step
    Assert (-not $busEngineReady -and $engineApiCheck.target -eq $expected) 'stale p0 result confirmed a different selector'
    $apiClients[-1].completion.SetResult((ConvertTo-Json -Compress @{name='active';now=$expected}))
    Engine-Step
    Assert ($busEngineReady -and -not $engineWait -and $actualSelector -eq $expected -and $selectorCalls.Count -eq 1 -and $selectorCalls[0] -eq $expected) 'late readiness overwrote pinned selector or did not resume'
    Assert (@($apiClients|Where-Object {$_.method -ne 'GET'}).Count -eq 0) 'readiness sent a mutating request'
    $readyEvents=@($eventQueue|Where-Object {$_.kind -eq 'engine-ready'})
    Assert ($readyEvents.Count -eq 1 -and $readyEvents[0].tag -eq $tag) 'engine-ready used an obsolete selector tag'
}
# Completed results also need target + generation validation when no control cancellation runs.
foreach($change in @('generation','target')){
    Fixture;$script:realApiObserver=$true;Start-TransportEngine;Engine-Step
    $client=$apiClients[-1];$client.completion.SetResult('{"name":"active","now":"p0"}')
    if($change -eq 'generation'){$script:checkGeneration++}
    else{Assert (Switch-TransportActive 'p1' $false 'verdict-test') 'test switch failed'}
    Engine-Step
    Assert (-not $busEngineReady -and $client.disposed -and $apiClients.Count -eq 2) 'obsolete completed API result was accepted instead of rechecked'
}
# Even a proof already returned to the caller is rejected after a switch/generation change.
foreach($change in @('generation','target')){
    Fixture;$script:realApiObserver=$true;Start-TransportEngine;Engine-Step
    $apiClients[-1].completion.SetResult('{"name":"active","now":"p0"}')
    $proof=& $script:testEngineApiReady
    if($change -eq 'generation'){$script:checkGeneration++}
    else{Assert (Switch-TransportActive 'p1' $false 'verdict-test') 'proof test switch failed'}
    Complete-DaemonEngineReady $proof.target $proof.generation $proof.active
    Assert (-not $busEngineReady -and $engineApiCheck -and $engineApiCheck.active -eq $active -and $engineApiCheck.generation -eq $checkGeneration) 'Complete accepted obsolete proof instead of starting a fresh check'
}
# Condition changes reopen the readiness allowance; process failures keep the series.
Fixture;$script:engineReadyTimeouts=2;$script:startFailures=4
Stop-DaemonObservation -EngineRestart
Assert ($engineReadyTimeouts -eq 2 -and $startFailures -eq 4) 'process exit reset the readiness/start error series'
Stop-DaemonObservation
Assert ($engineReadyTimeouts -eq 0 -and $startFailures -eq 4) 'network/pin/reload generation failed to reset only readiness allowance'
$script:engineReadyTimeouts=2
Add-DaemonQueuedEvent (New-DaemonEvent 'net.change' 'p0' 'network-change')
Assert ($engineReadyTimeouts -eq 0 -and $startFailures -eq 4) 'network event failed to reopen readiness allowance'
# Q annotations survive parallel probes and choose healthy p2 over faster TSPU p1.
Fixture
$q.networks[$network.id].tspu.p1=@{count=2;until=999999}
Open-Episode
$script:clockMs=200;Deliver 'p0' 'refused';Deliver 'p1' 'ok';Receive-DaemonChecks
$script:clockMs=250;Deliver 'p2' 'ok';$directCheck.handle.event=New-DaemonEvent 'net-up' '' 'ok';Invoke-DaemonDecision
$script:clockMs=3100;Invoke-DaemonDecision
Assert ($active -eq 'p2' -and $decision.episode.status -eq 'verifying') 'Q TSPU ordering was lost at final selection'
# Public profile -> actual Read-TransportSettings -> initial Q and reload of the same state.
Fixture
$configRoot=Join-Path ([IO.Path]::GetTempPath()) ('t2-profile-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($configRoot)
try{
    $script:fakeEngineIO=$false
    $sshFile=Join-Path $configRoot 'ssh.json';$channelFile=Join-Path $configRoot 'channel.json'
    Write-TransportJson $sshFile @{sshExecutable='ssh';serverAddress='example.test';login='user';keyPath='unused';knownHostsPath='unused'}
    Write-TransportJson $channelFile @{outbounds=@()}
    $config=@{transport=@{profilePath=$sshFile;channelPath=$channelFile;bindPhysical=$false;apiPort=29095;priority=@('p');entries=@()};profile=@{transport=@{switch=@{probeBudgetKiBPer10m=@{mobile=64}}}}}
    $configFile=Join-Path $configRoot 'config.json';Write-TransportJson $configFile $config
    $script:settings=Read-TransportSettings $configRoot;$script:q=$null;$script:qualityClass='mobile'
    Initialize-DaemonQuality
    Assert ($qualitySnapshot.budgetKiB -eq 64 -and $settings.Options.apiPort -eq 29095 -and $settings.Transport.profilePath -eq $sshFile -and $settings.Transport.priority[0] -eq 'p') 'public switch missing at startup or runtime fields lost'
    $originalQ=$q
    $config.transport.switch=@{probeBudgetKiBPer10m=@{mobile=192};minStayMs=99999}
    $config.profile.transport.switch.probeBudgetKiBPer10m.mobile=80
    Write-TransportJson $configFile $config
    $script:settings=Read-TransportSettings $configRoot;Initialize-DaemonQuality
    Assert ([object]::ReferenceEquals($originalQ,$q) -and $qualitySnapshot.budgetKiB -eq 80 -and $q.config.minStayMs -eq 30000 -and $settings.Transport.channelPath -eq $channelFile) 'profile priority/reload did not replace runtime switch while preserving Q/runtime fields'
    $config.profile.transport.switch=@{probeBudgetKiBPer10m=@{mobile=64}}
    [void]$config.transport.Remove('switch');Write-TransportJson $configFile $config
    $script:settings=Read-TransportSettings $configRoot;Initialize-DaemonQuality
    Assert ($qualitySnapshot.budgetKiB -eq 64) 'reload without runtime switch lost profile mobile budget'
}finally{Remove-Item -LiteralPath $configRoot -Recurse -Force}
Fixture
Open-Episode
Assert ($verdict.action -eq 'probe-round' -and $started.Count -eq 3 -and $directStarts -eq 1) 'round/direct verdict not executed immediately'
Assert (-not $confirmed -and @($started|Where-Object {$_.verify}).Count -eq 0) 'light round announced success or started bulk probe'
Assert (@($started|Where-Object {$_.timeout -ne 3}).Count -eq 0) 'light fuse not 3000 ms'
Assert (@($published|Where-Object {$_.topic -eq 'transport.episode' -and $_.fields.phase -eq 'open'}).Count -eq 1) 'episode open not published'
$script:clockMs=200;Deliver 'p0' 'ok';Invoke-DaemonDecision
Assert ($confirmed -and $decision.episode.status -eq 'closed') 'real active success did not close episode'
$script:clockMs=300;Open-Episode
Assert ($started.Count -eq 6 -and $directStarts -eq 2) 'light round throttled for 60 seconds'
Assert (@($logged|Where-Object {$_.name -eq 'switch.episode' -and $_.fields.phase -eq 'close'}).Count -ge 1) 'episode close not logged'
# More than four candidates: bounded concurrency and replenishment from completion events.
Fixture 8;Open-Episode
Assert ($pathChecks.Count -eq 4 -and $episodeDeferred.Count -eq 4 -and $pathChecks.ContainsKey('p0')) 'round is not capped at four or active not first'
$script:clockMs=200;Deliver 'p1' 'ok';Receive-DaemonChecks
Assert ($pathChecks.Count -eq 4 -and $episodeDeferred.Count -eq 3) 'completed slot not replenished'
# A switch is authoritative exactly once; a failed verify immediately tries the next responder.
Fixture;Open-Episode;Answer-Round;Select-Second
Assert (-not $confirmed -and @($started|Where-Object {$_.verify}).Count -eq 1) 'selector/banner treated as verify success'
$changes=@($published|Where-Object {$_.topic -eq 'transport.switch'})
Assert ($changes.Count -eq 1 -and $changes[0].fields.from -eq 'p0' -and $changes[0].fields.to -eq 'p1' -and $changes[0].fields.at -eq 3100 -and $changes[0].fields.changed) 'switch fields missing'
Assert ($decision.switches.Count -eq 1) 'authoritative switch not delivered to reducer'
$script:clockMs=3200;Deliver 'p1' 'timeout';Invoke-DaemonDecision
Assert ($active -eq 'p2' -and $selectorCalls.Count -eq 2) 'failed verify blocked by daemon switch cooldown'
Assert ($eventQueue.Count -eq 1 -and $eventQueue[0].kind -eq 'post-switch-verify' -and $eventQueue[0].code -eq 'skipped') 'Q did not skip second bulk request in episode'
$script:clockMs=3300;Invoke-DaemonDecision
Assert ($decision.episode.status -eq 'closed' -and -not $confirmed) 'skipped verify announced success or hung'
Assert ($decision.switches.Count -eq 2 -and @($started|Where-Object {$_.verify}).Count -eq 1) 'switch/verification count wrong'
Assert (@($logged|Where-Object {$_.name -eq 'switch.episode' -and $_.fields.phase -eq 'decide'}).Count -eq 2) 'decisions not logged'
# Real verification success; same selector PUT produces no switch event/history.
Fixture;Open-Episode;Answer-Round;Select-Second
$script:clockMs=3200;Deliver 'p1' 'ok';Invoke-DaemonDecision
Assert ($confirmed -and $decision.episode.status -eq 'closed') 'verified success not confirmed'
$before=@($published|Where-Object {$_.topic -eq 'transport.switch'}).Count
Assert (Switch-TransportActive 'p1' $true 'same') 'same selector PUT failed'
Assert (@($published|Where-Object {$_.topic -eq 'transport.switch'}).Count -eq $before -and $decision.switches.Count -eq 1) 'changed=false published as switch'
# Exhaustion between banner and selection -> explicit skipped result, no extra I/O/metrics success.
Fixture;Open-Episode;Answer-Round
Update-DaemonQuality 'traffic' @{id=$network.id;eventId='exhaust';bytes=524288}
Select-Second
Assert (@($started|Where-Object {$_.verify}).Count -eq 0 -and $eventQueue[0].code -eq 'skipped') 'exhausted budget started bulk probe'
$script:clockMs=3200;Invoke-DaemonDecision
Assert (-not $confirmed -and $decision.episode.verifySkipped -and $qualitySnapshot.kib64Ms -eq $null) 'budget skip manufactured success'
# Fuse expiry is failure, never success; generation cancellation never delivers late result.
Fixture;Open-Episode;Answer-Round;Select-Second
$old=$pathChecks.p1.handle
$script:clockMs=15100;Receive-DaemonChecks
Assert ($eventQueue[-1].kind -eq 'post-switch-verify' -and $eventQueue[-1].code -eq 'timeout' -and -not $confirmed) 'verify fuse did not yield timeout'
Fixture;Open-Episode;Answer-Round;Select-Second
$old=$pathChecks.p1.handle
Stop-DaemonObservation
Assert ($old.stopped -and $pathChecks.Count -eq 0 -and $decision.episodeEnabled) 'generation reset did not cancel verification/preserve opt-in'
$old.event=New-DaemonEvent 'path-check' 'p1' 'ok';Receive-DaemonChecks
Assert ($eventQueue.Count -eq 0 -and -not $confirmed) 'late cancelled result accepted'
# Engine exit during verify produces an actual failure instead of leaving it permanently pending.
Fixture;Open-Episode;Answer-Round;Select-Second
Stop-DaemonObservation -EngineRestart
Assert ($eventQueue[0].kind -eq 'post-switch-verify' -and $eventQueue[0].code -eq 'process-exited') 'engine exit left verify pending'
# AllowImprovement uses Q's flag; pure reducer is exercised through actual daemon invocation.
Fixture
$script:qualitySnapshot.allowImprovement=$false
Assert (-not (Test-DaemonImprovement)) 'Q improvement flag ignored'
$script:qualitySnapshot.allowImprovement=$true
Assert (Test-DaemonImprovement) 'improvements never enabled'
$script:pin.mode='pinned'
Assert (-not (Test-DaemonImprovement)) 'pinned path permits improvement'
# Invalidated tickets are ignored even if a faulty wrapper returns a completed old handle.
Fixture;Open-Episode
$pathChecks.p0.generation=-1;$script:clockMs=200;Deliver 'p0' 'ok';Receive-DaemonChecks
Assert (@($eventQueue|Where-Object {$_.tag -eq 'p0'}).Count -eq 0) 'old generation ticket accepted'
# Real B4B output serializer/allowlist: manually pump the writer, no worker threads.
$script:captureSendBus=${function:Send-TransportBusEvent}
Set-Item Function:Send-TransportBusEvent $script:realSendBus
Initialize-TransportEvents
$writer=[IO.StringWriter]::new()
$wireBus=[RemoteAgents.TransportBus]::new([IO.MemoryStream]::new(),$writer)
foreach($topic in @('transport.episode','transport.switch','net.quality')){
    Send-TransportBusEvent $wireBus $topic ([ordered]@{at=123;changed=$true;phase='open'})
}
[void]$wireBus.GetType().GetMethod('WritePending',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($wireBus,@())
$frames=@($writer.ToString().Trim().Split("`n")|ForEach-Object {ConvertFrom-Json $_.Substring(5)})
Assert ($frames.Count -eq 3 -and $frames[2].topic -eq 'net.quality' -and $frames[1].fields.changed -eq $true) 'real bus rejected quality/episode/switch frame'
[void]$wireBus.Complete(0)
Set-Item Function:Send-TransportBusEvent $script:captureSendBus
# T3: exercise real input parsing -> daemon fault handling -> T2 reducer, with fake time.
function Fault-Frame([string]$Fault,[string]$Tag='p0',[long]$Ms=0){
    '@bus '+(ConvertTo-Json -Compress @{topic='transport.command';fields=@{fault=$Fault;tag=$Tag;ms=$Ms}})
}
function Fault-Input([string]$Text,[bool]$TestBuild=$true){
    $script:bus=[RemoteAgents.TransportBus]::new([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($Text)),[IO.StringWriter]::new(),$TestBuild)
    [void]$bus.GetType().GetMethod('ReadInput',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($bus,@())
    Receive-DaemonBus
    $bus.Dispose();$script:bus=$null
}
Fixture
Fault-Input (Fault-Frame 'drop') $false
Assert ($transportFaults.Count -eq 0 -and $eventQueue.Count -eq 0 -and $logged[-1].name -eq 'fault.reject') 'Main accepted command on stdin or did not log rejection'
Invoke-DaemonFaultCommand @{fault='drop';tag='p0'}
Assert ($transportFaults.Count -eq 0 -and (Get-DaemonSelectorTarget 'p0') -eq 'p0') 'Main bypass event applied a fault'
Fixture;$script:TransportTestBuild=$true
Fault-Input (Fault-Frame 'drop')
Assert ((Get-DaemonSelectorTarget 'p0') -eq 'unavailable' -and $actualSelector -eq 'unavailable' -and -not $confirmed) 'Test drop did not select unavailable'
Assert ($active -eq 'p0' -and $decision.switches.Count -eq 0) 'fault application invented a switch/selection'
Assert (@(Get-DaemonFaultSnapshot).Count -eq 1) 'fault snapshot missing'
# Run the production file/status serializers across a capture-only filesystem boundary.
$script:statusDoc=$null
$saveWriter=${function:Write-TransportJson}
function Get-TransportConfiguredPorts {$null}
function Get-TransportHelperStatus {$null}
function Write-TransportJson($Path,$Value){$script:statusDoc=$Value}
try{
    $script:lastStatusKey=$null;$script:lastStatusWriteMs=0;$script:StatusHeartbeatMs=5000
    $script:exitCode=0;$script:stopping=$false
    & $script:testPublishStatus
    Assert ($statusDoc.faults.Count -eq 1 -and $statusDoc.faults[0].fault -eq 'drop' -and -not $statusDoc.ok) 'fault absent from actual transport.json state'
    $statusWriter=[IO.StringWriter]::new();$script:bus=[RemoteAgents.TransportBus]::new([IO.MemoryStream]::new(),$statusWriter)
    $script:busStatusKey=$null
    Set-Item Function:Send-TransportBusEvent $script:realSendBus
    & $script:testPublishBusStatus
    [void]$bus.GetType().GetMethod('WritePending',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($bus,@())
    $statusFrame=ConvertFrom-Json $statusWriter.ToString().Trim().Substring(5)
    $statusFaults=ConvertFrom-Json $statusFrame.fields.faults
    Assert ($statusFrame.topic -eq 'transport.status' -and $statusFaults[0].tag -eq 'p0') 'fault absent from actual status bus frame'
    $bus.Dispose();$script:bus=$null
}finally{Set-Item Function:Write-TransportJson $saveWriter;Set-Item Function:Send-TransportBusEvent $script:captureSendBus}
Invoke-DaemonDecision
Assert (@($published|Where-Object {$_.topic -eq 'transport.episode' -and $_.fields.faults[0].fault -eq 'drop'}).Count -eq 1) 'fault metadata missing from episode'
Assert ($decision.episode.status -eq 'open' -and $pathChecks.p0 -and -not $pathChecks.p0.handle -and $started.Count -eq 2) 'drop failed to open normal episode or started I/O for injected path'
Assert (-not $q.attempts.ContainsKey('p0') -and $qualitySnapshot.budgetUsedKiB -eq 2) 'synthetic fault spent real-probe retry/bandwidth allowance'
$script:clockMs=200;Deliver 'p1' 'ok';Deliver 'p2' 'ok';$directCheck.handle.event=New-DaemonEvent 'net-up' '' 'ok';Invoke-DaemonDecision
# A passive success while faulted is a failure, never recovery.
Add-DaemonEvent (New-DaemonEvent 'path-check' 'p0' 'ok');Invoke-DaemonDecision
Assert ($decision.episode.status -eq 'open' -and -not $confirmed) 'a real/late success escaped fault overlay'
$script:clockMs=10099;Invoke-DaemonDecision
Assert ($active -eq 'p0') 'drop bypassed blip threshold'
$script:clockMs=10100;Invoke-DaemonDecision
Assert ($active -eq 'p1' -and $actualSelector -eq 'p1' -and $decision.episode.status -eq 'verifying') 'drop did not switch via reducer to healthy candidate'
$script:clockMs=10200;Deliver 'p1' 'ok';Invoke-DaemonDecision
Assert ($confirmed -and $decision.episode.status -eq 'closed') 'drop broke normal post-switch verification'
$script:clockMs=10300;Fault-Input (Fault-Frame 'clear')
Assert ($active -eq 'p1' -and -not (Test-DaemonFault 'p0') -and (Get-DaemonSelectorTarget 'p0') -eq 'p0') 'clear forced fallback selection instead of allowing improvement'
$script:clockMs=10400;Deliver 'p0' 'ok';Invoke-DaemonDecision
$rows[0].latencyMs=10;$rows[1].latencyMs=120
Assert ($active -eq 'p1') 'clear ignored minStay'
$script:clockMs=40400;Add-DaemonEvent (New-DaemonEvent 'path-check' 'p0' 'ok');Invoke-DaemonDecision
Assert ($active -eq 'p0' -and $decision.episode.status -eq 'verifying') 'cleared path could not return through ordinary improvement'
# blip 5000 opens an episode, expires by tick, and only a real success closes it.
Fixture;$script:TransportTestBuild=$true
Fault-Input (Fault-Frame 'blip' 'p0' 5000);Invoke-DaemonDecision
$script:clockMs=200;Deliver 'p1' 'ok';Deliver 'p2' 'ok';$directCheck.handle.event=New-DaemonEvent 'net-up' '' 'ok';Invoke-DaemonDecision
$script:clockMs=1100;Invoke-DaemonDecision
$script:clockMs=3100;Invoke-DaemonDecision
$script:clockMs=5099
Fault-Input '@bus {"topic":"tick.transport-decide","fields":{}}'
Assert (Test-DaemonFault 'p0') 'blip cleared before duration'
$script:clockMs=5100
Fault-Input '@bus {"topic":"tick.transport-decide","fields":{}}'
Assert (-not (Test-DaemonFault 'p0') -and $actualSelector -eq 'p0' -and -not $confirmed -and $active -eq 'p0') 'tick did not remove blip or announced success'
Assert ($q.attempts.p0 -eq 1 -and $pathChecks.p0.purpose -eq 'light') 'clear bypassed Q or synthetic retries exhausted the recovery slot'
$script:clockMs=5200;Deliver 'p0' 'ok';Invoke-DaemonDecision
Assert ($decision.episode.status -eq 'closed' -and $confirmed -and $decision.switches.Count -eq 0) 'short blip switched or failed to recover on real result'
Assert (@($logged|Where-Object {$_.name -eq 'fault.clear' -and $_.fields.reason -eq 'tick'}).Count -eq 1) 'tick clear log missing'
# No stdin ticks: the existing decision pass fuse rolls back only the injection.
Fixture;$script:TransportTestBuild=$true
Fault-Input (Fault-Frame 'blip' 'p0' 5000)
$script:clockMs=7099;Update-DaemonFaults -Fuse
Assert (Test-DaemonFault 'p0') 'fuse fired early'
$script:clockMs=7100;Update-DaemonFaults -Fuse
Assert (-not (Test-DaemonFault 'p0') -and -not $confirmed -and $logged[-1].fields.reason -ne 'ok') 'fuse failed to roll back blip without success'
# drop does not expire, repeated blip replaces its deadline, and clear is idempotent.
Fixture;$script:TransportTestBuild=$true
Fault-Input (Fault-Frame 'drop');$script:clockMs=999999;Update-DaemonFaults;Update-DaemonFaults -Fuse
Assert (Test-DaemonFault 'p0') 'drop expired without clear'
Fault-Input (Fault-Frame 'blip' 'p0' 1000);$script:clockMs+=500
Fault-Input (Fault-Frame 'blip' 'p0' 5000);$script:clockMs+=500;Update-DaemonFaults
Assert (Test-DaemonFault 'p0') 'old blip deadline cleared new injection'
Fault-Input (Fault-Frame 'clear');$clears=@($logged|Where-Object {$_.name -eq 'fault.clear'}).Count
Fault-Input (Fault-Frame 'clear')
Assert (@($logged|Where-Object {$_.name -eq 'fault.clear'}).Count -eq $clears) 'clear is not idempotent'
# Applying during verification must produce its failure, rather than strand a cancelled ticket.
Fixture;Open-Episode;Answer-Round;Select-Second;$script:TransportTestBuild=$true
Fault-Input (Fault-Frame 'drop' 'p1');Invoke-DaemonDecision
Assert ($active -eq 'p2') 'fault during verification stranded episode'
# One stdin drain can cancel verify and clear the fault before the reducer runs.
# Model the old race: if clear starts a light probe, its real success arrives first.
Fixture;Open-Episode;Answer-Round;Select-Second;$script:TransportTestBuild=$true
$cancelledVerify=$pathChecks.p1.handle;$before=$started.Count
$script:clockMs=3200
Fault-Input ((Fault-Frame 'drop' 'p1')+"`n"+(Fault-Frame 'clear' 'p1'))
$script:clockMs=3300
if($pathChecks.ContainsKey('p1') -and $pathChecks.p1.purpose -eq 'light'){Deliver 'p1' 'ok'}
Assert ($cancelledVerify.stopped -and -not (Test-DaemonFault 'p1') -and -not $confirmed) 'drop/clear lost verify cancellation or manufactured success'
Assert (@($eventQueue|Where-Object {$_.kind -eq 'post-switch-verify' -and $_.tag -eq 'p1' -and $_.code -eq 'timeout'}).Count -eq 1) 'clear discarded cancelled verify failure'
Invoke-DaemonDecision
Assert (-not $confirmed -and $active -eq 'p2' -and $decision.episode.status -eq 'verifying') 'drop/clear confirmed cancelled verify via light success instead of normal failure handling'
Assert (@($started|Select-Object -Skip $before|Where-Object {$_.tag -eq 'p1' -and -not $_.verify}).Count -eq 0) 'clear launched light probe before cancelled verify was reduced'
Assert (@($eventQueue|Where-Object {$_.kind -eq 'post-switch-verify' -and $_.tag -eq 'p2' -and $_.code -eq 'skipped'}).Count -eq 1) 'next selected path bypassed ordinary Q verification budget'
$script:clockMs=3400;Invoke-DaemonDecision
Assert (-not $confirmed -and $decision.episode.verifySkipped) 'Q refusal after cancelled verify manufactured confirmation'
# Invalid metadata never changes state and is never echoed to logs/bus.
Fixture;$script:TransportTestBuild=$true
foreach($fields in @(@{fault='drop';tag='foreign'},@{fault='DROP';tag='p0'},@{fault='blip';tag='p0';ms='60001'},@{fault='blip';tag='p0';ms='NaN'},@{fault='drop';tag='p0';password='sentinel-secret'},@{fault='drop';tag="p0`nforged"})){
    Invoke-DaemonFaultCommand $fields
}
Assert ($transportFaults.Count -eq 0 -and (ConvertTo-Json @($logged,$published) -Depth 30 -Compress) -notmatch 'sentinel-secret|forged|NaN') 'invalid input changed state or leaked secret/raw fields'
# Bounded map and pruning on configuration generation changes.
Fixture 34;$script:TransportTestBuild=$true
for($i=0;$i -lt 34;$i++){Invoke-DaemonFaultCommand @{fault='drop';tag=('p'+$i)}}
Assert ($transportFaults.Count -eq 32 -and $logged[-1].fields.reason -eq 'fault-limit') 'fault map unbounded'
$allCandidates=$paths.Candidates
Start-DaemonPath 'p33' -Gate;$oldCheck=$pathChecks.p33.handle;$oldEngine=$engine;$generation=$checkGeneration
$reload=@{Settings=$settings;Paths=@{Candidates=@($allCandidates|Where-Object {$_.tag -ne 'p1'});Tunnels=@();Outbounds=@()};Revision='without-p1'}
# Call the same acceptance path as production: stop/reset with OLD paths, then
# accept NEW paths and prune, then restart. Reset alone cannot implement pruning.
Accept-DaemonReload $reload
Assert ($oldCheck.stopped -and $oldEngine.stopped -and $checkGeneration -eq $generation+1 -and $pathChecks.Count -eq 0) 'reload failed to retire old observations before restart'
Assert ($revision -eq 'without-p1' -and -not (Test-DaemonFault 'p1') -and $transportFaults.Count -eq 31 -and (Test-DaemonFault 'p2')) 'reload retained removed injection or discarded retained candidate fault'
Assert (@($logged|Where-Object {$_.name -eq 'fault.clear' -and $_.fields.tag -eq 'p1' -and $_.fields.reason -eq 'config-removed'}).Count -eq 1) 'reload pruning did not log config-removed'
Start-TransportEngine
$reload.Paths=@{Candidates=$allCandidates;Tunnels=@();Outbounds=@()};$reload.Revision='p1-returned'
Accept-DaemonReload $reload;Start-TransportEngine
Assert ($revision -eq 'p1-returned' -and -not (Test-DaemonFault 'p1') -and (Get-DaemonSelectorTarget 'p1') -eq 'p1' -and $transportFaults.Count -eq 31) 're-added candidate resurrected stale fault'
Invoke-DaemonFaultCommand @{fault='drop';tag='p32'}
Assert ($transportFaults.Count -eq 32 -and (Test-DaemonFault 'p32')) 'removed injection did not release bounded-map capacity'
'T3 fault injection PASS'

'T2/T3 daemon episode PASS ('+$count+' assertions)'
