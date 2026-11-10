#requires -Version 5.1
[CmdletBinding()]
param([Alias('Home')][string]$TransportHome=(Join-Path $env:LOCALAPPDATA 'RemoteAgents'),[int]$ParentPid=0)
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
$root=(Get-TransportHome $TransportHome);$engine=$null;$tunnelChildren=@{};$probes=@{};$rows=@();$active=$null;$confirmed=$false;$errorText='Запуск';$network=$null;$memory=$null;$secret=$null
$parent=$null;$mutex=$null;$locked=$false;$settings=$null;$paths=$null;$rankPending=$false;$rankTags=@();$rankQueue=$null;$exitCode=0
$pin=[pscustomobject]@{mode='auto';tag=$null};$nextControl=[DateTime]::MinValue;$revision='';$reloadJob=$null;$reloadError=$null;$failedRevision=$null;$pendingRevision=$null;$nextReload=[DateTime]::MinValue
$diagnosticContext=$null
$lastStatus=[DateTime]::MinValue;$nextActive=[DateTime]::MinValue;$nextRank=[DateTime]::MinValue;$nextNetwork=[DateTime]::MinValue;$retryAt=[DateTime]::MinValue
function Test-TransportStop {
    try{if([IO.File]::Exists((Join-Path $root 'stop')) -or [IO.File]::Exists((Join-Path $root 'state/transport.stop'))){return $true}}catch{}
    if($parent){try{return $parent.HasExited}catch{return $true}};return $false
}
function Stop-TransportProbes {
    foreach($probe in @($probes.Values)){Stop-TransportProbe $probe};$probes.Clear()
}
function Publish-TransportStatus {
    $speed=$null;$row=$rows|Where-Object {$_.tag -eq $active}|Select-Object -First 1
    if($confirmed -and $row){$speed=$row.kbps}
    $alive=$false;if($engine){try{$alive=-not $engine.Process.HasExited}catch{}}
    $id=$null;if($network){$id=$network.id}
    $summary='нет связи: '+$(if($errorText){$errorText}else{'нет проверенного пути'})
    if($alive -and $confirmed -and $row){$summary=$row.title;if($null -ne $speed){$summary+=' · '+([Math]::Round([double]$speed,1)).ToString([Globalization.CultureInfo]::InvariantCulture)+' КБ/с'}}
    Write-TransportJson (Join-Path $root 'status/transport.json') ([ordered]@{configRevision=$revision;summary=$summary;ok=[bool]($alive -and $confirmed);active=$active;kbps=$speed;network=$id;metered=$metered;mode=$pin.mode;pinnedTag=$pin.tag;candidates=@($rows);configError=$reloadError;updatedAt=[DateTime]::UtcNow.ToString('o');error=$errorText})
    $script:lastStatus=[DateTime]::UtcNow
}
function Switch-TransportActive([string]$Tag,[bool]$Verified) {
    if($pin.mode -eq 'pinned' -and $Tag -ne $pin.tag){return $false}
    if(-not $Tag){$script:confirmed=$false;$script:errorText='Нет проверенного пути';return $false}
    try{
        $target=$Tag;if($Tag -notin @($paths.Candidates|ForEach-Object {$_.tag})){$target='unavailable';$Verified=$false}
        Set-TransportSelector $settings.Options $secret $target
        $script:active=$Tag;$script:confirmed=$Verified;$script:nextActive=[DateTime]::UtcNow
        if($Verified){$script:errorText=$null}elseif($pin.mode -eq 'pinned'){$script:errorText='Закреплённый путь ещё не проверен или недоступен'}else{$script:errorText='Путь из памяти ещё не проверен'}
        Write-TransportLog $root 'switch';return $true
    }catch{$script:confirmed=$false;$script:errorText='Не удалось переключить selector';Write-TransportLog $root 'api-failed' (Get-TransportErrorDetail $_);return $false}
}
function Fail-TransportActive([bool]$RequestRank=$true) {
    $script:confirmed=$false;$script:errorText='Активный путь не прошёл пробу или завершился'
    if($pin.mode -eq 'pinned'){$script:errorText='Закреплённый путь не работает';return}
    $best=Get-TransportBest $rows
    if($best){[void](Switch-TransportActive $best.tag $true)}else{
        $best=Get-TransportBest $rows -Remembered
        if($best){[void](Switch-TransportActive $best.tag $false)}
    }
    if($RequestRank){$script:nextRank=[DateTime]::UtcNow}
}
function Start-DaemonProbe($Candidate,[long]$Bytes,[string]$Purpose) {
    if($probes.ContainsKey($Candidate.tag)){return}
    try{$probes[$Candidate.tag]=Start-TransportProbe $settings.Profile $Candidate $Bytes $settings.Options $Purpose}
    catch{
        $row=$rows|Where-Object {$_.tag -eq $Candidate.tag}|Select-Object -First 1;$row.state='fail';$row.kbps=$null;$row.checkedAt=[DateTime]::UtcNow.ToString('o')
        if($Candidate.tag -eq $active){Fail-TransportActive (-not $rankPending)}
        $detail=New-TransportDiagnostic $null $Candidate.tag 'probe-start-failed'
        $row|Add-Member -Force diagnostic $detail
        Write-TransportLog $root 'process-failed' $detail
    }
}
function Start-TransportRanking {
    $tags=@(Get-TransportRankTags $rows $paths.Candidates $settings.Options $metered)
    # Пути проверяются по очереди (rankConcurrency, по умолчанию 1): параллельные пробы делят один канал
    # и показывают долю канала, а не скорость пути.
    $script:rankTags=$tags;$script:rankPending=$true
    $script:rankQueue=New-Object Collections.Queue
    foreach($c in $paths.Candidates){if($c.tag -in $tags){$script:rankQueue.Enqueue($c)}}
    Start-TransportRankNext
}
function Start-TransportRankNext {
    while($script:rankQueue -and $script:rankQueue.Count -gt 0 -and @($probes.Values|Where-Object {$_.purpose -eq 'rank'}).Count -lt [int]$settings.Options.rankConcurrency){
        $c=$script:rankQueue.Dequeue()
        if($probes.ContainsKey($c.tag)){Stop-TransportProbe $probes[$c.tag];$probes.Remove($c.tag)}
        Start-DaemonProbe $c ([long]$settings.Options.rankProbeBytes) 'rank'
    }
    $script:nextRank=[DateTime]::UtcNow.AddSeconds([double]$settings.Options.rankIntervalSec)
}
function Start-TransportEngine([switch]$Validated) {
    $script:confirmed=$false
    $interface='';if($network -and $settings.Options.bindPhysical){$interface=[string]$network.interface}
    if($settings.Options.bindPhysical -and -not $interface){throw 'Физический интерфейс недоступен'}
    $cfg=New-TransportConfig $settings $paths $secret $active $interface
    $file=Join-Path $root 'state/transport-sing-box.json';Write-TransportJson $file $cfg -Private
    # Валидация до запуска; stdout/stderr не публикуются, т.к. могут содержать адреса и секреты.
    if(-not $Validated){Test-TransportConfigFile $settings.Options.singBoxPath $file}
    $script:engine=Start-TransportProcess $settings.Options.singBoxPath @('run','-c',$file)
    Save-TransportOwner $root 'transport' $engine $settings.Options.singBoxPath $file
    foreach($tunnel in $paths.Tunnels){
        if($tunnelChildren.ContainsKey($tunnel.tag)){continue}
        $a=@($tunnel.arguments)
        if($settings.Options.bindPhysical -and $tunnel.bind){if(-not $network.ip){throw 'Нет физического IPv4 для OpenSSH'};$a+=@('-b',[string]$network.ip)}
        $script:tunnelChildren[$tunnel.tag]=Start-TransportProcess $settings.Profile.sshExecutable ($a+@([string]$tunnel.target))
    }
    $script:nextRank=[DateTime]::UtcNow.AddSeconds(1);$script:nextActive=[DateTime]::UtcNow.AddSeconds(1);Write-TransportLog $root 'ready'
}
$metered=$null
try{
    [void][IO.Directory]::CreateDirectory($root)
    # Имя mutex зависит только от Home, не от серверных адресов. Второй экземпляр не портит статус первого.
    $hash=Get-TransportFingerprint 'local' $root.ToLowerInvariant();$mutex=New-Object Threading.Mutex($false,('Global\RemoteAgentsTransport-'+$hash))
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'Транспорт уже запущен'}
    Write-TransportLog $root 'start'
    if($ParentPid -gt 0){$parent=[Diagnostics.Process]::GetProcessById($ParentPid);[void]$parent.Handle}
    $settings=Read-TransportSettings $root;Sync-TransportEntryCache $settings $root;$paths=Get-TransportCandidates $settings $root;$secret=Get-TransportSecret $root;$memory=Read-TransportMemory $root
    $diagnosticContext=@(Get-TransportDiagnosticContext $settings $root)
    $network=Get-TransportNetwork;$metered=Get-TransportMetered $settings.Options
    $rows=@(Get-TransportRemembered $memory $network.id $paths.AllCandidates)
    $pin=Read-TransportPin $root;$active=Get-TransportSelection $pin $rows $paths.Candidates;$revision=Get-TransportRevision $root
    Publish-TransportStatus
    while(-not (Test-TransportStop)){
        $now=[DateTime]::UtcNow
        # Короткий управляющий цикл: pin не ждёт сетевых проб или SSH -G при reload.
        if($now -ge $nextControl){
            $nextControl=$now.AddSeconds(1)
            try{$newPin=Read-TransportPin $root}catch{$newPin=[pscustomobject]@{mode='pinned';tag='invalid-pin'}; $errorText='Неверный transport-pin.json'}
            if($newPin.mode -ne $pin.mode -or $newPin.tag -ne $pin.tag -or ($newPin.mode -eq 'pinned' -and $active -ne $newPin.tag)){
                $pin=$newPin;$desired=Get-TransportSelection $pin $rows $paths.Candidates $active
                $row=$rows|Where-Object {$_.tag -eq $desired}|Select-Object -First 1
                if($engine){[void](Switch-TransportActive $desired ([bool]($row -and $row.state -eq 'ok')))}else{$active=$desired;$confirmed=$false}
                $nextActive=$now;$nextRank=$now
            }
            if(-not $reloadJob -and $now -ge $nextReload){
                try{
                    $newRevision=Get-TransportRevision $root
                    if($newRevision -eq $revision){$reloadError=$null}
                    if($newRevision -ne $revision){
                        $pendingRevision=$newRevision
                        $reloadJob=Start-Job -ArgumentList $PSScriptRoot,$root,$secret,$network.interface,$newRevision -ScriptBlock {
                            param($scripts,$homeRoot,$apiSecret,$nic,$rev)
                            . (Join-Path $scripts 'Transport.Common.ps1')
                            $newSettings=Read-TransportSettings $homeRoot;Sync-TransportEntryCache $newSettings $homeRoot;$stableRevision=Get-TransportRevision $homeRoot;$newSettings=Read-TransportSettings $homeRoot;$newPaths=Get-TransportCandidates $newSettings $homeRoot
                            $newConfig=New-TransportConfig $newSettings $newPaths $apiSecret 'unavailable' $nic
                            $checkFile=Join-Path $homeRoot 'state/transport-pending.json';Write-TransportJson $checkFile $newConfig -Private
                            Test-TransportConfigFile $newSettings.Options.singBoxPath $checkFile
                            if((Get-TransportRevision $homeRoot) -ne $stableRevision){throw 'Конфиг изменился во время проверки'}
                            [pscustomobject]@{Settings=$newSettings;Paths=$newPaths;Revision=$stableRevision}
                        }
                    }
                }catch{$reloadError='Изменённый конфиг не прочитан; сохранена рабочая конфигурация'}
            }
        }
        if($reloadJob -and $reloadJob.State -in @('Completed','Failed','Stopped')){
            try{
                $result=Receive-Job $reloadJob -ErrorAction Stop
                if(-not $result -or $reloadJob.State -ne 'Completed'){throw 'Reload failed'}
                Stop-TransportProbes;$rankPending=$false;$rankQueue=$null
                # Сохраняем неизменившиеся SSH -D; только изменённые/удалённые туннели закрываются.
                foreach($tag in @($tunnelChildren.Keys)){
                    $old=$paths.Tunnels|Where-Object {$_.tag -eq $tag}|Select-Object -First 1
                    $new=$result.Paths.Tunnels|Where-Object {$_.tag -eq $tag}|Select-Object -First 1
                    if(-not $new -or (ConvertTo-Json $old -Compress -Depth 20) -ne (ConvertTo-Json $new -Compress -Depth 20)){
                        Stop-TransportProcess $tunnelChildren[$tag];$tunnelChildren.Remove($tag)
                    }
                }
                Stop-TransportProcess $engine;$engine=$null;$settings=$result.Settings;$paths=$result.Paths;$revision=$result.Revision
                $diagnosticContext=@(Get-TransportDiagnosticContext $settings $root)
                $rows=@(Get-TransportRemembered $memory $network.id $paths.AllCandidates)
                $active=Get-TransportSelection $pin $rows $paths.Candidates $active;$confirmed=$false;$retryAt=$now
                Start-TransportEngine -Validated;$reloadError=$null;$errorText='Конфиг применён; ожидается проверка пути'
                Write-TransportLog $root 'restart'
            }catch{$reloadError='Новый конфиг не применён; проверьте списки узлов и кэш секретов';$nextReload=[DateTime]::UtcNow.AddSeconds(5)}
            finally{Remove-Job $reloadJob -Force;$reloadJob=$null}
        }
        if($now -ge $nextNetwork){
            $nextNetwork=$now.AddSeconds(5);$newNetwork=Get-TransportNetwork;$newMetered=Get-TransportMetered $settings.Options
            $changed=($newNetwork.id -ne $network.id -or $newNetwork.interface -ne $network.interface -or $newNetwork.ip -ne $network.ip)
            $costChanged=($newMetered -ne $metered);$metered=$newMetered
            if($changed){
                Stop-TransportProbes;$rankPending=$false;$rankQueue=$null;$network=$newNetwork
                $rows=@(Get-TransportRemembered $memory $network.id $paths.AllCandidates);$confirmed=$false
                $best=Get-TransportBest $rows -Remembered
                if($best -and $pin.mode -eq 'auto'){
                    if($engine -and -not $settings.Options.bindPhysical){[void](Switch-TransportActive $best.tag $false)}
                    else{$active=$best.tag;$errorText='Путь из памяти ещё не проверен'}
                }
                $nextRank=$now;$nextActive=$now;Write-TransportLog $root 'network-change'
                # bind_interface и OpenSSH -b задаются на сокете. При смене NIC нужен новый процесс;
                # обычный failover selector никогда не перезапускает sing-box.
                if($settings.Options.bindPhysical){
                    Stop-TransportProcess $engine;$engine=$null
                    foreach($child in @($tunnelChildren.Values)){Stop-TransportProcess $child};$tunnelChildren.Clear();$retryAt=$now
                }
                if(-not $newNetwork.available){$errorText='Не удалось определить физическую сеть';Write-TransportLog $root 'network-unavailable'}
            }elseif($costChanged){Stop-TransportProbes;$rankPending=$false;$rankQueue=$null;$nextRank=$now;$nextActive=$now}
        }
        if($engine -and $engine.Process.HasExited){
            $detail=New-TransportDiagnostic $engine 'sing-box' 'process-exited' $diagnosticContext
            Write-TransportLog $root 'process-failed' $detail
            foreach($row in $rows){if($row.enabled){$perRow=Copy-TransportObject $detail;$perRow.candidate=$row.tag;$row|Add-Member -Force diagnostic $perRow}}
            Stop-TransportProbes;$rankPending=$false;$rankQueue=$null;Stop-TransportProcess $engine;$engine=$null;$confirmed=$false;$errorText='sing-box завершился, ожидается перезапуск'
            foreach($child in @($tunnelChildren.Values)){Stop-TransportProcess $child};$tunnelChildren.Clear()
            foreach($row in $rows){if($row.state -eq 'ok'){$row.state='remembered'}}
            $retryAt=$now.AddSeconds([double]$settings.Options.restartDelaySec);Write-TransportLog $root 'restart'
        }
        if(-not $engine -and $now -ge $retryAt){
            try{Start-TransportEngine;$errorText='Ожидается проверка пути'}
            catch{
                $detail=$_.Exception.Data['transportDiagnostic']
                if(-not $detail){$detail=New-TransportDiagnostic $null 'sing-box' 'engine-start-failed'}
                $detail.stderr=Protect-TransportDiagnostic $detail.stderr $diagnosticContext
                foreach($row in $rows){if($row.enabled){$perRow=Copy-TransportObject $detail;$perRow.candidate=$row.tag;$row|Add-Member -Force diagnostic $perRow}}
                Write-TransportLog $root 'process-failed' $detail
                Stop-TransportProcess $engine;$engine=$null;foreach($child in @($tunnelChildren.Values)){Stop-TransportProcess $child};$tunnelChildren.Clear()
                $confirmed=$false;$errorText='Не удалось запустить транспорт; проверьте конфиг и физическую сеть'
                $retryAt=$now.AddSeconds([double]$settings.Options.restartDelaySec)
            }
        }
        if($engine){
            foreach($tunnel in $paths.Tunnels){
                if($tunnelChildren.ContainsKey($tunnel.tag) -and $tunnelChildren[$tunnel.tag].Process.HasExited){
                    $detail=New-TransportDiagnostic $tunnelChildren[$tunnel.tag] $tunnel.tag 'process-exited' $diagnosticContext
                    Write-TransportLog $root 'process-failed' $detail
                    Stop-TransportProcess $tunnelChildren[$tunnel.tag];$tunnelChildren.Remove($tunnel.tag)
                    $row=$rows|Where-Object {$_.tag -eq $tunnel.tag}|Select-Object -First 1;$row.state='fail';$row.kbps=$null;$row|Add-Member -Force diagnostic $detail
                    if($active -eq $tunnel.tag){Fail-TransportActive}
                }
                if(-not $tunnelChildren.ContainsKey($tunnel.tag) -and $now -ge $retryAt){
                    try{$a=@($tunnel.arguments);if($settings.Options.bindPhysical -and $tunnel.bind){$a+=@('-b',[string]$network.ip)};$tunnelChildren[$tunnel.tag]=Start-TransportProcess $settings.Profile.sshExecutable ($a+@($tunnel.target))}catch{Write-TransportLog $root 'process-failed' (New-TransportDiagnostic $null $tunnel.tag 'tunnel-start-failed')}
                    $retryAt=$now.AddSeconds([double]$settings.Options.restartDelaySec)
                }
            }
            foreach($tag in @($probes.Keys)){
                $probe=$probes[$tag]
                if(Receive-TransportProbe $probe){
                    $result=$probe.state;$row=$rows|Where-Object {$_.tag -eq $tag}|Select-Object -First 1
                    # Скорость задаёт рейтинг (равные объёмы); проба активного пути меньше и только подтверждает живость.
                    $row.state=$result.state;if($probe.purpose -ne 'active' -or $result.state -ne 'ok' -or $null -eq $row.kbps){$row.kbps=$result.kbps};$row.checkedAt=$now.ToString('o')
                    $detail=New-TransportDiagnostic $probe.child $tag $result.diagnostic.reason $diagnosticContext
                    if($result.state -ne 'ok'){
                        $underlying=Get-TransportEngineDiagnostic $engine $tag $diagnosticContext
                        if($underlying){$detail|Add-Member engineStderr $underlying.stderr;$detail.reason=$underlying.reason}
                    }
                    $row|Add-Member -Force diagnostic $detail
                    Stop-TransportProbe $probe;$probes.Remove($tag)
                    if($result.state -eq 'ok'){
                        Write-TransportLog $root 'probe-ok' $detail
                        if($tag -eq $active){$confirmed=$true;$errorText=$null}
                        elseif(-not $confirmed){[void](Switch-TransportActive $tag $true)}
                    }else{
                        Write-TransportLog $root 'probe-failed' $detail
                        if($tag -eq $active){
                            Fail-TransportActive ($probe.purpose -eq 'active' -or -not $rankPending)
                        }
                    }
                    Save-TransportMemory $root $memory $network.id $rows
                }
            }
            if($rankPending){Start-TransportRankNext}
            if($rankPending -and @($probes.Values|Where-Object {$_.purpose -eq 'rank'}).Count -eq 0 -and (-not $rankQueue -or $rankQueue.Count -eq 0)){
                $rankPending=$false;$best=Get-TransportBest $rows $rankTags
                if($best -and $best.tag -ne $active){[void](Switch-TransportActive $best.tag $true)}
                Save-TransportMemory $root $memory $network.id $rows
            }
            if(-not $rankPending -and $now -ge $nextRank){Start-TransportRanking}
            if($active -and $active -in @($paths.Candidates|ForEach-Object {$_.tag}) -and $now -ge $nextActive -and -not $probes.ContainsKey($active)){
                $c=$paths.Candidates|Where-Object {$_.tag -eq $active}|Select-Object -First 1
                Start-DaemonProbe $c ([long]$settings.Options.activeProbeBytes) 'active'
                $interval=$settings.Options.activeIntervalSec;if($metered -ne $false){$interval=$settings.Options.meteredActiveIntervalSec};$nextActive=$now.AddSeconds([double]$interval)
            }
        }
        if($pin.mode -eq 'pinned' -and $pin.tag -notin @($paths.Candidates|ForEach-Object {$_.tag})){$confirmed=$false;$errorText='Закреплённый путь не работает: отключён или отсутствует'}
        if(($now-$lastStatus).TotalSeconds -ge 1){Publish-TransportStatus};Start-Sleep -Milliseconds 300
    }
    $errorText='Транспорт остановлен'
}catch{
    $exitCode=1
    # Текст чужого исключения может содержать адрес/пароль — публикуем только категорию.
    $errorText='Ошибка транспорта: проверьте настройки, файлы профиля и бинарные файлы'
    if($locked){Write-TransportLog $root 'fatal' (Get-TransportErrorDetail $_);Write-TransportLog $root 'process-failed' (New-TransportDiagnostic $null 'transport' 'initialization-failed')}else{Write-Error 'Транспорт уже запущен или блокировка недоступна' -ErrorAction Continue}
}finally{
    if($reloadJob){Stop-Job $reloadJob;Remove-Job $reloadJob -Force}
    Stop-TransportProbes
    foreach($child in @($tunnelChildren.Values)){Stop-TransportProcess $child};Stop-TransportProcess $engine;$engine=$null;$confirmed=$false
    if($locked){try{Publish-TransportStatus;Write-TransportLog $root 'stop'}finally{$mutex.ReleaseMutex()}}
    if($mutex){$mutex.Dispose()};if($parent){$parent.Dispose()}
}

exit $exitCode
