#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Transport.Quality.ps1')
$script:checks=0
function Check([bool]$Ok,[string]$Why){$script:checks++;if(-not $Ok){throw $Why}}
$script:now=100000000L;$script:seq=0
function Send($State,[string]$Kind,$Fields=@{}){
    $script:seq++;$Fields.id=$State.id;$Fields.eventId=[string]$script:seq
    Update-TransportQuality $State $Kind $Fields $script:now
}
function Network($State,[string]$Id,[string]$Class){Update-TransportQuality $State 'net.change' @{id=$Id;class=$Class} $script:now}
$s=New-TransportQualityState
Check ($s.config.blipMs.default -eq 10000 -and $s.config.hardFailMs.min -eq 1000 -and $s.config.classK.mobile -eq 1.5) 'missing switch defaults'
$profile=New-TransportQualityState @{profile=@{transport=@{switch=@{classK=@{wifi=0.9}}}}}
Check ($profile.config.classK.wifi -eq 0.9 -and $profile.config.classK.fixed -eq 0.5) 'partial public policy merges defaults'
$q=Network $s 'n1' 'fixed'
Check ($q.stabilityK -eq 1 -and $q.blipMs -eq 5000 -and $q.hardFailMs -eq 1500 -and $q.stage1Ms -eq 500) 'initial class formula'
$s.networks.n1.stability=0.6;$q=Get-TransportQualitySnapshot $s $now
Check ($q.blipMs -eq 3000 -and $q.hardFailMs -eq 1000) 'lower clamp'
$s.networks.n1.stability=2.0;$s.config.classK.fixed=10;$q=Get-TransportQualitySnapshot $s $now
Check ($q.blipMs -eq 30000 -and $q.hardFailMs -eq 10000) 'upper clamp'
$s=New-TransportQualityState;$null=Network $s 'n1' 'wifi'
$null=Send $s 'light-probe' @{tag='a';probeId='p1';ok=$true;ms=20}
$null=Send $s 'light-probe' @{tag='b';probeId='p2';ok=$true;ms=60}
$published=New-Object Collections.ArrayList
$q=Update-TransportQuality $s 'light-probe' @{id='n1';eventId='light3';tag='a';ok=$true;ms=40} $now {param($topic,$fields)[void]$published.Add(@{topic=$topic;fields=$fields})}
Check ($q.lightP50Ms -eq 40 -and $published.Count -eq 1 -and $published[0].topic -eq 'net.quality') 'median and event publication'
$ignored=Update-TransportQuality $s 'light-probe' @{id='old-network';eventId='old';tag='a';ok=$true;ms=99999} $now
Check ($null -eq $ignored) 'late network result ignored'
$null=Send $s 'probe64' @{tag='a';probeId='p1';ok=$false;ms=800}
$q=Send $s 'probe64' @{tag='b';probeId='p2';ok=$true;ms=1200}
Check (-not $q.tspuSuspect -and $q.tspuRatio -eq 0.5 -and $q.kib64Ms -eq 1200) 'paired ratio and successful 64 KiB measurement'
$null=Send $s 'light-probe' @{tag='a';probeId='p3';ok=$true;ms=25}
$q=Send $s 'probe64' @{tag='a';probeId='p3';ok=$false;ms=800}
Check ($q.tspuSuspect -and $q.status -like '*путь a режется в этой сети*') 'two independent paired failures mark TSPU'
$null=Send $s 'probe64' @{tag='a';probeId='p3';ok=$false;ms=800}
Check ($s.networks.n1.tspu.a.count -eq 2) 'banner proof cannot be reused'
$rows=@([pscustomobject]@{tag='a'},[pscustomobject]@{tag='b'},[pscustomobject]@{tag='c'},[pscustomobject]@{tag='d'})
$order=@(Get-TransportQualityCandidates $s $rows $now)
Check (($order.tag -join ',') -eq 'b,c,d,a') 'TSPU path demoted, stable ordering retained'
$null=Send $s 'episode';$null=Send $s 'episode';$q=Send $s 'episode'
Check ($q.stabilityK -eq 1.5) 'busy network moves only one step towards 2'
$q=Send $s 'episode';Check ($q.stabilityK -eq 2) 'next episode may take next step'
$stability=$q.stabilityK;$q=Send $s 'stall-suspect'
Check ($q.stabilityK -eq $stability -and $q.stalls10m -eq 1) 'measurements do not change hysteresis mid-episode'
$null=Send $s 'switch';$null=Send $s 'switch';$q=Send $s 'switch'
Check ($q.flapping -and -not $q.allowImprovement -and $q.blipMs -eq 30000) 'flapping doubles within clamps and disables improvement'
$round=Get-TransportQualityRound $s $rows 'a' $now
Check ($round.maxParallel -eq 4 -and $round.candidates.Count -eq 4) 'normal round keeps candidates with concurrency cap'
Check (Request-TransportQualityProbe $s 'a' 'a' 'light' $now) 'active light 1'
Check (Request-TransportQualityProbe $s 'a' 'a' 'light' $now) 'active light 2'
Check (Request-TransportQualityProbe $s 'a' 'a' 'light' $now) 'active light 3'
Check (-not (Request-TransportQualityProbe $s 'a' 'a' 'light' $now)) 'active limited to three'
Check (Request-TransportQualityProbe $s 'b' 'a' 'light' $now) 'candidate light 1'
Check (-not (Request-TransportQualityProbe $s 'b' 'a' 'light' $now)) 'candidate limited to one'
Check (Request-TransportQualityProbe $s 'a' 'a' 'post-switch-verify' $now) 'one bulk reservation'
Check (-not (Request-TransportQualityProbe $s 'b' 'a' 'post-switch-verify' $now)) 'bulk limited to one path'
$null=Send $s 'traffic' @{bytes=512*1024}
$round=Get-TransportQualityRound $s $rows 'a' $now
Check (($round.candidates.tag -join ',') -eq 'a,b,c' -and -not $round.postSwitchVerify -and $round.status -like '*64 КиБ пропущена*') 'exhaustion reduces round to active plus two best'
$null=Network $s 'n2' 'mobile-hotspot';$q=Send $s 'episode'
Check (-not $q.tspuSuspect -and $q.budgetKiB -eq 192 -and $q.stabilityK -eq 1) 'new network has separate TSPU and mobile budget'
$q=Network $s 'n1' 'wifi';Check ($q.tspuSuspect) 'network memory restored on return'
$memory=Export-TransportQualityMemory $s $now
$fresh=New-TransportQualityState
Import-TransportQualityMemory $fresh @{n1=[pscustomobject]@{quality=[pscustomobject]@{tspu=[pscustomobject]$memory.n1}}} $now
$q=Network $fresh 'n1' 'wifi';Check ($q.tspuSuspect) 'persisted TSPU imports from JSON-shaped objects'
# Persistence seam captures writes; no files, no Windows, no network or time waits.
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
function Write-TransportJson($Path,$Value,[switch]$Private){$script:written=$Value}
$m=@{networks=@{n1=[pscustomobject]@{candidates=@();quality=@{tspu=$memory.n1}};unseen=@{quality=@{tspu=@{x=@{count=2;until=9999999999L}}}}}}
Save-TransportMemory 'fake-home' $m 'n1' $rows $now
Check ($m.networks.n1.quality.tspu.a.count -eq 2 -and $m.networks.n1.candidates.Count -eq 4) 'candidate saves retain quality metadata'
Save-TransportQualityMemory 'fake-home' $m $fresh $now
Check ($m.networks.n1.candidates.Count -eq 4 -and $m.networks.unseen.quality.tspu.x.count -eq 2) 'quality saves retain candidate history and live unobserved networks'
# Long quiet observation may use the last bulk result after the 10-minute sample window.
$s=New-TransportQualityState;$null=Network $s 'quiet' 'wifi'
$null=Send $s 'probe64' @{ok=$true;ms=1200}
$script:now+=1800000L
$q=Send $s 'episode'
Check ($q.stabilityK -eq 0.6 -and $s.networks.quiet.bulk.Count -eq 0) 'quiet 30-minute path to 0.6 keeps one last bulk result outside rolling window'
# Unpaired and duplicate failures cannot manufacture TSPU evidence.
$s=New-TransportQualityState @{transport=@{switch=@{tspuMemoryHours=1}}};$null=Network $s 'ttl' 'wifi'
$null=Send $s 'probe64' @{tag='unpaired';probeId='absent';ok=$false}
$q=Send $s 'probe64' @{tag='unpaired';probeId='absent';ok=$false}
Check (-not $q.tspuSuspect -and $q.tspuRatio -eq 0 -and $s.networks.ttl.tspu.Count -eq 0) 'unpaired failures do not count'
foreach($i in 1..2){$null=Send $s 'light-probe' @{tag='cut';probeId="ttl$i";ok=$true;ms=10};$q=Send $s 'probe64' @{tag='cut';probeId="ttl$i";ok=$false}}
Check ($q.tspuSuspect) 'custom TSPU duration starts from paired evidence'
$duplicate=@{id='ttl';eventId='repeat';tag='cut';probeId='dup';ok=$true;ms=10}
$null=Update-TransportQuality $s 'light-probe' $duplicate $now
$null=Update-TransportQuality $s 'light-probe' $duplicate $now
Check ($s.networks.ttl.light.Count -eq 3) 'same eventId recorded once'
$null=Update-TransportQuality $s 'episode' @{id='ttl';eventId='ep-repeat'} $now
$null=Update-TransportQuality $s 'episode' @{id='ttl';eventId='ep-repeat'} $now
Check ($s.networks.ttl.events.Count -eq 1) 'episode eventId cannot advance hysteresis twice'
$script:now+=3600000L
$q=Get-TransportQualitySnapshot $s $now
Check (-not $q.tspuSuspect -and $s.networks.ttl.tspu.Count -eq 0) 'tspuMemoryHours expires at fake-clock boundary'
# Budget reservations must fit, and the ten-minute window advances only on input.
$s=New-TransportQualityState @{transport=@{switch=@{probeBudgetKiBPer10m=@{default=2}}}}
$null=Network $s 'budget' 'wifi';$null=Send $s 'episode'
Check (Request-TransportQualityProbe $s 'a' 'a' 'light' $now) 'first light fits budget'
$q=Get-TransportQualitySnapshot $s $now
Check (-not $q.budgetExhausted -and $q.status -like '*64 КиБ пропущена*') 'net.quality reports insufficient verification budget'
Check (Request-TransportQualityProbe $s 'b' 'a' 'light' $now) 'second light reaches budget'
Check (-not (Request-TransportQualityProbe $s 'c' 'a' 'light' $now)) 'light request denied when budget exhausted'
$q=Get-TransportQualitySnapshot $s $now
Check ($q.budgetExhausted -and $q.status -like '*Бюджет проб исчерпан*') 'net.quality publishes exhausted budget status'
$script:now+=600000L
$q=Get-TransportQualitySnapshot $s $now
Check ($q.budgetUsedKiB -eq 0 -and -not $q.budgetExhausted) 'budget reservations expire at moving window boundary'
Check (Request-TransportQualityProbe $s 'c' 'a' 'light' $now) 'denied request did not consume episode attempt'
# Both persistence entry points prune expired blocks across all networks and apply same cap.
$m=@{networks=@{expired=@{lastSeenMs=1;quality=@{tspu=@{x=@{count=2;until=$now}}};candidates=@('history')};live=@{lastSeenMs=2;quality=@{tspu=@{x=@{count=2;until=$now+1}}}}}}
Save-TransportQualityMemory 'fake-home' $m (New-TransportQualityState) $now
Check (-not $written.networks.expired.ContainsKey('quality') -and $written.networks.expired.candidates[0] -eq 'history' -and $written.networks.live.quality.tspu.x.count -eq 2) 'quality save cleans expired unobserved block and retains candidates/live tags'
$m.networks.live.quality.tspu.x.until=$now
Save-TransportMemory 'fake-home' $m 'active' @() $now
Check (-not $written.networks.live.ContainsKey('quality')) 'candidate save also cleans expired unobserved block'
foreach($mode in @('quality','candidate')){
    $m=@{networks=@{}}
    foreach($i in 0..33){$m.networks[('n{0:d2}' -f $i)]=@{lastSeenMs=100;quality=@{tspu=@{x=@{count=2;until=$now+1000}}}}}
    if($mode -eq 'quality'){Save-TransportQualityMemory 'fake-home' $m (New-TransportQualityState) $now}
    else{Save-TransportMemory 'fake-home' $m 'n33' @() $now}
    Check ($written.networks.Count -eq 32 -and -not $written.networks.ContainsKey('n00') -and -not $written.networks.ContainsKey('n01') -and $written.networks.ContainsKey('n33')) "$mode disk cap uses deterministic ordinal tie eviction"
}
$s=New-TransportQualityState
foreach($i in 0..32){$null=Network $s ('n{0:d2}' -f $i) 'wifi'}
Check ($s.networks.Count -eq 32 -and -not $s.networks.ContainsKey('n00')) 'working-set eviction deterministic for equal appearance time'
# A stale Q snapshot must not move a newer candidate appearance backwards.
$s=New-TransportQualityState;$null=Network $s 'recent' 'wifi'
$m=@{networks=@{recent=@{lastSeenMs=$now+100;candidates=@('keep')}}}
Save-TransportQualityMemory 'fake-home' $m $s $now
Check ($written.networks.recent.lastSeenMs -eq $now+100) 'quality save retains newer candidate appearance'
# Old records use updatedAt for migration, not enumeration order or id order.
$m=@{networks=@{}}
foreach($i in 0..32){$m.networks[('n{0:d2}' -f $i)]=@{lastSeenMs=100}}
$m.networks.n00=@{updatedAt='2026-01-01T00:00:00Z';candidates=@('newest')}
Save-TransportQualityMemory 'fake-home' $m (New-TransportQualityState) $now
Check ($written.networks.Count -eq 32 -and $written.networks.ContainsKey('n00') -and -not $written.networks.ContainsKey('n01')) 'latest appearance and legacy updatedAt outrank ordinal tie eviction'
# Import also selects the latest networks independently of input enumeration order.
$m=@{}
foreach($i in 0..33){$m[('n{0:d2}' -f $i)]=@{lastSeenMs=100;quality=@{tspu=@{x=@{count=2;until=$now+1000}}}}}
$s=New-TransportQualityState;Import-TransportQualityMemory $s $m $now
Check ($s.networks.Count -eq 32 -and -not $s.networks.ContainsKey('n00') -and -not $s.networks.ContainsKey('n01')) 'import cap agrees with deterministic disk eviction'
foreach($bad in @(@{blipMs=@{min=20000}},@{stageMs=@(3000,1000)},@{stageMs=@(1000)},@{classK=@{wifi=$true}},@{flapWindowMs=1800001},@{unknown=1})){
    $rejected=$false;try{$null=Get-TransportQualityConfig @{transport=@{switch=$bad}}}catch{$rejected=$true}
    Check $rejected 'invalid quality configuration throws'
}
# Exercise Read-TransportSettings itself with fake JSON and no filesystem/network I/O.
function Read-TransportJson($Path){
    if($Path -like '*config.json'){return @{transport=@{profilePath='profile';channelPath='channel';switch=$script:badSettings}}}
    if($Path -eq 'profile'){return @{sshExecutable='ssh';serverAddress='fixture';login='worker';keyPath='fixture';knownHostsPath='fixture'}}
    return @{}
}
foreach($script:badSettings in @(@{blipMs=@{min=20000}},@{stageMs=@(3000,1000)})){
    $reason='';try{$null=Read-TransportSettings 'fake-home'}catch{$reason=$_.Exception.Message}
    Check ($reason -like 'switch.*') 'runtime settings reject inverted thresholds/stages through Q validator'
}
"PASS: Q quality ($script:checks checks, fake clock and manual events)"
