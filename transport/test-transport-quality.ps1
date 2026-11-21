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
Save-TransportMemory 'fake-home' $m 'n1' $rows
Check ($m.networks.n1.quality.tspu.a.count -eq 2 -and $m.networks.n1.candidates.Count -eq 4) 'candidate saves retain quality metadata'
Save-TransportQualityMemory 'fake-home' $m $fresh $now
Check ($m.networks.n1.candidates.Count -eq 4 -and $m.networks.unseen.quality.tspu.x.count -eq 2) 'quality saves retain candidate history and unobserved networks'
"PASS: Q quality ($script:checks checks, fake clock and manual events)"
