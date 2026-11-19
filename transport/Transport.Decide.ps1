#requires -Version 5.1
<#
Pure event reducer; dot-source independently of Transport.Common.ps1.

$state = New-TransportDecisionState -Now $unixMs -CurrentTag $active
$result = Invoke-TransportDecision -State $state -Candidates $rows -Now $unixMs `
    -CurrentTag $active -Events $events
$state = $result.state
# Execute $result.verdict in the daemon, never in this file.

CurrentTag is the ACTUAL selector value. A switch verdict is a proposal; acknowledge
it on the next call with CurrentTag only after selector PUT succeeds. The 10-second
limit and 30-second minStay start at acknowledgement. Keep calling with empty Events
to release a deferred switch / expired penalty; this never schedules periodic probes.
AllowImprovement permits comparison of already available metrics, without any I/O.

All times (including reason.since and penalties.until) are Unix milliseconds; null
means no deadline. C converts deadlines to ISO for status/transport.json. Events,
state and candidates may be hashtables or JSON-derived PSCustomObjects. Inputs are
not mutated. Keep the returned state even for action=none. notes contain only fixed
codes, never event detail, endpoints or exception text. No VPN stop action exists.

path-check/ok also represents a successful dial (the event contract has no dial-ok).
engine-exit (empty tag means CurrentTag) / path-check process-exited prove a dead process without a network check;
all network-like failures, including refused, require a fresh check-direct result.
check-path always requests the contract's 64 KiB confirmation/recovery probe.
#>

function Get-TransportDecisionValue($Object,[string]$Name,$Default=$null) {
    if($null -eq $Object){return $Default}
    if($Object -is [Collections.IDictionary]){
        if($Object.Contains($Name)){return $Object[$Name]}
    }elseif($Object.PSObject.Properties[$Name]){return $Object.$Name}
    return $Default
}

function Copy-TransportDecisionValue($Value) {
    if($null -eq $Value){return $null}
    if($Value -is [Collections.IDictionary]){
        $copy=@{};foreach($key in $Value.Keys){$copy[$key]=Copy-TransportDecisionValue $Value[$key]};return $copy
    }
    if($Value -is [System.Management.Automation.PSCustomObject]){
        $copy=@{};foreach($p in $Value.PSObject.Properties){$copy[$p.Name]=Copy-TransportDecisionValue $p.Value};return $copy
    }
    if($Value -is [array]){return ,@($Value|ForEach-Object {Copy-TransportDecisionValue $_})}
    return $Value
}

function Get-TransportDecisionReasonText([string]$Code) {
    $texts=@{
        'path-dial-failed'='Путь не отвечает, пробую другой'
        'path-stalled'='Путь завис, пробую другой'
        'path-process-exited'='Сбой канала, перезапускаю'
        'local-network-down'='Нет интернета у вас (сеть), жду'
        'no-candidates'='Нет подходящих путей'
        'all-paths-penalized'='Все пути временно недоступны, повторяю'
        'ok'='Связь работает'
    }
    return $texts[$Code]
}

function New-TransportDecisionState([long]$Now,[string]$CurrentTag='') {
    return @{
        now=$Now;currentTag=$CurrentTag;selectedAt=$Now;lastSwitchAt=$null
        localNet='unknown';localNetAt=$null;paths=@{};pending=@{}
        directRequestedAt=$null;history=@();roundSince=$null;consecutiveFailures=0
        switches=@();proposal=$null;reason=@{code='ok';text=(Get-TransportDecisionReasonText 'ok');since=$Now}
    }
}

function New-TransportDecisionPath {
    return @{step=0;until=$null;failures=0;failed=$false;reason='ok';lastFailureAt=$null;lastResultAt=$null;lastCheckAt=$null;lastSignalAt=$null;stallIgnoreUntil=$null}
}

# Helpers below mutate only the private deep copy owned by Invoke-TransportDecision.
function Set-TransportDecisionReason($State,[string]$Code,[long]$Now) {
    if($State.reason.code -ne $Code){
        $State.reason=@{code=$Code;text=(Get-TransportDecisionReasonText $Code);since=$Now}
    }
}

function Add-TransportDecisionPenalty($State,[string]$Tag,[string]$Reason,[long]$Now,[long]$At) {
    $p=$State.paths[$Tag]
    $State.history+=@(@{at=$Now;tag=$Tag;before=(Copy-TransportDecisionValue $p)})
    $p.step=[Math]::Min(5,([int]$p.step+1))
    $p.until=$Now+@(5000,15000,45000,120000,300000)[$p.step-1]
    $p.failures++;$p.failed=$true;$p.reason=$Reason;$p.lastFailureAt=$Now;$p.lastResultAt=$At
    $State.consecutiveFailures++
    [void]$State.pending.Remove($Tag)
}

function Reset-TransportDecisionPath($State,[string]$Tag,[long]$At) {
    $p=$State.paths[$Tag]
    $p.step=0;$p.until=$null;$p.failures=0;$p.failed=$false;$p.reason='ok';$p.lastResultAt=$At
    $State.history=@($State.history|Where-Object {$_.tag -ne $Tag})
    [void]$State.pending.Remove($Tag)
    $State.consecutiveFailures=0;$State.roundSince=$null
    $State.localNet='ok';$State.localNetAt=$At
}

function Undo-TransportDecisionPenalties($State,[long]$Now) {
    $since=$Now-45000
    if($null -ne $State.roundSince){$since=[Math]::Min($since,[long]$State.roundSince)}
    # Reverse snapshots restore older penalties rather than destroying their history.
    for($i=$State.history.Count-1;$i -ge 0;$i--){
        $entry=$State.history[$i]
        if($entry.at -ge $since){$State.paths[$entry.tag]=Copy-TransportDecisionValue $entry.before}
    }
    $State.history=@($State.history|Where-Object {$_.at -lt $since})
    $State.pending=@{};$State.directRequestedAt=$null;$State.proposal=$null
    $State.roundSince=$null;$State.consecutiveFailures=0
    $State.localNet='down';$State.localNetAt=$Now
}

function Get-TransportDecisionHealth($Candidate,$Path) {
    if($Path.failed){return 2}
    switch ([string](Get-TransportDecisionValue $Candidate 'state' 'unknown')) {
        'ok' {return 0};'remembered' {return 1};default {return 2}
    }
}

function Get-TransportDecisionMetric($Candidate,[string]$Name) {
    $value=Get-TransportDecisionValue $Candidate $Name
    if($null -eq $value){return [double]::MaxValue}
    return [double]$value
}

function Invoke-TransportDecision {
    [CmdletBinding()]
    param($State,$Candidates,[long]$Now,[string]$CurrentTag='', $Events=@(),[switch]$AllowImprovement)
    if($null -eq $State){$State=New-TransportDecisionState $Now $CurrentTag}
    $s=Copy-TransportDecisionValue $State
    if($Now -lt $s.now){throw 'Decision time must not move backwards'}
    $s.now=$Now;$notes=@();$action='none';$target='';$rolledBack=$false
    $rows=@($Candidates|Where-Object {
        $tag=[string](Get-TransportDecisionValue $_ 'tag' '')
        $tag -match '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,95}$' -and $tag -ne 'unavailable' -and
        (Get-TransportDecisionValue $_ 'enabled' $true) -ne $false -and
        -not (Get-TransportDecisionValue $_ 'buildFailed' $false) -and
        (Get-TransportDecisionValue $_ 'state' '') -ne 'disabled'
    })
    foreach($row in $rows){if(-not $s.paths.ContainsKey([string]$row.tag)){$s.paths[[string]$row.tag]=New-TransportDecisionPath}}
    $tags=@($rows|ForEach-Object {[string]$_.tag})
    foreach($key in @($s.pending.Keys)){if($key -notin $tags){[void]$s.pending.Remove($key)}}
    if($CurrentTag -ne $s.currentTag){
        $why='ok'
        if($s.proposal -and $s.proposal.tag -eq $CurrentTag){$why=$s.proposal.reason}
        $s.switches=@(@($s.switches)+@(@{at=$Now;from=$s.currentTag;to=$CurrentTag;why=$why})|Select-Object -Last 10)
        $s.currentTag=$CurrentTag;$s.selectedAt=$Now;$s.lastSwitchAt=$Now;$s.proposal=$null
        # Selecting an expired, previously failed path starts a new attempt, not a success.
        if($s.paths.ContainsKey($CurrentTag)){$s.paths[$CurrentTag].failed=$false}
    }

    foreach($event in @($Events|Sort-Object {[long](Get-TransportDecisionValue $_ 'at' $Now)})){
        $at=[long](Get-TransportDecisionValue $event 'at' $Now)
        if($at -gt $Now){continue}
        $kind=[string](Get-TransportDecisionValue $event 'kind' '')
        $tag=[string](Get-TransportDecisionValue $event 'tag' '')
        $code=[string](Get-TransportDecisionValue $event 'code' '')
        if($code -in @('cancelled','canceled','operation-canceled','operation-cancelled','context-canceled','aborted')){
            if($kind -eq 'path-check' -and $s.pending.ContainsKey($tag) -and $at -ge $s.pending[$tag].at){[void]$s.pending.Remove($tag)}
            continue
        }
        $local=(Get-TransportDecisionValue $event 'local' $false) -eq $true
        if($kind -eq 'net-down' -or ($local -and $kind -in @('dial-fail','conn-closed-error'))){
            if($null -ne $s.localNetAt -and $at -lt $s.localNetAt){continue}
            Undo-TransportDecisionPenalties $s $Now;$s.localNetAt=$at;$rolledBack=$true
            continue
        }
        if($kind -eq 'net-up'){
            if($null -ne $s.localNetAt -and $at -lt $s.localNetAt){continue}
            $s.localNet='ok';$s.localNetAt=$at
            if($null -ne $s.directRequestedAt -and $at -ge $s.directRequestedAt){
                foreach($pendingTag in @($s.pending.Keys)){
                    $pending=$s.pending[$pendingTag]
                    if($pending.stage -eq 'direct' -and $at -ge $pending.at){
                        Add-TransportDecisionPenalty $s $pendingTag $pending.reason $Now $at
                    }
                }
                $s.directRequestedAt=$null
            }
            continue
        }
        if($kind -eq 'engine-exit' -and -not $tag){$tag=$CurrentTag}
        if(-not $s.paths.ContainsKey($tag) -or $tag -notin $tags){continue}
        $p=$s.paths[$tag]
        if($null -ne $p.lastResultAt -and $at -lt $p.lastResultAt){continue}
        if($kind -eq 'path-check'){
            if($s.localNet -eq 'down' -and $null -ne $s.localNetAt -and $at -lt $s.localNetAt){continue}
            if($null -ne $p.lastCheckAt -and $at -le $p.lastCheckAt){continue}
            if($code -notin @('ok','timeout','stalled','refused','process-exited')){continue}
            $p.lastCheckAt=$at
        }
        if($kind -eq 'path-check' -and $code -eq 'ok'){
            $wasStall=$s.pending.ContainsKey($tag) -and $s.pending[$tag].reason -eq 'path-stalled'
            Reset-TransportDecisionPath $s $tag $at
            if($wasStall){$p.stallIgnoreUntil=$Now+60000}
            continue
        }
        if($s.localNet -eq 'down'){continue}
        if($kind -eq 'path-check'){
            if($s.pending.ContainsKey($tag) -and $at -lt $s.pending[$tag].at){continue}
            if($code -ne 'process-exited' -and $s.pending.ContainsKey($tag) -and $s.pending[$tag].stage -eq 'direct'){continue}
            if($null -ne $p.until -and $Now -lt $p.until){continue}
            if($code -eq 'process-exited'){
                if($null -eq $s.roundSince){$s.roundSince=$at}
                Add-TransportDecisionPenalty $s $tag 'path-process-exited' $Now $at;continue
            }
            $reason='path-dial-failed'
            if($code -eq 'stalled' -or ($s.pending.ContainsKey($tag) -and $s.pending[$tag].reason -eq 'path-stalled')){$reason='path-stalled'}
            $s.pending[$tag]=@{at=$at;stage='direct';reason=$reason;requested=$false}
            if($null -eq $s.roundSince){$s.roundSince=$at}
            continue
        }
        if($kind -notin @('dial-fail','conn-closed-error','stall-suspect','engine-exit')){continue}
        if($s.pending.ContainsKey($tag) -and $kind -ne 'engine-exit'){continue}
        # Fixed 500 ms window from the first signal, shared by all failure kinds on a path.
        if($kind -ne 'engine-exit' -and $null -ne $p.lastSignalAt -and $at -lt ($p.lastSignalAt+500)){continue}
        if($kind -eq 'stall-suspect' -and $null -ne $p.stallIgnoreUntil -and $Now -lt $p.stallIgnoreUntil){continue}
        if($null -ne $p.until -and $Now -lt $p.until){continue}
        $p.lastSignalAt=$at
        if($null -eq $s.roundSince){$s.roundSince=$at}
        if($kind -eq 'engine-exit'){
            Add-TransportDecisionPenalty $s $tag 'path-process-exited' $Now $at;continue
        }
        $stage='direct';$reason='path-dial-failed'
        if($kind -eq 'stall-suspect'){$stage='path';$reason='path-stalled'}
        $s.pending[$tag]=@{at=$at;stage=$stage;reason=$reason;requested=$false}
    }
    # A successful probe may have removed the last waiter while direct I/O was running.
    $direct=@($s.pending.Keys|Where-Object {$s.pending[$_].stage -eq 'direct'}|Sort-Object)
    if(-not $direct.Count){$s.directRequestedAt=$null}
    $available=@($rows|Where-Object {$p=$s.paths[[string]$_.tag];$null -eq $p.until -or $Now -ge $p.until})
    $eligible=@($available|Where-Object {-not $s.pending.ContainsKey([string]$_.tag)})
    $ordered=@($eligible|Sort-Object @{Expression={Get-TransportDecisionHealth $_ $s.paths[[string]$_.tag]}},
        @{Expression={Get-TransportDecisionMetric $_ 'latencyMs'}},
        @{Expression={$s.paths[[string]$_.tag].failures+[double](Get-TransportDecisionValue $_ 'failures' 0)}},
        @{Expression={Get-TransportDecisionMetric $_ 'maxGapMs'}},@{Expression={[string]$_.tag}})
    $current=@($rows|Where-Object {[string]$_.tag -eq $CurrentTag})|Select-Object -First 1
    $currentFailed=$current -and $s.paths[$CurrentTag].failed

    if($s.localNet -eq 'down'){
        $action='searching';if($rolledBack){$action='rollback-penalties';$notes+=@('penalties-rolled-back')}
        Set-TransportDecisionReason $s 'local-network-down' $Now
    }elseif($direct.Count -and $null -eq $s.directRequestedAt -and (-not $currentFailed -or -not $eligible.Count)){
        $action='check-direct';$target=$direct[0];$s.directRequestedAt=$Now
        Set-TransportDecisionReason $s $s.pending[$target].reason $Now
    }elseif((-not $currentFailed -or -not $eligible.Count) -and @($s.pending.Keys|Where-Object {$s.pending[$_].stage -eq 'path' -and -not $s.pending[$_].requested}).Count){
        $target=@($s.pending.Keys|Where-Object {$s.pending[$_].stage -eq 'path' -and -not $s.pending[$_].requested}|Sort-Object)[0]
        $action='check-path';$s.pending[$target].requested=$true
        Set-TransportDecisionReason $s $s.pending[$target].reason $Now
    }elseif(-not $rows.Count){
        $action='searching';Set-TransportDecisionReason $s 'no-candidates' $Now
    }elseif(-not $available.Count){
        $action='searching';Set-TransportDecisionReason $s 'all-paths-penalized' $Now
        $notes+=@('waiting-penalty-expiry')
    }elseif($s.pending.Count -and (-not $currentFailed -or -not $eligible.Count)){
        # Wait for explicitly requested I/O; repeated ticks/events cannot duplicate it.
        $notes+=@('awaiting-check')
    }else{
        $best=$ordered|Select-Object -First 1
        $mustMove=(-not $current -or $currentFailed)
        $improve=$false
        if($AllowImprovement -and $current -and -not $currentFailed -and [string]$best.tag -ne $CurrentTag){
            $curLatency=Get-TransportDecisionMetric $current 'latencyMs'
            $bestLatency=Get-TransportDecisionMetric $best 'latencyMs'
            $improve=($curLatency -ne [double]::MaxValue -and $bestLatency -ne [double]::MaxValue -and
                (Get-TransportDecisionHealth $best $s.paths[[string]$best.tag]) -le (Get-TransportDecisionHealth $current $s.paths[$CurrentTag]) -and
                ($curLatency-$bestLatency) -gt [Math]::Max(30,0.2*$curLatency) -and ($Now-$s.selectedAt) -ge 30000)
        }
        if($mustMove -or $improve){
            $reason='ok';if($currentFailed){$reason=$s.paths[$CurrentTag].reason}
            Set-TransportDecisionReason $s $reason $Now
            if($null -ne $s.lastSwitchAt -and ($Now-$s.lastSwitchAt) -lt 10000){
                $notes+=@('switch-rate-limited')
                if($mustMove){$action='searching'}
            }elseif([string]$best.tag -eq $CurrentTag){
                # Only the current path remains after its pause: confirm it once.
                $action='check-path';$target=$CurrentTag
                $s.pending[$target]=@{at=$Now;stage='path';reason=$reason;requested=$true}
            }else{
                $action='switch';$target=[string]$best.tag
                $s.proposal=@{tag=$target;reason=$reason}
            }
        }else{Set-TransportDecisionReason $s 'ok' $Now}
    }
    # Bounded undo log: keep 45 seconds or the whole unfinished failure round.
    $keepSince=$Now-45000
    if($null -ne $s.roundSince){$keepSince=[Math]::Min($keepSince,[long]$s.roundSince)}
    $s.history=@($s.history|Where-Object {$_.at -ge $keepSince})
    $penalties=@{}
    foreach($key in $s.paths.Keys){$penalties[$key]=@{step=$s.paths[$key].step;until=$s.paths[$key].until}}
    return @{state=$s;verdict=@{action=$action;tag=$target;reason=(Copy-TransportDecisionValue $s.reason);penalties=$penalties;localNet=$s.localNet;notes=@($notes)}}
}
