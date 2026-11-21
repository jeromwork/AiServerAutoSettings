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
engine-exit (empty tag means CurrentTag) / two engine-exit events within 60 s, or no engine-ready within 20 s of engine-exit, prove a dead process
without a network check (one exit alone is a restart; engine-ready clears it); probe process-exited is a
network-like failure like the rest;
all network-like failures, including refused, require a fresh check-direct result.
check-path always requests the contract's 64 KiB confirmation/recovery probe.
#>

# Engine restart handling: one exit is a restart of the same path, not a failure.
$script:TransportExitWindowMs=60000     # two exits within this window are a real failure
$script:TransportReadyTimeoutMs=20000   # engine-ready must arrive within this time after an exit

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
        'server-unavailable'='Сервер недоступен'
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
        episode=$null
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
    $p.step=0;$p.until=$null;$p.failures=0;$p.failed=$false;$p.reason='ok';$p.lastResultAt=$At;$p.restartingSince=$null
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
    foreach($k in @($State.paths.Keys)){$State.paths[$k].restartingSince=$null}
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
    param(
        $State,$Candidates,[long]$Now,[string]$CurrentTag='', $Events=@(),[switch]$AllowImprovement,
        [switch]$SwitchEpisode, [long]$Stage1Ms=1000, [long]$Stage2Ms=3000, [long]$BlipMs=10000, [long]$HardFailMs=3000, $SwitchConfig=$null
    )
    if($SwitchEpisode -or ($null -ne $State -and $null -ne (Get-TransportDecisionValue $State 'episode'))){
        return Invoke-TransportSwitchEpisode -State $State -Candidates $Candidates -Now $Now -CurrentTag $CurrentTag -Events $Events -Stage1Ms $Stage1Ms -Stage2Ms $Stage2Ms -BlipMs $BlipMs -HardFailMs $HardFailMs -SwitchConfig $SwitchConfig
    }
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
        if($kind -in @('engine-exit','engine-ready') -and -not $tag){$tag=$CurrentTag}
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
        if($kind -eq 'engine-ready'){$p.restartingSince=$null;continue}
        if($s.localNet -eq 'down'){continue}
        if($kind -eq 'path-check'){
            if($s.pending.ContainsKey($tag) -and $at -lt $s.pending[$tag].at){continue}
            if($s.pending.ContainsKey($tag) -and $s.pending[$tag].stage -eq 'direct'){continue}
            if($null -ne $p.until -and $Now -lt $p.until){continue}
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
            $exits=@(@(Get-TransportDecisionValue $p 'exitTimes' @())|Where-Object {$at-[long]$_ -lt $script:TransportExitWindowMs})
            $exits=@($exits)+@($at);$p.exitTimes=@($exits)
            if($exits.Count -ge 2){
                $p.restartingSince=$null
                Add-TransportDecisionPenalty $s $tag 'path-process-exited' $Now $at
            }elseif($null -eq (Get-TransportDecisionValue $p 'restartingSince')){$p.restartingSince=$at}
            continue
        }
        $stage='direct';$reason='path-dial-failed'
        if($kind -eq 'stall-suspect'){$stage='path';$reason='path-stalled'}
        $s.pending[$tag]=@{at=$at;stage=$stage;reason=$reason;requested=$false}
    }
    # engine-ready did not arrive in time: the restart failed, so the path is really dead.
    if($s.localNet -ne 'down'){
        foreach($key in @($s.paths.Keys|Sort-Object)){
            $rp=$s.paths[$key];$since=Get-TransportDecisionValue $rp 'restartingSince'
            if($null -ne $since -and $key -in $tags -and ($Now-[long]$since) -ge $script:TransportReadyTimeoutMs){
                $rp.restartingSince=$null
                if($null -eq $rp.until -or $Now -ge $rp.until){
                    if($null -eq $s.roundSince){$s.roundSince=$Now}
                    Add-TransportDecisionPenalty $s $key 'path-process-exited' $Now $Now
                }
            }
        }
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

function Invoke-TransportSwitchEpisode {
    [CmdletBinding()]
    param($State,$Candidates,[long]$Now,[string]$CurrentTag='', $Events=@(),
        [long]$Stage1Ms = 1000, [long]$Stage2Ms = 3000, [long]$BlipMs = 10000, [long]$HardFailMs = 3000, $SwitchConfig = $null)
    if($null -eq $State){$State=New-TransportDecisionState $Now $CurrentTag}
    $s=Copy-TransportDecisionValue $State
    if($Now -lt $s.now){throw 'Decision time must not move backwards'}
    $s.now=$Now;$notes=@();$action='stay';$target=$CurrentTag

    if($SwitchConfig){
        $b=Get-TransportDecisionValue $SwitchConfig 'blipMs';if($null -ne $b){$BlipMs=[long]$(if($b.default){$b.default}else{$b})}
        $h=Get-TransportDecisionValue $SwitchConfig 'hardFailMs';if($null -ne $h){$HardFailMs=[long]$(if($h.default){$h.default}else{$h})}
        $st=Get-TransportDecisionValue $SwitchConfig 'stageMs';if($null -ne $st){$sa=@($st);if($sa.Count -ge 1){$Stage1Ms=[long]$sa[0]};if($sa.Count -ge 2){$Stage2Ms=[long]$sa[1]}}
    }
    $rows=@($Candidates|Where-Object {$t=[string](Get-TransportDecisionValue $_ 'tag' '');$t -match '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,95}$' -and $t -ne 'unavailable' -and (Get-TransportDecisionValue $_ 'enabled' $true) -ne $false -and -not (Get-TransportDecisionValue $_ 'buildFailed' $false) -and (Get-TransportDecisionValue $_ 'state' '') -ne 'disabled'})
    foreach($row in $rows){if(-not $s.paths.ContainsKey([string]$row.tag)){$s.paths[[string]$row.tag]=New-TransportDecisionPath}}

    if($CurrentTag -ne $s.currentTag){
        $why='ok';if($s.proposal -and $s.proposal.tag -eq $CurrentTag){$why=$s.proposal.reason}
        $s.switches=@(@($s.switches)+@(@{at=$Now;from=$s.currentTag;to=$CurrentTag;why=$why})|Select-Object -Last 10)
        $s.currentTag=$CurrentTag;$s.selectedAt=$Now;$s.lastSwitchAt=$Now;$s.proposal=$null
        if($s.paths.ContainsKey($CurrentTag)){$s.paths[$CurrentTag].failed=$false}
        if($s.episode -and $s.episode.status -eq 'switched' -and $s.episode.switchedTo -eq $CurrentTag){
            $s.episode.status='verifying';$penalties=@{};foreach($k in $s.paths.Keys){$penalties[$k]=@{step=$s.paths[$k].step;until=$s.paths[$k].until}}
            return @{state=$s;verdict=@{action='post-switch-verify';tag=$CurrentTag;tags=@($CurrentTag);reason=(Copy-TransportDecisionValue $s.reason);penalties=$penalties;localNet=$s.localNet;notes=@('post-switch-verify')}}
        }
    }

    $ep=$s.episode;$triggerKinds=@('dial-fail','conn-closed-error','stall-suspect','engine-exit','win.iface.changed','net.change')
    $sortedEvents=@($Events|Sort-Object {[long](Get-TransportDecisionValue $_ 'at' $Now)})

    if($null -eq $ep -or -not $ep.open){
        $triggerFound=$false;$triggerHard=$false
        foreach($ev in $sortedEvents){
            $at=[long](Get-TransportDecisionValue $ev 'at' $Now);if($at -gt $Now){continue}
            $kind=[string](Get-TransportDecisionValue $ev 'kind' '');$tag=[string](Get-TransportDecisionValue $ev 'tag' '');$code=[string](Get-TransportDecisionValue $ev 'code' '')
            if(-not $tag){$tag=$CurrentTag}
            if(($tag -eq $CurrentTag -and ($kind -in $triggerKinds -or ($kind -eq 'path-check' -and $code -notin @('ok','cancelled','canceled')))) -or $kind -in @('win.iface.changed','net.change')){
                $triggerFound=$true;if($code -eq 'refused'){$triggerHard=$true}
                if($kind -eq 'engine-exit'){
                    $p=$s.paths[$CurrentTag];$exits=@(@(Get-TransportDecisionValue $p 'exitTimes' @())|Where-Object {$at-[long]$_ -lt $script:TransportExitWindowMs})+@($at);$p.exitTimes=@($exits)
                    if($exits.Count -ge 2){$triggerHard=$true}
                }
            }
        }
        if($triggerFound){
            $ep=@{open=$true;openedAt=$Now;activeTag=$CurrentTag;hardFail=$triggerHard;stage1Done=$false;stage2Done=$false;activeProbeFailed=$true;responded=@{};status='open';switchedTo=$null}
            $s.episode=$ep;$unpenalized=@($rows|Where-Object {$p=$s.paths[[string]$_.tag];$null -eq $p.until -or $Now -ge $p.until}|ForEach-Object {[string]$_.tag})
            $penalties=@{};foreach($k in $s.paths.Keys){$penalties[$k]=@{step=$s.paths[$k].step;until=$s.paths[$k].until}}
            return @{state=$s;verdict=@{action='probe-round';tag=$CurrentTag;tags=$unpenalized;reason=(Copy-TransportDecisionValue $s.reason);penalties=$penalties;localNet=$s.localNet;notes=@()}}
        }
    }

    if($ep -and $ep.open){
        foreach($ev in $sortedEvents){
            $at=[long](Get-TransportDecisionValue $ev 'at' $Now);if($at -gt $Now){continue}
            $kind=[string](Get-TransportDecisionValue $ev 'kind' '');$tag=[string](Get-TransportDecisionValue $ev 'tag' '');$code=[string](Get-TransportDecisionValue $ev 'code' '')
            $local=(Get-TransportDecisionValue $ev 'local' $false) -eq $true;if(-not $tag -and $kind -in @('engine-exit','engine-ready')){$tag=$CurrentTag}
            if($kind -eq 'net-down' -or ($local -and $kind -in @('dial-fail','conn-closed-error'))){$s.localNet='down';$s.localNetAt=$at;continue}
            if($kind -eq 'net-up'){$s.localNet='ok';$s.localNetAt=$at;continue}
            if($kind -eq 'engine-exit' -and ($tag -eq $ep.activeTag -or -not $tag)){
                $p=$s.paths[$ep.activeTag];$exits=@(@(Get-TransportDecisionValue $p 'exitTimes' @())|Where-Object {$at-[long]$_ -lt $script:TransportExitWindowMs})+@($at);$p.exitTimes=@($exits)
                if($exits.Count -ge 2){$ep.hardFail=$true}
            }
            if($kind -eq 'path-check'){
                if($tag -eq $ep.activeTag){
                    if($code -eq 'ok'){
                        Reset-TransportDecisionPath $s $tag $at;$ep.open=$false;$ep.status='closed';Set-TransportDecisionReason $s 'ok' $Now
                        $penalties=@{};foreach($k in $s.paths.Keys){$penalties[$k]=@{step=$s.paths[$k].step;until=$s.paths[$k].until}}
                        return @{state=$s;verdict=@{action='stay';tag=$CurrentTag;reason=(Copy-TransportDecisionValue $s.reason);penalties=$penalties;localNet=$s.localNet;notes=@()}}
                    }else{$ep.activeProbeFailed=$true;if($code -eq 'refused'){$ep.hardFail=$true}}
                }else{if($code -eq 'ok'){$ep.responded[$tag]=@{at=$at;tag=$tag}}}
            }
        }
        $deadline=$(if($ep.hardFail){$HardFailMs}else{$BlipMs})
        if(($Now - $ep.openedAt) -ge $deadline){
            if($s.localNet -eq 'down'){
                Undo-TransportDecisionPenalties $s $Now;$ep.open=$false;$ep.status='closed';Set-TransportDecisionReason $s 'local-network-down' $Now
                $penalties=@{};foreach($k in $s.paths.Keys){$penalties[$k]=@{step=$s.paths[$k].step;until=$s.paths[$k].until}}
                return @{state=$s;verdict=@{action='stay';tag=$ep.activeTag;reason=(Copy-TransportDecisionValue $s.reason);penalties=$penalties;localNet=$s.localNet;notes=@('penalties-rolled-back')}}
            }
            $availableResponders=@($rows|Where-Object {$t=[string]$_.tag;$t -ne $ep.activeTag -and $ep.responded.ContainsKey($t) -and ($null -eq $s.paths[$t].until -or $Now -ge $s.paths[$t].until)})
            if(-not $availableResponders.Count){
                $ep.open=$false;$ep.status='closed';Set-TransportDecisionReason $s 'server-unavailable' $Now
                $penalties=@{};foreach($k in $s.paths.Keys){$penalties[$k]=@{step=$s.paths[$k].step;until=$s.paths[$k].until}}
                return @{state=$s;verdict=@{action='stay';tag=$ep.activeTag;reason=(Copy-TransportDecisionValue $s.reason);penalties=$penalties;localNet=$s.localNet;notes=@()}}
            }
            $ordered=@($availableResponders|Sort-Object @{Expression={Get-TransportDecisionHealth $_ $s.paths[[string]$_.tag]}},@{Expression={Get-TransportDecisionMetric $_ 'latencyMs'}},@{Expression={$s.paths[[string]$_.tag].failures+[double](Get-TransportDecisionValue $_ 'failures' 0)}},@{Expression={Get-TransportDecisionMetric $_ 'maxGapMs'}},@{Expression={[string]$_.tag}})
            $best=$ordered[0];$bestTag=[string]$best.tag
            Add-TransportDecisionPenalty $s $ep.activeTag 'path-dial-failed' $Now $Now
            $ep.open=$false;$ep.status='switched';$ep.switchedTo=$bestTag;$s.proposal=@{tag=$bestTag;reason='path-dial-failed'}
            Set-TransportDecisionReason $s 'path-dial-failed' $Now;$penalties=@{};foreach($k in $s.paths.Keys){$penalties[$k]=@{step=$s.paths[$k].step;until=$s.paths[$k].until}}
            return @{state=$s;verdict=@{action='switch';tag=$bestTag;reason=(Copy-TransportDecisionValue $s.reason);penalties=$penalties;localNet=$s.localNet;notes=@('post-switch-verify')}}
        }
        if(($Now - $ep.openedAt) -ge $Stage1Ms -and -not $ep.stage1Done){
            $ep.stage1Done=$true;if($ep.activeProbeFailed){$ep.activeProbeFailed=$false;$penalties=@{};foreach($k in $s.paths.Keys){$penalties[$k]=@{step=$s.paths[$k].step;until=$s.paths[$k].until}};return @{state=$s;verdict=@{action='probe-active';tag=$ep.activeTag;reason=(Copy-TransportDecisionValue $s.reason);penalties=$penalties;localNet=$s.localNet;notes=@()}}}
        }
        if(($Now - $ep.openedAt) -ge $Stage2Ms -and -not $ep.stage2Done){
            $ep.stage2Done=$true;if($ep.activeProbeFailed){$ep.activeProbeFailed=$false;$penalties=@{};foreach($k in $s.paths.Keys){$penalties[$k]=@{step=$s.paths[$k].step;until=$s.paths[$k].until}};return @{state=$s;verdict=@{action='probe-active';tag=$ep.activeTag;reason=(Copy-TransportDecisionValue $s.reason);penalties=$penalties;localNet=$s.localNet;notes=@()}}}
        }
    }
    $penalties=@{};foreach($k in $s.paths.Keys){$penalties[$k]=@{step=$s.paths[$k].step;until=$s.paths[$k].until}}
    return @{state=$s;verdict=@{action=$action;tag=$target;reason=(Copy-TransportDecisionValue $s.reason);penalties=$penalties;localNet=$s.localNet;notes=@($notes)}}
}
