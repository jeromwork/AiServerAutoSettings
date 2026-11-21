# Q: pure event reducer and probe policy. Dot-source in the daemon; no probes, loops or clocks here.
# Now is Unix milliseconds supplied by the caller. All windows advance only on input events.
function Get-TransportQualityValue($Object,[string]$Name,$Default=$null) {
    if($null -eq $Object){return $Default}
    if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]}}
    elseif($Object.PSObject.Properties[$Name]){return $Object.$Name}
    return $Default
}
function Test-TransportQualityNumber($Value,[double]$Min,[double]$Max,[switch]$Integer) {
    if($Value -is [bool] -or $Value -isnot [ValueType]){return $false}
    $n=[double]$Value
    return $n -ge $Min -and $n -le $Max -and (-not $Integer -or $n -eq [Math]::Floor($n))
}
function Get-TransportQualityConfig($Config=$null) {
    $result=@{
        blipMs=@{default=10000;min=3000;max=30000};hardFailMs=@{default=3000;min=1000;max=10000}
        stageMs=@(1000,3000);classK=@{fixed=0.5;wifi=0.8;'mobile-hotspot'=1.3;mobile=1.5}
        minStayMs=30000;flapWindowMs=600000;flapSwitches=3
        probeBudgetKiBPer10m=@{default=512;mobile=192};tspuMemoryHours=24
    }
    # Public profile overrides legacy runtime settings. A missing switch always means defaults.
    $profile=Get-TransportQualityValue $Config 'profile'
    $transport=Get-TransportQualityValue $profile 'transport' (Get-TransportQualityValue $Config 'transport')
    $source=Get-TransportQualityValue $transport 'switch'
    if($null -ne $source){
        if($source -isnot [Collections.IDictionary] -and $source -isnot [pscustomobject]){throw 'switch must be an object'}
        $names=if($source -is [Collections.IDictionary]){@($source.Keys)}else{@($source.PSObject.Properties.Name)}
        foreach($name in $names){if($name -notin @($result.Keys)+@('stallSeconds','stallConns','hint')){throw "switch.$name unknown"}}
    }
    foreach($name in @($result.Keys)){
        $value=Get-TransportQualityValue $source $name
        if($null -eq $value){continue}
        if($result[$name] -is [Collections.IDictionary]){
            if($value -isnot [Collections.IDictionary] -and $value -isnot [pscustomobject]){throw "switch.$name must be an object"}
            $names=if($value -is [Collections.IDictionary]){@($value.Keys)}else{@($value.PSObject.Properties.Name)}
            foreach($key in $names){if($key -notin @($result[$name].Keys)+@('hint')){throw "switch.${name}.$key unknown"}}
            foreach($key in @($result[$name].Keys)){$v=Get-TransportQualityValue $value $key;if($null -ne $v){$result[$name][$key]=$v}}
        }else{$result[$name]=$value}
    }
    foreach($name in @('blipMs','hardFailMs')){
        $b=$result[$name]
        foreach($v in $b.Values){if(-not (Test-TransportQualityNumber $v 1 300000 -Integer)){throw "switch.$name must contain integers"}}
        if($b.min -lt 1 -or $b.min -gt $b.default -or $b.default -gt $b.max -or $b.max -gt 300000){throw "switch.${name}: min <= default <= max, 1..300000"}
    }
    foreach($v in @($result.stageMs)){if(-not (Test-TransportQualityNumber $v 1 300000 -Integer)){throw 'switch.stageMs must contain integers'}}
    if($result.stageMs -isnot [Array] -or @($result.stageMs).Count -ne 2 -or $result.stageMs[0] -lt 1 -or $result.stageMs[0] -ge $result.stageMs[1] -or $result.stageMs[1] -gt $result.blipMs.default){throw 'switch.stageMs: two increasing stages <= blipMs.default'}
    foreach($k in $result.classK.Values){if(-not (Test-TransportQualityNumber $k 0.01 10)){throw 'switch.classK: 0 < K <= 10'}}
    foreach($item in @(@('minStayMs',3600000),@('flapWindowMs',1800000),@('flapSwitches',1000),@('tspuMemoryHours',720))){if(-not (Test-TransportQualityNumber $result[$item[0]] 1 $item[1] -Integer)){throw "switch.$($item[0]) out of range"}}
    foreach($v in $result.probeBudgetKiBPer10m.Values){if(-not (Test-TransportQualityNumber $v 1 1048576 -Integer)){throw 'switch.probeBudgetKiBPer10m must be positive integers'}}
    return $result
}
function New-TransportQualityState($Config=$null) {
    @{config=(Get-TransportQualityConfig $Config);networks=@{};id='';episode='';attempts=@{};verified=$false}
}
function Get-TransportQualityOldestNetwork($Networks) {
    $old=$null
    foreach($id in $Networks.Keys){
        if($null -eq $old -or $Networks[$id].last -lt $Networks[$old].last -or ($Networks[$id].last -eq $Networks[$old].last -and [string]::CompareOrdinal($id,$old) -lt 0)){$old=$id}
    }
    return $old
}
function Get-TransportQualityNetwork($State,[long]$Now) {
    if(-not $State.id){return $null}
    if(-not $State.networks.ContainsKey($State.id)){
        # Bound working-set growth across roaming networks. Persisted TSPU memory is separate.
        if($State.networks.Count -ge 32){$old=Get-TransportQualityOldestNetwork $State.networks;$State.networks.Remove($old)}
        $State.networks[$State.id]=@{class='unknown';since=$Now;last=$Now;stability=1;lastEpisode='';events=@();light=@();bulk=@();traffic=@();banner=@{};seen=@{};tspu=@{};lastBulk=$null}
    }
    $n=$State.networks[$State.id];$n.last=$Now
    foreach($pair in @(@('events',1800000),@('light',600000),@('bulk',600000),@('traffic',600000))){
        $key=$pair[0];$cut=$Now-[long]$pair[1];$n[$key]=@($n[$key]|Where-Object {$_.at -gt $cut}|Select-Object -Last 4096)
    }
    foreach($tag in @($n.tspu.Keys)){if([long]$n.tspu[$tag].until -le $Now){$n.tspu.Remove($tag)}}
    foreach($key in @($n.banner.Keys)){if($n.banner[$key].at -le $Now-600000){$n.banner.Remove($key)}}
    if($n.seen.Count -gt 4096){foreach($key in @($n.seen.Keys)){if($n.seen[$key] -le $Now-1800000){$n.seen.Remove($key)}}}
    return $n
}
function Get-TransportQualityThresholds($State,[long]$Now) {
    $n=Get-TransportQualityNetwork $State $Now;$c=$State.config;$stability=1.0;$class='unknown';$flap=$false
    if($n){$stability=[double]$n.stability;$class=$n.class;$flap=@($n.events|Where-Object {$_.kind -eq 'switch' -and $_.at -gt $Now-$c.flapWindowMs}).Count -ge $c.flapSwitches}
    $classK=1.0;if($c.classK.ContainsKey($class)){$classK=[double]$c.classK[$class]}
    $factor=$stability*$classK;if($flap){$factor*=2}
    $values=@{}
    foreach($name in @('blipMs','hardFailMs')){$b=$c[$name];$values[$name]=[int][Math]::Round([Math]::Max($b.min,[Math]::Min($b.max,$b.default*$factor)))}
    # stage has no separate min/max in the wire schema: use hardFail's relative bounds.
    $stages=@();foreach($base in $c.stageMs){$low=$base*$c.hardFailMs.min/$c.hardFailMs.default;$high=$base*$c.hardFailMs.max/$c.hardFailMs.default;$stages+=([int][Math]::Round([Math]::Max(1,[Math]::Max($low,[Math]::Min($high,$base*$factor)))))}
    @{blipMs=$values.blipMs;hardFailMs=$values.hardFailMs;stage1Ms=$stages[0];stage2Ms=$stages[1];stabilityK=$stability;classK=$classK;flapping=$flap;allowImprovement=(-not $flap)}
}
function Get-TransportQualitySnapshot($State,[long]$Now) {
    $n=Get-TransportQualityNetwork $State $Now
    $fields=@{id=$State.id;class='unknown';lightP50Ms=$null;kib64Ms=$null;episodes10m=0;switches10m=0;stalls10m=0;tspuSuspect=$false;tspuRatio=0.0;budgetUsedKiB=0;budgetKiB=$State.config.probeBudgetKiBPer10m.default;budgetExhausted=$false;status=''}
    if($n){
        $fields.class=$n.class;$recent=@($n.events|Where-Object {$_.at -gt $Now-600000})
        $fields.episodes10m=@($recent|Where-Object {$_.kind -eq 'episode'}).Count
        $fields.switches10m=@($recent|Where-Object {$_.kind -eq 'switch'}).Count
        $fields.stalls10m=@($recent|Where-Object {$_.kind -eq 'stall-suspect'}).Count
        $light=@($n.light|ForEach-Object {$_.ms}|Sort-Object)
        if($light.Count){$middle=[int][Math]::Floor($light.Count/2);if($light.Count%2){$fields.lightP50Ms=$light[$middle]}else{$fields.lightP50Ms=($light[$middle-1]+$light[$middle])/2.0}}
        $bulk=@($n.bulk|Where-Object {$_.ok});if($bulk.Count){$fields.kib64Ms=$bulk[-1].ms}
        $paired=@($n.bulk|Where-Object {$_.paired});if($paired.Count){$fields.tspuRatio=@($paired|Where-Object {-not $_.ok}).Count/[double]$paired.Count}
        $tags=@($n.tspu.Keys|Where-Object {$n.tspu[$_].count -ge 2}|Sort-Object)
        $fields.tspuSuspect=$tags.Count -gt 0
        $fields.status=($tags|ForEach-Object {"путь $_ режется в этой сети"}) -join '; '
        $used=0L;foreach($t in $n.traffic){$used+=$t.bytes};$fields.budgetUsedKiB=$used/1024.0
        if($n.class -in @('mobile','mobile-hotspot')){$fields.budgetKiB=$State.config.probeBudgetKiBPer10m.mobile}
        $fields.budgetExhausted=$fields.budgetUsedKiB -ge $fields.budgetKiB
        if($fields.budgetExhausted){$fields.status+='; Бюджет проб исчерпан: только активный и два лучших; проверка 64 КиБ пропущена'}
        elseif($fields.budgetUsedKiB+64 -gt $fields.budgetKiB){$fields.status+='; Остатка бюджета недостаточно: проверка 64 КиБ пропущена'}
        $fields.status=$fields.status.TrimStart(';',' ')
    }
    $thresholds=Get-TransportQualityThresholds $State $Now;foreach($key in $thresholds.Keys){$fields[$key]=$thresholds[$key]}
    return $fields
}
function Update-TransportQuality($State,[string]$Kind,$Fields,[long]$Now,[scriptblock]$Publish=$null) {
    if($Kind -eq 'net.change'){
        $id=[string](Get-TransportQualityValue $Fields 'id' '')
        if($State.id -ne $id){$State.id=$id;$State.episode='';$State.attempts=@{};$State.verified=$false}
        $n=Get-TransportQualityNetwork $State $Now
        if($n){$n.class=[string](Get-TransportQualityValue $Fields 'class' $n.class)}
    }else{
        # The generation id is mandatory: late results from a previous network cannot poison this one.
        if(-not $State.id -or [string](Get-TransportQualityValue $Fields 'id' '') -ne $State.id){return}
        $n=Get-TransportQualityNetwork $State $Now
        $tag=[string](Get-TransportQualityValue $Fields 'tag' '')
        $eventId=[string](Get-TransportQualityValue $Fields 'eventId' '')
        if(-not $eventId){throw 'Q requires eventId for measurement/episode deduplication'}
        $dedup=$Kind+'|'+$eventId
        if($n.seen.ContainsKey($dedup)){return}
        # Bound duplicate memory even under a flood; no timed housekeeping job.
        if($n.seen.Count -ge 8192){$old=@($n.seen.Keys|Sort-Object {$n.seen[$_]})[0];$n.seen.Remove($old)}
        $n.seen[$dedup]=$Now
        switch($Kind){
            'episode' {
                $recent=@($n.events|Where-Object {$_.kind -eq 'episode' -and $_.at -gt $Now-600000}).Count
                $past=@($n.events|Where-Object {$_.kind -eq 'episode'}).Count
                $target=1.0
                if($recent+1 -ge 3){$target=1.5;if(@($n.tspu.Values|Where-Object {$_.count -ge 2}).Count){$target=2.0}}
                elseif($past -eq 0 -and $Now-$n.since -ge 1800000 -and $n.lastBulk -and $n.lastBulk.ok -and $n.lastBulk.ms -lt 1500){$target=0.6}
                $steps=@(0.6,1.0,1.5,2.0);$from=[Array]::IndexOf($steps,[double]$n.stability);$to=[Array]::IndexOf($steps,[double]$target)
                $n.stability=$steps[$from+[Math]::Sign($to-$from)]
                $n.lastEpisode=$eventId;$State.episode=$eventId;$State.attempts=@{};$State.verified=$false
                $n.events+=@{kind='episode';at=$Now}
            }
            'switch' {$n.events+=@{kind='switch';at=$Now}}
            'stall-suspect' {$n.events+=@{kind='stall-suspect';at=$Now}}
            'light-probe' {
                $ok=(Get-TransportQualityValue $Fields 'ok' $false) -eq $true
                $ms=[double](Get-TransportQualityValue $Fields 'ms' 0)
                if($ok -and $ms -ge 0){$n.light+=@{at=$Now;ms=$ms}}
                $probeId=[string](Get-TransportQualityValue $Fields 'probeId' '')
                if($probeId -and $tag){
                    if($n.banner.Count -ge 4096){$old=@($n.banner.Keys|Sort-Object {$n.banner[$_].at})[0];$n.banner.Remove($old)}
                    $n.banner[$probeId]=@{tag=$tag;ok=$ok;at=$Now}
                }
            }
            'probe64' {
                $ok=(Get-TransportQualityValue $Fields 'ok' $false) -eq $true
                $ms=[double](Get-TransportQualityValue $Fields 'ms' 0);$probeId=[string](Get-TransportQualityValue $Fields 'probeId' '')
                $paired=$probeId -and $n.banner.ContainsKey($probeId) -and $n.banner[$probeId].ok -and $n.banner[$probeId].tag -eq $tag
                # Consume the banner proof once, even if a bulk result is repeated with a new eventId.
                if($probeId){$n.banner.Remove($probeId)}
                $n.lastBulk=@{at=$Now;ok=$ok;ms=$ms};$n.bulk+=@{at=$Now;ok=$ok;ms=$ms;paired=[bool]$paired}
                if($paired -and -not $ok){
                    if(-not $n.tspu.ContainsKey($tag)){$n.tspu[$tag]=@{count=0;until=0L}}
                    $n.tspu[$tag].count++;$n.tspu[$tag].until=$Now+[long]($State.config.tspuMemoryHours*3600000)
                }
            }
            'traffic' {
                $bytes=[long](Get-TransportQualityValue $Fields 'bytes' 0)
                if($bytes -lt 0){throw 'Q traffic bytes cannot be negative'}
                $n.traffic+=@{at=$Now;bytes=$bytes}
            }
            default {return}
        }
    }
    $snapshot=Get-TransportQualitySnapshot $State $Now
    if($Publish){& $Publish 'net.quality' $snapshot|Out-Null}
    return $snapshot
}
function Get-TransportQualityCandidates($State,$Candidates,[long]$Now) {
    $n=Get-TransportQualityNetwork $State $Now
    # Stable partition: retain the caller's penalty/performance ordering within both groups.
    @($Candidates|Where-Object {-not ($n -and $n.tspu.ContainsKey([string]$_.tag) -and $n.tspu[[string]$_.tag].count -ge 2)})+
        @($Candidates|Where-Object {$n -and $n.tspu.ContainsKey([string]$_.tag) -and $n.tspu[[string]$_.tag].count -ge 2})
}
function Get-TransportQualityRound($State,$Candidates,[string]$Active,[long]$Now) {
    $snapshot=Get-TransportQualitySnapshot $State $Now
    $ranked=@(Get-TransportQualityCandidates $State $Candidates $Now)
    if($snapshot.budgetExhausted){$ranked=@($ranked|Where-Object {$_.tag -eq $Active})+@($ranked|Where-Object {$_.tag -ne $Active}|Select-Object -First 2)}
    $verify=$snapshot.budgetUsedKiB+64 -le $snapshot.budgetKiB
    $status=''
    if($snapshot.budgetExhausted){$status='Бюджет проб исчерпан: только активный и два лучших; проверка 64 КиБ пропущена'}
    elseif(-not $verify){$status='Остатка бюджета недостаточно: проверка 64 КиБ пропущена'}
    @{candidates=$ranked;maxParallel=4;postSwitchVerify=$verify;status=$status}
}
function Request-TransportQualityProbe($State,[string]$Tag,[string]$Active,[string]$Purpose,[long]$Now) {
    if(-not $State.episode -or -not $State.id){return $false}
    $snapshot=Get-TransportQualitySnapshot $State $Now
    if($Purpose -eq 'post-switch-verify'){
        if($State.verified -or $snapshot.budgetUsedKiB+64 -gt $snapshot.budgetKiB){return $false}
        $State.verified=$true;$bytes=65536
    }elseif($Purpose -eq 'light'){
        if($snapshot.budgetUsedKiB+1 -gt $snapshot.budgetKiB){return $false}
        $count=0;if($State.attempts.ContainsKey($Tag)){$count=[int]$State.attempts[$Tag]}
        $limit=1;if($Tag -eq $Active){$limit=3}
        if($count -ge $limit){return $false};$State.attempts[$Tag]=$count+1;$bytes=1024
    }else{return $false}
    $n=Get-TransportQualityNetwork $State $Now
    # Reserve expected bytes before I/O so concurrent starts cannot overspend the budget.
    $n.traffic+=@{at=$Now;bytes=$bytes}
    return $true
}
function Export-TransportQualityMemory($State,[long]$Now) {
    $result=@{}
    foreach($id in @($State.networks.Keys)){
        $entries=@{}
        foreach($tag in @($State.networks[$id].tspu.Keys)){
            $v=$State.networks[$id].tspu[$tag]
            if($v.until -gt $Now){$entries[$tag]=@{count=$v.count;until=$v.until}}
        }
        if($entries.Count){$result[$id]=$entries}
    }
    return $result
}
function Import-TransportQualityMemory($State,$Networks,[long]$Now) {
    # Call once after Read-TransportMemory. Each network stores quality.tspu alongside candidates.
    $previous=$State.id;$loaded=@{}
    foreach($id in @($Networks.Keys)){
        $saved=Get-TransportQualityValue (Get-TransportQualityValue $Networks $id) 'quality'
        $saved=Get-TransportQualityValue $saved 'tspu'
        if(-not $saved){continue}
        $n=@{tspu=@{};last=0L}
        $record=Get-TransportQualityValue $Networks $id
        $n.last=[long](Get-TransportQualityValue $record 'lastSeenMs' 0)
        if($null -eq (Get-TransportQualityValue $record 'lastSeenMs')){
            $date=[DateTimeOffset]::MinValue
            if([DateTimeOffset]::TryParse([string](Get-TransportQualityValue $record 'updatedAt' ''),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$date)){$n.last=$date.ToUnixTimeMilliseconds()}
        }
        $keys=if($saved -is [Collections.IDictionary]){@($saved.Keys)}else{@($saved.PSObject.Properties.Name)}
        foreach($tag in $keys){$v=Get-TransportQualityValue $saved $tag;$until=[long](Get-TransportQualityValue $v 'until' 0);$count=[int](Get-TransportQualityValue $v 'count' 0);if($until -gt $Now -and $count -gt 0){$n.tspu[$tag]=@{count=$count;until=$until}}}
        if($n.tspu.Count){$loaded[$id]=$n}
        if($loaded.Count -gt 32){$loaded.Remove((Get-TransportQualityOldestNetwork $loaded))}
    }
    foreach($id in $loaded.Keys){$State.id=$id;$n=Get-TransportQualityNetwork $State $Now;$n.tspu=$loaded[$id].tspu;$n.last=$loaded[$id].last}
    $State.id=$previous
}
function Save-TransportQualityMemory([string]$Root,$Memory,$State,[long]$Now) {
    $export=Export-TransportQualityMemory $State $Now
    # Retain candidate history and other network metadata owned by the daemon.
    foreach($id in @($State.networks.Keys)){
        if(-not $Memory.networks.ContainsKey($id)){continue}
        $record=$Memory.networks[$id]
        $quality=@{tspu=(Get-TransportQualityValue $export $id @{})}
        $last=[Math]::Max([long](Get-TransportMemoryLastSeen $record),[long]$State.networks[$id].last)
        if($record -is [Collections.IDictionary]){$record['quality']=$quality;$record['lastSeenMs']=$last}
        else{$record|Add-Member -Force -NotePropertyName quality -NotePropertyValue $quality;$record|Add-Member -Force -NotePropertyName lastSeenMs -NotePropertyValue $last}
    }
    foreach($id in @($export.Keys)){if(-not $Memory.networks.ContainsKey($id)){$Memory.networks[$id]=@{quality=@{tspu=$export[$id]};candidates=@();lastSeenMs=$State.networks[$id].last}}}
    Limit-TransportMemory $Memory $Now
    Write-TransportJson (Join-Path $Root 'state/transport-memory.json') $Memory -Private
}
