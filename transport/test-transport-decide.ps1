#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Transport.Decide.ps1')
$count=0
function Assert($Condition,[string]$Message) {
    if(-not $Condition){throw ('Тест решателя: '+$Message)}
    $script:count++
}
function Row([string]$Tag,[string]$Health='ok',[double]$Latency=100,[int]$Failures=0,[double]$Gap=0) {
    return @{tag=$Tag;state=$Health;enabled=$true;latencyMs=$Latency;failures=$Failures;maxGapMs=$Gap}
}
function Event([long]$At,[string]$Kind,[string]$Tag='a',[string]$Code='timeout',[bool]$Local=$false) {
    return @{at=$At;kind=$Kind;tag=$Tag;code=$Code;local=$Local;detail='must-never-escape password=TOP_SECRET host=private.example'}
}
function Decide($State,[long]$Now,$Events=@(),$Rows=@((Row 'a'),(Row 'b' 'remembered' 120)),[string]$Current='a',[switch]$Improve) {
    return Invoke-TransportDecision -State $State -Candidates $Rows -Now $Now -Events $Events -CurrentTag $Current -AllowImprovement:$Improve
}
function Json($Value){return ConvertTo-Json -InputObject $Value -Depth 30 -Compress}

# Failure is only a suspicion until direct connectivity is independently confirmed.
$s=New-TransportDecisionState 0 'a';$rows=@((Row 'a'),(Row 'b' 'remembered' 120))
$events=@((Event 1000 'dial-fail'));$before=Json @($s,$rows,$events)
$r=Decide $s 1000 $events $rows
Assert ($r.verdict.action -eq 'check-direct' -and $r.verdict.tag -eq 'a') 'dial failure requests direct connectivity'
Assert ($r.verdict.reason.code -eq 'path-dial-failed' -and $r.verdict.localNet -eq 'unknown') 'suspect reason and unknown local network'
Assert ($r.verdict.penalties.a.step -eq 0) 'unconfirmed failure is not penalized'
Assert ((Json @($s,$rows,$events)) -ceq $before) 'all inputs remain unchanged'
Assert ((Json $r) -ceq (Json (Decide $s 1000 $events $rows))) 'same inputs give same result'
$r=Decide $r.state 1100 @((Event 1010 'dial-fail'),(Event 1090 'conn-closed-error'))
Assert ($r.verdict.action -eq 'none' -and $r.state.pending.Count -eq 1) 'burst while check runs coalesces'
$r=Decide $r.state 2000 @((Event 2000 'net-up' ''))
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.tag -eq 'b') 'confirmed current failure immediately selects remembered alternative'
Assert ($r.verdict.penalties.a.step -eq 1 -and $r.verdict.penalties.a.until -eq 7000) 'first confirmed failure pauses for five seconds'
Assert ($r.state.paths.a.failures -eq 1 -and $r.state.consecutiveFailures -eq 1) 'burst produces exactly one confirmed failure'
Assert ($null -eq $r.state.lastSwitchAt -and $r.state.switches.Count -eq 0) 'proposal is not a successful selector change'
$r=Decide $r.state 2050
Assert ($r.verdict.action -eq 'switch') 'failed selector request can be retried without consuming rate limit'
$r=Decide $r.state 2100 @() $rows 'b'
Assert ($r.verdict.action -eq 'none' -and $r.state.lastSwitchAt -eq 2100) 'actual selector change starts stay and rate limits'
Assert ($r.state.switches.Count -eq 1 -and $r.state.switches[0].from -eq 'a' -and $r.state.switches[0].to -eq 'b' -and $r.state.switches[0].why -eq 'path-dial-failed') 'acknowledged history records failure reason'
$r=Decide $r.state 2700 @((Event 2700 'engine-exit' 'b')) $rows 'b'
Assert ($r.verdict.action -eq 'searching' -and $r.verdict.reason.code -eq 'all-paths-penalized') 'all paths paused means searching'
$r=Decide $r.state 8000 @() $rows 'b'
Assert ($r.verdict.action -eq 'searching' -and $r.verdict.notes -contains 'switch-rate-limited') 'new failure bypasses minStay but cannot violate ten seconds'
$r=Decide $r.state 12100 @() $rows 'b'
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.tag -eq 'a') 'deferred failover releases at the ten second boundary'

