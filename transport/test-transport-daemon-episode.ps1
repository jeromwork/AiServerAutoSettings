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
function Fixture([int]$Candidates=3){
    $script:clockMs=100;$script:root='/unused';$script:network=@{id='test-net';available=$true}
    $script:settings=@{Transport=@{};Profile=@{};Options=@{switchStallSeconds=8;switchStallConns=2}}
    $script:paths=@{Candidates=@();Tunnels=@();Outbounds=@()};$script:rows=@()
    for($i=0;$i -lt $Candidates;$i++){
        $tag='p'+$i
        $script:paths.Candidates+=@{tag=$tag;port=(10000+$i);title=$tag}
        $script:rows+=@{tag=$tag;state='remembered';enabled=$true;latencyMs=(100+$i*10);kbps=$null;checkedAt=$null;lastOkAt=$null;lastFailAt=$null}
    }
    $script:active='p0';$script:pin=@{mode='auto';tag=$null};$script:memory=@{networks=@{}}
    $script:engine=@{Process=@{HasExited=$false}};$script:secret=''
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
