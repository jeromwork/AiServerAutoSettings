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
legacy limit and episode minStay start at acknowledgement. Keep calling with empty Events
to reduce supplied tick events; this never schedules periodic probes.
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

function New-TransportDecisionState([long]$Now,[string]$CurrentTag='',[switch]$SwitchEpisode) {
    return @{
        now=$Now;currentTag=$CurrentTag;selectedAt=$Now;lastSwitchAt=$null
        localNet='unknown';localNetAt=$null;paths=@{};pending=@{}
        directRequestedAt=$null;history=@();roundSince=$null;consecutiveFailures=0
        switches=@();proposal=$null;reason=@{code='ok';text=(Get-TransportDecisionReasonText 'ok');since=$Now}
        episode=$null;episodeEnabled=[bool]$SwitchEpisode;switchPolicy=$null;qualityAt=$null;flapHistory=@();boundsOverflow=$false
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
    $ladder=@(5000,15000,45000,120000,300000)
    $ep=Get-TransportDecisionValue $State 'episode'
    if($ep -and $ep.policy){$ladder=@($ep.policy.penaltyMs)}
    $p.until=$Now+$ladder[$p.step-1]
    $p.recentPenaltyAt=$Now;$p.successStreak=0
    if($State.history.Count -gt 1024){$State.boundsOverflow=$true}
    $State.history=@($State.history|Select-Object -Last 1024)
    $p.failures=[Math]::Min(1000000,([long]$p.failures+1));$p.failed=$true;$p.reason=$Reason;$p.lastFailureAt=$Now;$p.lastResultAt=$At
    $State.consecutiveFailures=[Math]::Min(1000000,([long]$State.consecutiveFailures+1))
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
    $State.history=@($State.history|Where-Object {$_.at -lt $since}|Select-Object -Last 1024)
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
    # Once enabled, only the episode reducer may switch, including between episodes.
    # Legacy is the default; T2 must preserve opt-in when recreating state.
    $episodeMode=Get-TransportDecisionValue $State 'episodeEnabled' $false
    if($PSBoundParameters.ContainsKey('SwitchEpisode')){$episodeMode=[bool]$SwitchEpisode}
    if($episodeMode){
        $episodeArgs=@{State=$State;Candidates=$Candidates;Now=$Now;CurrentTag=$CurrentTag;Events=$Events;AllowImprovement=$AllowImprovement}
        foreach($key in @('Stage1Ms','Stage2Ms','BlipMs','HardFailMs','SwitchConfig')){
            if($PSBoundParameters.ContainsKey($key)){$episodeArgs[$key]=$PSBoundParameters[$key]}
        }
        return Invoke-TransportSwitchEpisode @episodeArgs
    }
    if($null -eq $State){$State=New-TransportDecisionState $Now $CurrentTag}
    $s=Copy-TransportDecisionValue $State
    if($Now -lt $s.now){throw 'Decision time must not move backwards'}
    $s.now=$Now;$s.episodeEnabled=$false;$s.episode=$null;$notes=@();$action='none';$target='';$rolledBack=$false
    $rows=@(Get-TransportDecisionRows $Candidates $CurrentTag)
    Limit-TransportDecisionState $s @($rows|ForEach-Object {[string]$_.tag}) $Now
    if(@($Candidates).Count -gt 256 -or @($Events).Count -gt 512){$s.boundsOverflow=$true}
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

    foreach($event in @(@($Events|Select-Object -Last 512)|Sort-Object {[long](Get-TransportDecisionValue $_ 'at' $Now)})){
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
            $exits=@($exits)+@($at);$p.exitTimes=@($exits|Select-Object -Last 2)
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
    $s.history=@($s.history|Where-Object {$_.at -ge $keepSince}|Select-Object -Last 1024)
    $penalties=@{}
    foreach($key in $s.paths.Keys){$penalties[$key]=@{step=$s.paths[$key].step;until=$s.paths[$key].until}}
    return @{state=$s;verdict=@{action=$action;tag=$target;reason=(Copy-TransportDecisionValue $s.reason);penalties=$penalties;localNet=$s.localNet;notes=@($notes)}}
}

# Bounds apply to scalar thresholds and to {default,min,max} config entries.
function Get-TransportSwitchThreshold($Value,[long]$Fallback) {
    $lower=1L;$upper=300000L;$parsed=0L
    if($Value -is [Collections.IDictionary] -or $Value -is [System.Management.Automation.PSCustomObject]){
        if([long]::TryParse([string](Get-TransportDecisionValue $Value 'min'),[ref]$parsed)){$lower=[Math]::Max(1L,[Math]::Min(300000L,$parsed))}
        if([long]::TryParse([string](Get-TransportDecisionValue $Value 'max'),[ref]$parsed)){$upper=[Math]::Max(1L,[Math]::Min(300000L,$parsed))}
        $Value=Get-TransportDecisionValue $Value 'default'
    }
    if($lower -gt $upper){$lower=1L;$upper=300000L}
    if(-not [long]::TryParse([string]$Value,[ref]$parsed)){$parsed=$Fallback}
    return [Math]::Max($lower,[Math]::Min($upper,$parsed))
}

# The light-probe fuse never proves success; it only keeps a delayed signal from
# abandoning an in-flight round. All comparisons use supplied event time.
# Предохранитель (конституция 4а): событие результата пробы недоступно, если процесс завис; при срабатывании — отказ от ожидания пробы, успех не объявляет.
$script:TransportLightProbeFuseMs=3000L

# §4б: at most 256 candidate keys, 512 input events and 1024 undo/switch records.
# Candidate removal drops its state; overflow drops oldest records, never invents success.
function Get-TransportDecisionRows($Candidates,[string]$CurrentTag='') {
    $seen=@{};$rows=@()
    foreach($row in $Candidates){
        $tag=[string](Get-TransportDecisionValue $row 'tag' '')
        if($tag -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,95}$' -or $tag -eq 'unavailable' -or
            (Get-TransportDecisionValue $row 'enabled' $true) -eq $false -or
            (Get-TransportDecisionValue $row 'buildFailed' $false) -or
            (Get-TransportDecisionValue $row 'state' '') -eq 'disabled' -or $seen.ContainsKey($tag)){continue}
        if($rows.Count -ge 256){
            if($tag -eq $CurrentTag){[void]$seen.Remove([string]$rows[-1].tag);$rows[-1]=$row;$seen[$tag]=$true}
            continue
        }
        $seen[$tag]=$true;$rows+=@($row)
    }
    return $rows
}

function Limit-TransportDecisionState($State,$Tags,[long]$Now) {
    $overflow=$State.paths.Count -gt 256 -or $State.history.Count -gt 1024 -or
        @(Get-TransportDecisionValue $State 'flapHistory' @()).Count -gt 1024
    foreach($name in @('paths','pending')){
        foreach($key in @($State[$name].Keys)){if($key -notin $Tags){[void]$State[$name].Remove($key)}}
    }
    foreach($key in @($State.paths.Keys)){
        $p=$State.paths[$key]
        if($p.ContainsKey('exitTimes')){$p.exitTimes=@($p.exitTimes|Select-Object -Last 2)}
    }
    $keepSince=$Now-45000L;if($null -ne $State.roundSince){$keepSince=[Math]::Min($keepSince,[long]$State.roundSince)}
    $State.history=@($State.history|Where-Object {$_.tag -in $Tags -and $_.at -ge $keepSince}|Select-Object -Last 1024)
    $State.switches=@($State.switches|Select-Object -Last 10)
    $State.flapHistory=@(@(Get-TransportDecisionValue $State 'flapHistory' @())|Where-Object {$_.at -gt $Now-1800000 -and $_.at -le $Now}|Select-Object -Last 1024)
    $ep=$State.episode
    if($ep){foreach($name in @('responded','probed','attempted')){
        $map=Get-TransportDecisionValue $ep $name
        if($map){foreach($key in @($map.Keys)){if($key -notin $Tags){[void]$map.Remove($key)}}}
    }}
    if($overflow){$State.boundsOverflow=$true}
    elseif($State.paths.Count -lt 192 -and $State.history.Count -lt 768 -and $State.flapHistory.Count -lt 768){$State.boundsOverflow=$false}
}

# Only authoritative bus events enter switch history; acknowledgement is minStay only.
function Add-TransportSwitchChange($State,$Change) {
    if(@(@($State.flapHistory)+@($State.switches)|Where-Object {
        $_.at -eq $Change.at -and $_.from -eq $Change.from -and $_.to -eq $Change.to
    }).Count){return}
    if($State.flapHistory.Count -ge 1024){$State.boundsOverflow=$true}
    $order=@('at','from','to')
    $State.flapHistory=@(@($State.flapHistory)+@($Change)|Where-Object {$_.at -gt $State.now-1800000}|Sort-Object -Property $order|Select-Object -Last 1024)
    $State.switches=@(@($State.switches)+@($Change)|Sort-Object -Property $order|Select-Object -Last 10)
}

function Get-TransportSwitchNumber($Value,[long]$Default,[long]$Min,[long]$Max) {
    $n=0L;if(-not [long]::TryParse([string]$Value,[ref]$n)){$n=$Default}
    return [Math]::Max($Min,[Math]::Min($Max,$n))
}

function Get-TransportSwitchPolicy($Config,[long]$Stage1Ms,[long]$Stage2Ms,[long]$BlipMs,[long]$HardFailMs) {
    $st=@(Get-TransportDecisionValue $Config 'stageMs' @($Stage1Ms,$Stage2Ms))
    $a=Get-TransportSwitchThreshold (Get-TransportDecisionValue $Config 'stage1Ms' $(if($st.Count -ge 1){$st[0]})) 1000
    $b=Get-TransportSwitchThreshold (Get-TransportDecisionValue $Config 'stage2Ms' $(if($st.Count -ge 2){$st[1]})) 3000
    $blip=Get-TransportSwitchThreshold (Get-TransportDecisionValue $Config 'blipMs' $BlipMs) 10000
    $hard=Get-TransportSwitchThreshold (Get-TransportDecisionValue $Config 'hardFailMs' $HardFailMs) 3000
    # Q rounds/clamps stages independently: equality and stage2 > blip are valid.
    if($a -gt $b){$a=1000L;$b=3000L}
    $ladder=@(@(Get-TransportDecisionValue $Config 'penaltyMs' @(5000,15000,45000,120000,300000))|Select-Object -First 6)
    $valid=$ladder.Count -eq 5;$last=0L;$parsed=@()
    foreach($v in $ladder){$n=0L;if(-not [long]::TryParse([string]$v,[ref]$n) -or $n -lt $last -or $n -lt 1 -or $n -gt 3600000){$valid=$false};$parsed+=@($n);$last=$n}
    if(-not $valid){$parsed=@(5000,15000,45000,120000,300000)}
    $pct=0.0
    if(-not [double]::TryParse([string](Get-TransportDecisionValue $Config 'improvementRatio' 0.2),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$pct) -or
        [double]::IsNaN($pct) -or $pct -lt 0 -or $pct -gt 1){$pct=0.2}
    return @{stage1Ms=$a;stage2Ms=$b;blipMs=$blip;hardFailMs=$hard;penaltyMs=$parsed
        minStayMs=(Get-TransportSwitchNumber (Get-TransportDecisionValue $Config 'minStayMs') 30000 1 3600000)
        improvementMs=(Get-TransportSwitchNumber (Get-TransportDecisionValue $Config 'improvementMs') 30 1 60000)
        improvementRatio=$pct
        flapWindowMs=(Get-TransportSwitchNumber (Get-TransportDecisionValue $Config 'flapWindowMs') 600000 1 1800000)
        flapSwitches=(Get-TransportSwitchNumber (Get-TransportDecisionValue $Config 'flapSwitches') 3 1 1000)
        flapping=((Get-TransportDecisionValue $Config 'flapping' $false) -eq $true)
        allowImprovement=((Get-TransportDecisionValue $Config 'allowImprovement' $true) -ne $false)}
}

# Consume quality in event order: a quality fact after the opening signal belongs
# to the next episode, even if both facts were delivered in one batch.
function Update-TransportSwitchPolicy($State,$Event,[long]$Now) {
    $at=[long](Get-TransportDecisionValue $Event 'at' $Now)
    if($null -ne $State.qualityAt -and $at -le $State.qualityAt){return}
    $fields=Get-TransportDecisionValue $Event 'fields' $Event
    $merged=Copy-TransportDecisionValue $State.switchPolicy
    if($null -ne (Get-TransportDecisionValue $fields 'stageMs')){
        [void]$merged.Remove('stage1Ms');[void]$merged.Remove('stage2Ms')
    }
    foreach($name in @('stage1Ms','stage2Ms','stageMs','blipMs','hardFailMs','minStayMs','improvementMs','improvementRatio','penaltyMs','flapWindowMs','flapSwitches','flapping','allowImprovement')){
        $v=Get-TransportDecisionValue $fields $name
        if($null -ne $v){$merged[$name]=$v}
    }
    $State.switchPolicy=Get-TransportSwitchPolicy $merged 1000 3000 10000 3000;$State.qualityAt=$at
}

function Get-TransportEpisodePolicy($State,[long]$Now) {
    $p=Copy-TransportDecisionValue $State.switchPolicy
    $localFlap=@($State.flapHistory|Where-Object {$_.at -gt $Now-$p.flapWindowMs}).Count -ge $p.flapSwitches
    # Q already includes flapK in its flat snapshot: do not multiply it a second time.
    if($localFlap -and -not $p.flapping){$p.blipMs*=2}
    $p.flapping=$localFlap -or $p.flapping
    if($p.flapping){$p.allowImprovement=$false}
    return $p
}

function New-TransportSwitchResult($State,[string]$Action,[string]$Tag,$Tags=@(),$Notes=@(),[bool]$Direct=$false) {
    $penalties=@{}
    foreach($key in $State.paths.Keys){$penalties[$key]=@{step=$State.paths[$key].step;until=$State.paths[$key].until}}
    $policy=Get-TransportEpisodePolicy $State $State.now
    if($State.episode -and $State.episode.status -in @('open','switched','verifying') -and $State.episode.policy){$policy=$State.episode.policy}
    return @{state=$State;verdict=@{action=$Action;tag=$Tag;tags=@($Tags);direct=$Direct;reason=(Copy-TransportDecisionValue $State.reason);penalties=$penalties;localNet=$State.localNet;notes=@($Notes)
        flapping=[bool]$policy.flapping;allowImprovement=[bool]$policy.allowImprovement;boundsOverflow=[bool]$State.boundsOverflow}}
}

function Test-TransportSwitchSignal($State,$Event,[string]$CurrentTag,[long]$Now) {
    if((Get-TransportDecisionValue $Event 'local' $false) -eq $true){return $false}
    $kind=[string](Get-TransportDecisionValue $Event 'kind' '');$tag=[string](Get-TransportDecisionValue $Event 'tag' '')
    $code=[string](Get-TransportDecisionValue $Event 'code' '');$at=[long](Get-TransportDecisionValue $Event 'at' $Now)
    if($kind -in @('win.iface.changed','net.change')){return $true}
    if(-not $tag){$tag=$CurrentTag}
    if($tag -ne $CurrentTag){return $false}
    $p=$State.paths[$tag]
    if($p -and $null -ne $p.lastResultAt -and $at -lt $p.lastResultAt){return $false}
    if($kind -eq 'path-check'){
        if($p -and $null -ne $p.lastCheckAt -and $at -le $p.lastCheckAt){return $false}
        if($null -ne $State.localNetAt -and $at -lt $State.localNetAt){return $false}
        return $code -in @('timeout','stalled','refused','process-exited')
    }
    return $kind -in @('dial-fail','conn-closed-error','stall-suspect','engine-exit')
}

function New-TransportSwitchEpisode([long]$At,[long]$ProbeAt,[string]$CurrentTag,$Policy) {
    return @{open=$true;openedAt=$At;activeTag=$CurrentTag;hardFail=$false;stage1Done=$false;stage2Done=$false;activeProbeFailed=$false;activeProbeAt=$ProbeAt
        responded=@{};probed=@{};attempted=@{};status='open';switchedTo=$null;verifyAt=$null;verifyFailed=$false;policy=(Copy-TransportDecisionValue $Policy)}
}

function Test-TransportSwitchImprovement($State,$Current,$Candidate,$Policy,[long]$Now) {
    if(-not $Policy.allowImprovement -or -not $Current -or ($Now-$State.selectedAt) -lt $Policy.minStayMs){return $false}
    $a=Get-TransportDecisionMetric $Current 'latencyMs';$b=Get-TransportDecisionMetric $Candidate 'latencyMs'
    return (Get-TransportDecisionHealth $Candidate $State.paths[[string]$Candidate.tag]) -le (Get-TransportDecisionHealth $Current $State.paths[[string]$Current.tag]) -and $a -ne [double]::MaxValue -and $b -ne [double]::MaxValue -and
        ($a-$b) -ge [Math]::Max($Policy.improvementMs,$Policy.improvementRatio*$a)
}

function Get-TransportSwitchCandidates($State,$Rows,$Episode,[long]$Now) {
    $current=@($Rows|Where-Object {$_.tag -eq $State.currentTag})|Select-Object -First 1
    $eligible=@(foreach($row in $Rows){
        $tag=[string]$row.tag;$p=$State.paths[$tag]
        if($tag -eq $State.currentTag -or -not $Episode.responded.ContainsKey($tag) -or $Episode.attempted.ContainsKey($tag) -or ($null -ne $p.until -and $Now -lt $p.until)){continue}
        $recent=Get-TransportDecisionValue $p 'recentPenaltyAt' $p.lastFailureAt
        if($null -ne $recent -and $Now-[long]$recent -lt $Episode.policy.flapWindowMs){
            if((Get-TransportDecisionValue $p 'successStreak' 0) -lt 2 -or -not (Test-TransportSwitchImprovement $State $current $row $Episode.policy $Now)){continue}
        }
        $row
    })
    # Optional Q annotation on rows: absent means the original health/latency order.
    return @($eligible|Sort-Object @{Expression={[int][bool](Get-TransportDecisionValue $_ 'qualityPenalty' $false)}},@{Expression={Get-TransportDecisionHealth $_ $State.paths[[string]$_.tag]}},@{Expression={Get-TransportDecisionMetric $_ 'latencyMs'}},@{Expression={$State.paths[[string]$_.tag].failures+[double](Get-TransportDecisionValue $_ 'failures' 0)}},@{Expression={Get-TransportDecisionMetric $_ 'maxGapMs'}},@{Expression={[string]$_.tag}})
}

function Invoke-TransportSwitchEpisode {
    [CmdletBinding()]
    param($State,$Candidates,[long]$Now,[string]$CurrentTag='', $Events=@(),[switch]$AllowImprovement,
        [long]$Stage1Ms=1000,[long]$Stage2Ms=3000,[long]$BlipMs=10000,[long]$HardFailMs=3000,$SwitchConfig=$null)
    if($null -eq $State){$State=New-TransportDecisionState $Now $CurrentTag}
    $s=Copy-TransportDecisionValue $State
    if($Now -lt $s.now){throw 'Decision time must not move backwards'}
    $s.now=$Now;$s.episodeEnabled=$true;$notes=@()
    if($null -ne $SwitchConfig -or -not $s.switchPolicy){$s.switchPolicy=Get-TransportSwitchPolicy $SwitchConfig $Stage1Ms $Stage2Ms $BlipMs $HardFailMs}
    elseif(@('Stage1Ms','Stage2Ms','BlipMs','HardFailMs'|Where-Object {$PSBoundParameters.ContainsKey($_)}).Count){
        $pending=Copy-TransportDecisionValue $s.switchPolicy
        foreach($name in @('stage1Ms','stage2Ms','blipMs','hardFailMs')){if($PSBoundParameters.ContainsKey($name)){$pending[$name]=$PSBoundParameters[$name]}}
        $s.switchPolicy=Get-TransportSwitchPolicy $pending $Stage1Ms $Stage2Ms $BlipMs $HardFailMs
    }
    $rows=@(Get-TransportDecisionRows $Candidates $CurrentTag);$tags=@($rows|ForEach-Object {[string]$_.tag})
    Limit-TransportDecisionState $s $tags $Now
    if(@($Candidates).Count -gt 256 -or @($Events).Count -gt 512){$s.boundsOverflow=$true}
    foreach($tag in $tags){if(-not $s.paths.ContainsKey($tag)){$s.paths[$tag]=New-TransportDecisionPath}}
    $ep=$s.episode;$acknowledged=$false
    $selectionChanged=$CurrentTag -ne $s.currentTag
    if($selectionChanged){
        $s.currentTag=$CurrentTag;$s.proposal=$null
        if($ep -and $ep.status -eq 'switched' -and $ep.switchedTo -eq $CurrentTag){
            $ep.status='verifying';$ep.verifyAt=$Now;$acknowledged=$true
        }elseif($ep){$ep.open=$false;$ep.status='closed'}
    }
    $cancelCodes=@('cancelled','canceled','operation-canceled','operation-cancelled','context-canceled','aborted')
    $probeCodes=@('ok','timeout','stalled','refused','process-exited')
    $sortedEvents=@(@(foreach($ev in @($Events|Select-Object -Last 512)){
        $at=0L
        if([long]::TryParse([string](Get-TransportDecisionValue $ev 'at' $Now),[ref]$at) -and $at -ge 0 -and $at -le $Now){$ev}
    })|Sort-Object {[long](Get-TransportDecisionValue $_ 'at' $Now)})
    foreach($ev in $sortedEvents){
        if((Get-TransportDecisionValue $ev 'kind') -eq 'transport.switch'){
            $at=[long](Get-TransportDecisionValue $ev 'at' $Now);$tag=[string](Get-TransportDecisionValue $ev 'tag' '')
            $from=[string](Get-TransportDecisionValue $ev 'from' '')
            $to=[string](Get-TransportDecisionValue $ev 'to' $tag)
            if($from -eq $to -or (Get-TransportDecisionValue $ev 'changed' $true) -eq $false -or
                $from -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,95}$' -or $from -eq 'unavailable' -or $to -notin $tags){continue}
            Add-TransportSwitchChange $s @{at=$at;from=$from;to=$to;why='ok'}
        }
    }
    # A known event at/after selectedAt supplies the selection time. Otherwise a
    # changed CurrentTag starts minStay at Now, without inventing a history entry.
    # Delayed events can only move this time forward; no ack/event correlation.
    $latest=@($s.switches|Where-Object {$_.to -eq $CurrentTag -and $_.at -ge $s.selectedAt}|Select-Object -Last 1)
    if($latest.Count){
        $s.selectedAt=[Math]::Max([long]$s.selectedAt,[long]$latest[0].at);$s.lastSwitchAt=$s.selectedAt
    }elseif($selectionChanged){$s.selectedAt=$Now;$s.lastSwitchAt=$Now}
    $opened=$false
    # Find the opening timestamp first, so older results cannot close this episode.
    if((-not $ep -or $ep.status -eq 'closed') -and -not $acknowledged){
        foreach($ev in $sortedEvents){
            if((Get-TransportDecisionValue $ev 'code') -in $cancelCodes){continue}
            if((Get-TransportDecisionValue $ev 'kind') -eq 'net.quality'){Update-TransportSwitchPolicy $s $ev $Now;continue}
            if(Test-TransportSwitchSignal $s $ev $CurrentTag $Now){
                $ep=New-TransportSwitchEpisode ([long](Get-TransportDecisionValue $ev 'at' $Now)) $Now $CurrentTag (Get-TransportEpisodePolicy $s $Now)
                $s.episode=$ep;$opened=$true;break
            }
        }
    }
    foreach($ev in $sortedEvents){
        $at=[long](Get-TransportDecisionValue $ev 'at' $Now)
        $kind=[string](Get-TransportDecisionValue $ev 'kind' '');$tag=[string](Get-TransportDecisionValue $ev 'tag' '');$code=[string](Get-TransportDecisionValue $ev 'code' '')
        if($code -in $cancelCodes){continue}
        if($kind -eq 'net.quality'){Update-TransportSwitchPolicy $s $ev $Now;continue}
        if($kind -eq 'net-down' -or ((Get-TransportDecisionValue $ev 'local' $false) -eq $true -and $kind -in @('dial-fail','conn-closed-error'))){
            if($null -eq $s.localNetAt -or $at -ge $s.localNetAt){$s.localNet='down';$s.localNetAt=$at};continue
        }
        if($kind -eq 'net-up'){
            if($null -eq $s.localNetAt -or $at -ge $s.localNetAt){$s.localNet='ok';$s.localNetAt=$at};continue
        }
        if($kind -eq 'transport.switch'){continue}
        if(-not $tag -and $kind -in @('engine-exit','engine-ready')){$tag=$CurrentTag}
        if($tag -notin $tags){continue}
        $p=$s.paths[$tag]
        if($null -ne $p.lastResultAt -and $at -lt $p.lastResultAt){continue}
        if(((-not $ep) -or $ep.status -eq 'closed') -and (Test-TransportSwitchSignal $s $ev $CurrentTag $Now)){
            $ep=New-TransportSwitchEpisode $at $Now $CurrentTag (Get-TransportEpisodePolicy $s $Now)
            $s.episode=$ep;$opened=$true
        }
        if($kind -in @('dial-fail','conn-closed-error','engine-exit','stall-suspect')){$p.successStreak=0}
        if($ep -and $ep.status -eq 'verifying' -and $tag -eq $CurrentTag -and $kind -in @('dial-fail','conn-closed-error','stall-suspect','engine-exit')){
            $s.pending[$tag]=@{at=$at;stage='episode-signal';reason='path-dial-failed'}
        }
        if($kind -eq 'engine-ready'){$p.exitTimes=@();continue}
        if($kind -eq 'engine-exit' -and $ep -and $ep.open -and $at -ge $ep.openedAt -and $tag -eq $ep.activeTag){
            $p.exitTimes=@(@(@(Get-TransportDecisionValue $p 'exitTimes' @())|Where-Object {$at-[long]$_ -lt $script:TransportExitWindowMs})+@($at)|Select-Object -Last 2)
            if($p.exitTimes.Count -ge 2){$ep.hardFail=$true}
        }
        # Q can refuse the 64 KiB reservation (including after a failed verify).
        # Closing a skipped verification records no success and leaves metrics untouched.
        if($kind -eq 'post-switch-verify' -and $code -eq 'skipped'){
            if($ep -and $ep.status -eq 'verifying' -and $tag -eq $CurrentTag -and -not $acknowledged -and $at -ge $ep.verifyAt){
                $ep.status='closed';$ep.verifySkipped=$true;$notes+=@('post-switch-verify-skipped')
                if($s.pending.ContainsKey($tag)){
                    # Budget refusal is no evidence of recovery. Probe the saved real
                    # signal in a new episode, using its time and a fresh probe fuse.
                    $ep=New-TransportSwitchEpisode $s.pending[$tag].at $Now $CurrentTag (Get-TransportEpisodePolicy $s $Now)
                    $s.episode=$ep;$opened=$true
                }
            }
            continue
        }
        if($kind -notin @('path-check','post-switch-verify') -or $code -notin $probeCodes){continue}
        if(($null -ne $p.lastCheckAt -and $at -le $p.lastCheckAt) -or ($null -ne $s.localNetAt -and $at -lt $s.localNetAt)){continue}
        $verifying=$ep -and $ep.status -eq 'verifying' -and $tag -eq $CurrentTag -and -not $acknowledged -and $at -ge $ep.verifyAt
        if($kind -eq 'post-switch-verify' -and -not $verifying){continue}
        $p.lastCheckAt=$at;$p.lastResultAt=$at
        if($code -eq 'ok'){
            $streak=[Math]::Min(2,1+[int](Get-TransportDecisionValue $p 'successStreak' 0))
            Reset-TransportDecisionPath $s $tag $at;$p.successStreak=$streak
            if($tag -eq $CurrentTag -and (-not $ep -or $ep.status -eq 'closed')){Set-TransportDecisionReason $s 'ok' $Now}
            # Old results still recover penalties; only episode responses need openedAt.
            if($ep -and $ep.status -ne 'closed' -and $at -ge $ep.openedAt){
                if($verifying){$ep.status='closed';Set-TransportDecisionReason $s 'ok' $Now}
                elseif($ep.open -and $tag -eq $ep.activeTag){$ep.open=$false;$ep.status='closed';Set-TransportDecisionReason $s 'ok' $Now}
                elseif($tag -ne $ep.activeTag){$ep.responded[$tag]=@{at=$at;tag=$tag}}
            }
        }else{
            $p.successStreak=0
            if($verifying){$ep.verifyFailed=$true}
            elseif($ep -and $ep.open -and $at -ge $ep.openedAt -and $tag -eq $ep.activeTag){
                if(-not $opened -and $at -ge $ep.activeProbeAt){$ep.activeProbeFailed=$true}
                if($code -eq 'refused'){$ep.hardFail=$true}
            }elseif($ep -and $ep.responded){[void]$ep.responded.Remove($tag)}
        }
    }
    if($s.localNet -eq 'down' -and (-not $ep -or -not $ep.open)){
        Undo-TransportDecisionPenalties $s $Now
        if($ep){$ep.open=$false;$ep.status='closed'}
        Set-TransportDecisionReason $s 'local-network-down' $Now
        return New-TransportSwitchResult $s 'stay' $CurrentTag @() @('penalties-rolled-back')
    }
    if($acknowledged){return New-TransportSwitchResult $s 'post-switch-verify' $CurrentTag @($CurrentTag) @('post-switch-verify')}
    if($ep -and $ep.status -eq 'switched'){
        return New-TransportSwitchResult $s 'switch' $ep.switchedTo @() @('awaiting-selector')
    }
    if($ep -and $ep.status -eq 'verifying' -and -not $ep.verifyFailed){return New-TransportSwitchResult $s 'stay' $CurrentTag}
    if(-not $ep -or $ep.status -eq 'closed'){
        # Optional improvement uses known successful results only; it never starts probes.
        if($AllowImprovement -and $s.localNet -eq 'ok'){
            $policy=Get-TransportEpisodePolicy $s $Now
            $candidateEp=New-TransportSwitchEpisode $Now $Now $CurrentTag $policy
            foreach($row in $rows){$t=[string]$row.tag;if($s.paths[$t].lastResultAt -ne $null -and $s.paths[$t].successStreak -gt 0){$candidateEp.responded[$t]=@{tag=$t}}}
            $ordered=@(Get-TransportSwitchCandidates $s $rows $candidateEp $Now)
            $cur=@($rows|Where-Object {$_.tag -eq $CurrentTag})|Select-Object -First 1
            if($ordered.Count -and (Test-TransportSwitchImprovement $s $cur $ordered[0] $policy $Now)){
                $candidateEp.open=$false;$candidateEp.status='switched';$candidateEp.switchedTo=[string]$ordered[0].tag;$candidateEp.attempted[$CurrentTag]=$true
                $s.episode=$candidateEp
                return New-TransportSwitchResult $s 'switch' $candidateEp.switchedTo @() @('improvement')
            }
        }
        return New-TransportSwitchResult $s 'stay' $CurrentTag @() $notes
    }
    $unpenalized=@($rows|Where-Object {$p=$s.paths[[string]$_.tag];$_.tag -eq $CurrentTag -or $null -eq $p.until -or $Now -ge $p.until}|ForEach-Object {[string]$_.tag})
    if($opened){
        foreach($tag in $unpenalized){$ep.probed[$tag]=1}
        return New-TransportSwitchResult $s 'probe-round' $CurrentTag $unpenalized $notes $true
    }
    $hasActive=$ep.activeTag -in $tags
    $deadline=$(if($ep.hardFail){$ep.policy.hardFailMs}else{$ep.policy.blipMs})
    $decisionAt=[Math]::Max(($ep.openedAt+$deadline),($ep.activeProbeAt+$script:TransportLightProbeFuseMs))
    if($ep.verifyFailed -or -not $hasActive -or $Now -ge $decisionAt){
        if($s.localNet -eq 'down'){
            Undo-TransportDecisionPenalties $s $Now;$ep.open=$false;$ep.status='closed';Set-TransportDecisionReason $s 'local-network-down' $Now
            return New-TransportSwitchResult $s 'stay' $CurrentTag @() @('penalties-rolled-back')
        }
        if($ep.verifyFailed){
            Add-TransportDecisionPenalty $s $CurrentTag 'path-dial-failed' $Now $Now
            $ep.attempted[$CurrentTag]=$true;$ep.verifyFailed=$false
        }
        $ordered=@(Get-TransportSwitchCandidates $s $rows $ep $Now)
        if(-not $ordered.Count){
            $ep.open=$false;$ep.status='closed';Set-TransportDecisionReason $s 'server-unavailable' $Now
            return New-TransportSwitchResult $s 'stay' $CurrentTag
        }
        if($ep.open -and $hasActive){Add-TransportDecisionPenalty $s $ep.activeTag 'path-dial-failed' $Now $Now}
        $ep.attempted[$CurrentTag]=$true
        $ep.open=$false;$ep.status='switched';$ep.switchedTo=[string]$ordered[0].tag;$s.proposal=@{tag=$ep.switchedTo;reason='path-dial-failed'}
        Set-TransportDecisionReason $s 'path-dial-failed' $Now
        return New-TransportSwitchResult $s 'switch' $ep.switchedTo @() @('post-switch-verify')
    }
    foreach($stage in @(1,2)){
        $done='stage'+$stage+'Done';$ms='stage'+$stage+'Ms'
        if(($Now-$ep.openedAt) -ge $ep.policy[$ms] -and -not $ep[$done]){
            $ep[$done]=$true
            # A late tick must not start a retry that extends the decision threshold.
            # A round already in flight still keeps its own light-probe fuse above.
            if($ep.activeProbeFailed -and $Now+$script:TransportLightProbeFuseMs -le $ep.openedAt+$deadline -and (Get-TransportDecisionValue $ep.probed $ep.activeTag 0) -lt 3){
                $ep.activeProbeFailed=$false;$ep.activeProbeAt=$Now;$ep.probed[$ep.activeTag]++
                return New-TransportSwitchResult $s 'probe-active' $ep.activeTag
            }
        }
    }
    return New-TransportSwitchResult $s 'stay' $CurrentTag
}