# Penalty ladder, expiry and successful probe/dial recovery.
$s=New-TransportDecisionState 0 'a';$single=@((Row 'a'));$now=1000
$delays=@(5000,15000,45000,120000,300000,300000)
for($i=0;$i -lt $delays.Count;$i++){
    $r=Decide $s $now @((Event $now 'engine-exit')) $single
    Assert ($r.verdict.penalties.a.step -eq [Math]::Min(5,$i+1) -and $r.verdict.penalties.a.until -eq ($now+$delays[$i])) ('penalty ladder step '+$i)
    Assert ($r.verdict.action -eq 'searching') 'single paused path never disables VPN'
    $s=$r.state;$now=$r.verdict.penalties.a.until
}
$r=Decide $s $s.now @((Event $s.now 'engine-exit')) $single
Assert ($r.verdict.penalties.a.step -eq 5 -and $r.verdict.penalties.a.until -eq $s.paths.a.until) 'duplicate process exit cannot extend current penalty'
$r=Decide $s $now @() $single
Assert ($r.verdict.action -eq 'check-path' -and $r.verdict.tag -eq 'a') 'expiry retries the only current path once'
$r=Decide $r.state ($now+1) @() $single
Assert ($r.verdict.action -eq 'none') 'expiry does not start periodic probes'
$r=Decide $r.state ($now+2) @((Event ($now+2) 'path-check' 'a' 'ok')) $single
Assert ($r.verdict.penalties.a.step -eq 0 -and $null -eq $r.verdict.penalties.a.until -and $r.state.paths.a.failures -eq 0) 'success resets the entire failure streak'
Assert ($r.verdict.localNet -eq 'ok' -and $r.verdict.reason.code -eq 'ok') 'path success proves working local connectivity'
$s=$r.state
$r=Decide $s ($now+1000) @((Event ($now+1000) 'dial-fail' 'a' 'cancelled')) $single
Assert ($r.verdict.action -eq 'none' -and $r.state.pending.Count -eq 0 -and $r.verdict.penalties.a.step -eq 0) 'cancellation is not a failure'
$r=Decide $s ($now+1000) @((Event ($now+1000) 'path-check' 'a' 'refused')) $single
Assert ($r.verdict.action -eq 'check-direct' -and $r.verdict.penalties.a.step -eq 0) 'refused path probe also needs direct confirmation'

# Local indications immediately roll back and freeze all path punishment and movement.
foreach($kind in @('dial-fail','conn-closed-error','net-down')){
    $r=Decide (New-TransportDecisionState 0 'a') 1000 @((Event 1000 'engine-exit'))
    $r=Decide $r.state 2000 @((Event 2000 $kind 'a' '10051' $true))
    Assert ($r.verdict.action -eq 'rollback-penalties' -and $r.verdict.localNet -eq 'down' -and $r.verdict.penalties.a.step -eq 0) ($kind+' rolls back recent penalty')
    Assert ($r.verdict.reason.code -eq 'local-network-down' -and $r.verdict.reason.text -ceq 'Нет интернета у вас (сеть), жду') 'shared Russian local network reason'
    $r=Decide $r.state 5000 @((Event 5000 'dial-fail'),(Event 5000 'engine-exit' 'b'))
    Assert ($r.verdict.action -eq 'searching' -and $r.verdict.penalties.a.step -eq 0 -and $r.verdict.penalties.b.step -eq 0 -and $r.state.pending.Count -eq 0) 'no path checks, switches or penalties while down'
    Assert ($r.verdict.reason.since -eq 2000) 'reason since remains stable while waiting'
    $r=Decide $r.state 6000 @((Event 6000 'net-up' ''))
    Assert ($r.verdict.action -eq 'none' -and $r.verdict.localNet -eq 'ok') 'net-up resumes without fabricated path failure'
}
$r=Decide (New-TransportDecisionState 0 'a') 1000 @((Event 1000 'dial-fail'))
$r=Decide $r.state 2000 @((Event 2000 'net-down' ''))
Assert ($r.verdict.action -eq 'rollback-penalties' -and $r.state.pending.Count -eq 0 -and $r.verdict.penalties.a.step -eq 0) 'failed direct check never convicts a path'
$r=Decide $r.state 2100 @((Event 1500 'net-up' ''),(Event 1500 'path-check' 'a' 'ok'))
Assert ($r.verdict.localNet -eq 'down') 'late old successes cannot resurrect a down network'
$r=Decide $r.state 2200 @((Event 2200 'path-check' 'a' 'ok'))
Assert ($r.verdict.localNet -eq 'ok') 'new successful path probe proves recovery'

