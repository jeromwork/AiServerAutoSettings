#requires -Version 5.1
# T2: daemon functions, fake clock and manually delivered results; no network/process/VPN or waiting.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
. (Join-Path $PSScriptRoot 'Transport.Decide.ps1')
. (Join-Path $PSScriptRoot 'Transport.Quality.ps1')
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Transport.Daemon.ps1'),[ref]$null,[ref]$errors)
if($errors){throw ($errors|Out-String)}
foreach($fn in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
    . ([scriptblock]::Create($fn.Extent.Text))
}
$script:testEngineApiReady=${function:Test-TransportEngineApiReady}
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
function Set-TransportSelector($Options,$Secret,$Tag){$script:selectorCalls+=,$Tag}
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
function New-TransportConfig { @{outbounds=@(@{tag='active';default=$active})} }
function Test-TransportConfigFile {}
function Set-TransportProcessPriority {$true}
function Save-TransportOwner {}
function Start-TransportProcess {
    $script:engineStarts++
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
    return ($script:apiChecks -gt $script:apiFalseChecks)
}
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
    $script:startFailures=0;$script:EngineReadyFailureLimit=2;$script:engineAttempted=$false
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
# Actual asynchronous API observer: pending/auth failure is never readiness.
# Completed responses are consumed only after IsCompleted and all resources released.
Add-Type -AssemblyName System.Net.Http
foreach($status in @(401,204)){
    $completion=New-Object 'Threading.Tasks.TaskCompletionSource[Net.Http.HttpResponseMessage]'
    $client=[pscustomobject]@{disposed=$false};$client|Add-Member ScriptMethod Dispose {$this.disposed=$true}
    $content=[pscustomobject]@{disposed=$false};$content|Add-Member ScriptMethod Dispose {$this.disposed=$true}
    $script:engineApiCheck=@{client=$client;content=$content;task=$completion.Task}
    Assert (-not (& $script:testEngineApiReady) -and $engineApiCheck -and -not $client.disposed) 'pending API request was awaited or accepted'
    $response=New-Object Net.Http.HttpResponseMessage([Net.HttpStatusCode]$status)
    $completion.SetResult($response)
    $ready=& $script:testEngineApiReady
    Assert ($ready -eq ($status -eq 204) -and -not $engineApiCheck -and $client.disposed -and $content.disposed) 'API authentication result/cleanup lost'
}
# Cancellation of an in-flight request does not read its unfinished Result.
$completion=New-Object 'Threading.Tasks.TaskCompletionSource[Net.Http.HttpResponseMessage]'
$script:engineApiCheck=@{client=$client;content=$content;task=$completion.Task}
Stop-DaemonEngineApiCheck
Assert (-not $engineApiCheck) 'engine stop retained pending API request'
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
Assert ($firstEngine.stopped -and -not $engine -and $engineWait.expired -and $startFailures -eq 1) 'fuse did not stop hung engine/count failure'
Assert ($decision.episode.status -eq 'closed' -and -not $confirmed -and -not $busEngineReady -and $errorText -match 'engine-ready-timeout') 'readiness timeout announced success or left episode open'
Assert (@($logged|Where-Object {$_.name -eq 'restart' -and $_.fields.why -eq 'engine-ready-timeout'}).Count -eq 1) 'timeout restart reason not logged exactly once'
Engine-Step
Assert ($engineStarts -eq 1) 'timeout bypassed existing restart backoff'
$script:clockMs+=3000;Engine-Step
Assert ($engineStarts -eq 2 -and $initialWaits -eq 2 -and $startFailures -eq 1 -and -not $engineWait.expired) 'real restart reset failures before readiness or failed to rearm fuse'
$script:clockMs=$engineWait.at+$EngineReadyFuseMs;Engine-Step
Assert (-not $engine -and $startFailures -eq $EngineReadyFailureLimit -and -not $confirmed -and -not $checkingSince) 'restart exhaustion did not leave failed status'
for($i=0;$i -lt 5;$i++){$script:clockMs+=30000;Engine-Step;Invoke-DaemonDecision}
Assert ($engineStarts -eq 2 -and $engineStops -eq 2 -and -not $confirmed -and $decision.episode.status -eq 'closed') 'readiness failure caused an endless restart/success loop'
Assert (@($logged|Where-Object {$_.name -eq 'ready'}).Count -eq 0) 'unready process was logged ready'
# A retry that really becomes ready resets the existing failure counter.
Fixture;Open-Episode;$script:apiFalseChecks=1
Start-TransportEngine
$script:clockMs=$engineWait.at+$EngineReadyFuseMs;Engine-Step
$script:clockMs+=3000;Engine-Step;Engine-Step
Assert ($busEngineReady -and -not $engineWait -and $startFailures -eq 0 -and -not $confirmed) 'authenticated readiness did not reset failures without claiming path success'
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
$script:active='p1';$decision.currentTag='p1';$decision.episode.open=$false;$decision.episode.status='verifying';$decision.episode.verifyAt=3100
$script:busEngineReady=$false;Start-DaemonVerification 'p1'
Assert (-not $q.verified -and @($started|Where-Object {$_.verify}).Count -eq 0) 'unready verification consumed Q or started I/O'
$script:clockMs=6000;$script:engineApiTarget='p1'
Engine-Step
Assert ($pathChecks.p1.purpose -eq 'post-switch-verify' -and $pathChecks.p1.generation -eq $checkGeneration -and $decision.episode.verifyAt -eq 6000) 'engine-ready did not resume deferred verification'
$script:clockMs=6100;Deliver 'p1' 'ok';Invoke-DaemonDecision
Assert ($confirmed -and $decision.episode.status -eq 'closed') 'resumed verification did not close on its real result'
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
. (Join-Path $PSScriptRoot 'Transport.Events.ps1')
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
'T2 daemon episode PASS ('+$count+' assertions)'