# Rollback includes a long unfinished round, but preserves older unrelated penalties.
$r=Decide (New-TransportDecisionState 0 'a') 1000 @((Event 1000 'engine-exit'))
$r=Decide $r.state 70000 @((Event 70000 'net-down' ''))
Assert ($r.verdict.penalties.a.step -eq 0 -and $r.state.paths.a.failures -eq 0) 'unfinished round older than 45 seconds is fully rolled back'
$r=Decide (New-TransportDecisionState 0 'a') 1000 @((Event 1000 'engine-exit'))
$r=Decide $r.state 2000 @((Event 2000 'path-check' 'b' 'ok'))
$r=Decide $r.state 60000 @((Event 60000 'engine-exit'))
Assert ($r.verdict.penalties.a.step -eq 2) 'old penalty streak survives time without success on that path'
$r=Decide $r.state 61000 @((Event 61000 'net-down' ''))
Assert ($r.verdict.penalties.a.step -eq 1 -and $r.verdict.penalties.a.until -eq 6000 -and $r.state.paths.a.failures -eq 1) 'rollback restores previous older step and failure count exactly'
$r=Decide (New-TransportDecisionState 0 'a') 1000 @((Event 1000 'engine-exit'))
$r=Decide $r.state 1100 @((Event 1100 'path-check' 'a' 'ok'))
$r=Decide $r.state 2000 @((Event 2000 'net-down' ''))
Assert ($r.verdict.penalties.a.step -eq 0) 'rollback never resurrects penalties cleared by success'
$four=@((Row 'a'),(Row 'b'),(Row 'c'),(Row 'd'),(Row 'e'))
$r=Decide (New-TransportDecisionState 0 'a') 1000 @((Event 1000 'engine-exit' 'a'),(Event 1000 'engine-exit' 'b'),(Event 1000 'engine-exit' 'c'),(Event 1000 'engine-exit' 'd')) $four
Assert ($r.state.consecutiveFailures -eq 4 -and $r.verdict.localNet -ne 'down') 'four failures alone cannot declare local outage'
$r=Decide $r.state 2000 @((Event 2000 'net-down' '')) $four
Assert ($r.verdict.localNet -eq 'down' -and $r.state.consecutiveFailures -eq 0 -and $r.verdict.penalties.a.step -eq 0 -and $r.verdict.penalties.d.step -eq 0) 'four-failure no-success round is discarded when direct connectivity fails'

# Stall requires a single 64 KiB check; only a confirmed failure can proceed to direct check.
$r=Decide (New-TransportDecisionState 0 'a') 1000 @((Event 1000 'stall-suspect'))
Assert ($r.verdict.action -eq 'check-path' -and $r.verdict.penalties.a.step -eq 0) 'stall suspicion requests confirmation without penalty'
$r=Decide $r.state 2000 @((Event 2000 'stall-suspect'))
Assert ($r.verdict.action -eq 'none') 'duplicate stall does not launch another confirmation'
$r=Decide $r.state 3000 @((Event 3000 'path-check' 'a' 'ok'))
Assert ($r.verdict.action -eq 'none' -and $r.verdict.penalties.a.step -eq 0) 'confirmed throughput disproves stall'
$s=$r.state
$r=Decide $s 62999 @((Event 62999 'stall-suspect'))
Assert ($r.verdict.action -eq 'none') 'successful stall check suppresses suspicion for sixty seconds'
$r=Decide $r.state 63000 @((Event 63000 'stall-suspect'))
Assert ($r.verdict.action -eq 'check-path') 'sixty-second suppression boundary releases new suspicion'
foreach($code in @('stalled','timeout')){
    $r=Decide $s 63000 @((Event 63000 'stall-suspect'))
    $r=Decide $r.state 64000 @((Event 64000 'path-check' 'a' $code))
    Assert ($r.verdict.action -eq 'check-direct' -and $r.verdict.reason.code -eq 'path-stalled' -and $r.verdict.penalties.a.step -eq 0) ($code+' confirmation first checks local network')
    $r=Decide $r.state 65000 @((Event 65000 'net-up' ''))
    Assert ($r.verdict.action -eq 'switch' -and $r.verdict.reason.code -eq 'path-stalled' -and $r.verdict.penalties.a.step -eq 1) 'confirmed stall with working direct network switches and penalizes once'
}
$r=Decide (New-TransportDecisionState 0 'a') 1000 @((Event 1000 'stall-suspect'))
$r=Decide $r.state 2000 @((Event 2000 'path-check' 'a' 'cancelled'))
Assert ($r.verdict.action -eq 'none' -and $r.state.pending.Count -eq 0) 'cancelled stall check clears request without punishment'
$r=Decide (New-TransportDecisionState 0 'a') 1000 @((Event 1000 'dial-fail'))
$r=Decide $r.state 1200 @((Event 1200 'engine-exit'))
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.reason.code -eq 'path-process-exited') 'dead process overrides an unconfirmed network suspicion'
$r=Decide (New-TransportDecisionState 0 'a') 1000 @((Event 1000 'engine-exit' ''))
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.penalties.a.step -eq 1) 'whole engine exit with empty tag fails the current path'
$r=Decide (New-TransportDecisionState 0 'a') 1000 @((Event 1000 'engine-exit'),(Event 1000 'stall-suspect' 'b')) @((Row 'a'),(Row 'b'),(Row 'c'))
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.tag -eq 'c') 'current confirmed failure does not wait for unrelated suspect candidate'
$r=Decide (New-TransportDecisionState 0 'a') 2000 @((Event 1000 'net-down' ''),(Event 1500 'net-up' ''))
Assert ($r.verdict.localNet -eq 'ok' -and $r.verdict.action -eq 'none') 'ordered recovery in a delayed event batch is respected'
$r=Decide (New-TransportDecisionState 0 'a') 1000 @((Event 1000 'conn-closed-error'))
$r=Decide $r.state 2000 @((Event 2000 'net-up' ''))
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.penalties.a.step -eq 1) 'nonlocal connection closure follows direct-confirmed failover'

# Fixed debounce window, duplicate results and no background work during idle ticks.
$r=Decide (New-TransportDecisionState 0 'a') 1000 @((Event 1000 'dial-fail'))
$r=Decide $r.state 1100 @((Event 1100 'path-check' 'a' 'ok'))
$r=Decide $r.state 1499 @((Event 1499 'conn-closed-error'))
Assert ($r.verdict.action -eq 'none') 'failure kind changes still share a 500ms window'
$r=Decide $r.state 1500 @((Event 1500 'dial-fail'))
Assert ($r.verdict.action -eq 'check-direct') 'debounce is fixed to first event, not sliding'
$r=Decide (New-TransportDecisionState 0 'a') 1000 @((Event 1000 'path-check' 'a' 'process-exited'))
$r=Decide $r.state 1000 @((Event 1000 'path-check' 'a' 'process-exited'))
Assert ($r.verdict.penalties.a.step -eq 1) 'replayed probe result is applied exactly once'
$r=Decide (New-TransportDecisionState 0 'a') 1000 @((Event 1000 'dial-fail'))
$r=Decide $r.state 2000 @((Event 2000 'path-check' 'a' 'ok'))
$r=Decide $r.state 3000 @((Event 3000 'net-up' ''))
Assert ($r.verdict.penalties.a.step -eq 0 -and $r.verdict.action -eq 'none') 'late direct success cannot convict a path already proven good'
$r=Decide (New-TransportDecisionState 0 'a') 1000 @((Event 1000 'dial-fail'))
$r=Decide $r.state 2000 @() @((Row 'b')) 'b'
Assert ($r.state.pending.Count -eq 0 -and $null -eq $r.state.directRequestedAt) 'removed candidates cannot keep orphan checks alive'
$s=New-TransportDecisionState 0 'a'
foreach($tick in @(0,500,1000,30000,1000000)){
    $r=Decide $s $tick;$s=$r.state
    Assert ($r.verdict.action -eq 'none') 'time passing on a healthy path starts no probes'
}

# Candidate ordering: health, latency, failures, dispersion, deterministic tie-break.
$cases=@(
    @{rows=@((Row 'unknown' 'unknown' 1),(Row 'remember' 'remembered' 2),(Row 'healthy' 'ok' 999));best='healthy'},
    @{rows=@((Row 'a' 'ok' 101),(Row 'b' 'ok' 100));best='b'},
    @{rows=@((Row 'a' 'ok' 100 2),(Row 'b' 'ok' 100 1));best='b'},
    @{rows=@((Row 'a' 'ok' 100 1 11),(Row 'b' 'ok' 100 1 10));best='b'},
    @{rows=@((Row 'b'),(Row 'a'));best='a'}
)
foreach($case in $cases){
    $r=Decide (New-TransportDecisionState 0 '') 1000 @() $case.rows ''
    Assert ($r.verdict.action -eq 'switch' -and $r.verdict.tag -eq $case.best) ('candidate order chooses '+$case.best)
}
$disabled=Row 'disabled' 'ok' 1;$disabled.enabled=$false
$broken=Row 'broken' 'ok' 1;$broken.buildFailed=$true
$noLatency=Row 'unmeasured';$noLatency.latencyMs=$null
$r=Decide (New-TransportDecisionState 0 '') 1000 @() @($disabled,$broken,$noLatency,(Row 'measured')) ''
Assert ($r.verdict.tag -eq 'measured') 'disabled/build-failed candidates excluded and missing latency sorts last'
$r=Decide (New-TransportDecisionState 0 '') 1000 @() @() ''
Assert ($r.verdict.action -eq 'searching' -and $r.verdict.reason.code -eq 'no-candidates') 'no candidates has its own reason'
$r=Decide (New-TransportDecisionState 0 'a') 1000 @((Event 1000 'engine-exit')) @((Row 'a' 'ok' 1),(Row 'b' 'unknown' 9999))
Assert ($r.verdict.tag -eq 'b') 'confirmed failure switches immediately even to a slower unknown candidate'

# Planned improvement uses existing measurements, strict max(30ms,20%) and minStay.
foreach($case in @(@{cur=100;best=70;move=$false},@{cur=100;best=69;move=$true},@{cur=400;best=320;move=$false},@{cur=400;best=319;move=$true})){
    $pair=@((Row 'a' 'ok' $case.cur),(Row 'b' 'ok' $case.best))
    $s=New-TransportDecisionState 0 'a'
    $r=Decide $s 29999 @() $pair 'a' -Improve
    Assert ($r.verdict.action -eq 'none') 'minStay holds a healthy path for thirty seconds'
    $r=Decide $s 30000 @() $pair 'a' -Improve
    Assert (($r.verdict.action -eq 'switch') -eq $case.move) 'strict absolute and relative improvement threshold'
    $r=Decide $s 90000 @() $pair 'a'
    Assert ($r.verdict.action -eq 'none') 'healthy current path stays unless improvement is explicitly enabled'
}
$r=Decide (New-TransportDecisionState 0 'a') 90000 @() @((Row 'a' 'ok' 400),(Row 'b' 'remembered' 1)) 'a' -Improve
Assert ($r.verdict.action -eq 'none') 'remembered candidate cannot displace a healthy current path by latency alone'

# JSON round-tripping, stable reason table, safe output and bounded switch history.
$r=Decide (New-TransportDecisionState 0 'a') 1000 @((Event 1000 'dial-fail'))
$jsonState=(Json $r.state)|ConvertFrom-Json
$jsonRows=(Json @((Row 'a'),(Row 'b' 'remembered' 120)))|ConvertFrom-Json
$jsonEvents=(Json @((Event 2000 'net-up' '')))|ConvertFrom-Json
$r=Decide $jsonState 2000 $jsonEvents $jsonRows
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.penalties.a.step -eq 1) 'JSON-derived state, candidates and events are accepted'
Assert ((Json $r) -notmatch 'TOP_SECRET|private\.example|password=') 'raw event details never enter state, verdict or notes'
$s=New-TransportDecisionState 0 'a'
for($i=1;$i -le 12;$i++){
    $tag='b';if(($i%2) -eq 0){$tag='a'}
    $r=Decide $s ($i*10000) @() $rows $tag;$s=$r.state
}
Assert ($s.switches.Count -eq 10 -and $s.switches[0].at -eq 30000 -and $s.switches[9].at -eq 120000) 'history contains only the last ten acknowledged switches'
foreach($code in @('path-dial-failed','path-stalled','path-process-exited','local-network-down','no-candidates','all-paths-penalized','ok')){
    Assert (-not [string]::IsNullOrEmpty((Get-TransportDecisionReasonText $code))) ('reason text exists: '+$code)
}
$rejected=$false;try{Decide $s 0|Out-Null}catch{$rejected=$true}
Assert $rejected 'backwards decision clock is rejected'
$r=Decide (New-TransportDecisionState 0 'a') 1000 @((Event 2000 'dial-fail'),(Event 1000 'unknown-kind'),(Event 1000 'dial-fail' 'not-a-candidate'))
Assert ($r.verdict.action -eq 'none' -and $r.state.pending.Count -eq 0) 'future, unknown and unrelated events cannot change selection'
Write-Host ('PASS: transport decision reducer, '+$count+' assertions; no network/process/VPN operations')
