#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Transport.Decide.ps1')
. (Join-Path $PSScriptRoot 'Transport.Quality.ps1')

$count=0
function Assert($Condition,[string]$Message) {
    if(-not $Condition){throw ('Тест переключения: '+$Message)}
    $script:count++
}

function Row([string]$Tag,[string]$Health='ok',[double]$Latency=100,[int]$Failures=0,[double]$Gap=0) {
    return @{tag=$Tag;state=$Health;enabled=$true;latencyMs=$Latency;failures=$Failures;maxGapMs=$Gap}
}

function Event([long]$At,[string]$Kind,[string]$Tag='a',[string]$Code='timeout',[bool]$Local=$false) {
    return @{at=$At;kind=$Kind;tag=$Tag;code=$Code;local=$Local;detail='test-detail'}
}

function DecideSwitch($State,[long]$Now,$Events=@(),$Rows=@((Row 'a'),(Row 'b' 'remembered' 120)),[string]$Current='a',$Config=$null) {
    return Invoke-TransportDecision -SwitchEpisode:$true -State $State -Candidates $Rows -Now $Now -Events $Events -CurrentTag $Current -SwitchConfig $Config
}

# Контракт фактических вызовов демона до T2: State/Invoke без SwitchEpisode.
# none — нейтральный вердикт; все действия исполняются текущим демоном.
$legacyActions=@('none','check-direct','check-path','switch','searching')
$daemonRows=@((Row 'a'),(Row 'b' 'remembered' 120))
$daemonState=New-TransportDecisionState -Now 0 -CurrentTag 'a'
$daemonResult=Invoke-TransportDecision -State $daemonState -Candidates $daemonRows -CurrentTag 'a' -Now 1 -Events @((Event 1 'stall-suspect'))
Assert ($daemonResult.verdict.action -eq 'check-path') 'D: сигнал просит исполняемый демоном check-path по умолчанию'
$daemonResults=@($daemonResult)
$daemonResult=Invoke-TransportDecision -State $daemonResult.state -Candidates $daemonRows -CurrentTag 'a' -Now 2 -Events @((Event 2 'path-check' 'a' 'timeout'))
Assert ($daemonResult.verdict.action -eq 'check-direct') 'D: провал path-check просит check-direct, а не probe-round'
$daemonResults+=@($daemonResult)
$daemonResult=Invoke-TransportDecision -State $daemonResult.state -Candidates $daemonRows -CurrentTag 'a' -Now 3 -Events @((Event 3 'net-up' ''))
Assert ($daemonResult.verdict.action -eq 'switch' -and $daemonResult.verdict.tag -eq 'b') 'D: подтверждённая сеть разрешает legacy switch'
$daemonResults+=@($daemonResult)
# Confirm-DaemonSelection не передаёт даже Events; затем приходит transport.switch.
$daemonResult=Invoke-TransportDecision -State $daemonResult.state -Candidates $daemonRows -CurrentTag 'b' -Now 4
$daemonResults+=@($daemonResult)
$daemonResult=Invoke-TransportDecision -State $daemonResult.state -Candidates $daemonRows -CurrentTag 'b' -Now 5 -Events @(@{kind='transport.switch';at=5;from='a';to='b';changed=$true})
$daemonResults+=@($daemonResult)
$daemonResult=Invoke-TransportDecision -State (New-TransportDecisionState -Now 6 -CurrentTag '') -Candidates @() -CurrentTag '' -Now 6 -Events @()
Assert ($daemonResult.verdict.action -eq 'searching') 'D: пустой выбор возвращает исполняемый searching'
$daemonResults+=@($daemonResult)
foreach($result in $daemonResults){
    Assert ($result.verdict.action -in $legacyActions -and $result.verdict.action -notin @('probe-round','probe-active','post-switch-verify')) 'D: обычный вызов демона не требует действий T2'
    Assert (-not $result.state.episodeEnabled -and $null -eq $result.state.episode) 'D: создание, подтверждение и reset без флага остаются legacy'
}
$oldState=New-TransportDecisionState -Now 0 -CurrentTag 'a';[void]$oldState.Remove('episodeEnabled')
$daemonResult=Invoke-TransportDecision -State $oldState -Candidates $daemonRows -CurrentTag 'a' -Now 1 -Events @((Event 1 'path-check' 'a' 'timeout'))
Assert ($daemonResult.verdict.action -eq 'check-direct' -and -not $daemonResult.state.episodeEnabled) 'D: состояние до T1 без episodeEnabled также использует legacy'

# T2: явный opt-in при создании и перенос настройки при reset.
$s=New-TransportDecisionState -Now 0 -CurrentTag 'a' -SwitchEpisode:$true
Assert ($s.episodeEnabled) 'D/R: создание состояния принимает явное включение эпизодов'
$r=Invoke-TransportDecision -State $s -Candidates $daemonRows -CurrentTag 'a' -Now 1 -Events @((Event 1 'dial-fail'))
Assert ($r.state.episodeEnabled -and $r.verdict.action -eq 'probe-round') 'D/R: созданный opt-in работает без флага на следующем вызове'
$s=New-TransportDecisionState -Now 2 -CurrentTag 'a' -SwitchEpisode:$r.state.episodeEnabled
Assert ($s.episodeEnabled -and $null -eq $s.episode) 'D/R: reset с переносом настройки очищает эпизод, сохраняя режим'
$r=Invoke-TransportDecision -State $s -Candidates $daemonRows -CurrentTag 'a' -Now 3 -Events @((Event 3 'dial-fail'))
Assert ($r.state.episodeEnabled -and $r.verdict.action -eq 'probe-round') 'D/R: после reset с переносом настройки эпизоды остаются включены'
$s=New-TransportDecisionState -Now 4 -CurrentTag 'a'
Assert (-not $s.episodeEnabled) 'D/R: пересоздание без переноса настройки по умолчанию возвращает legacy'
$r=Invoke-TransportDecision -State $s -Candidates $daemonRows -CurrentTag 'a' -Now 5 -Events @((Event 5 'dial-fail'))
Assert (-not $r.state.episodeEnabled -and $r.verdict.action -eq 'check-direct') 'D/R: reset без opt-in возвращает прежний контракт действий'

# (1) сигнал -> probe-round сразу (t=0)
$s = New-TransportDecisionState 0 'a'
$rows = @((Row 'a'), (Row 'b' 'remembered' 120), (Row 'c' 'ok' 150))
$r = DecideSwitch $s 0 @((Event 0 'dial-fail' 'a')) $rows 'a'
Assert ($r.verdict.action -eq 'probe-round') '1: сигнал сразу даёт probe-round'
Assert ($r.verdict.tag -eq 'a') '1: активный путь передан в tag'
Assert ($r.verdict.tags.Count -eq 3 -and $r.verdict.tags -contains 'a' -and $r.verdict.tags -contains 'b') '1: probe-round включает все неоштрафованные пути'
Assert ($r.state.episode.open -eq $true) '1: эпизод открыт'
Assert ($r.verdict.penalties.a.step -eq 0) '1: на t=0 штраф ещё не наложен'

# (2) ожил на 2500 мс -> без переключения
$s = New-TransportDecisionState 0 'a'
$r = DecideSwitch $s 0 @((Event 0 'conn-closed-error' 'a')) $rows 'a'
Assert ($r.verdict.action -eq 'probe-round') '2: эпизод открыт по conn-closed-error'
# Ступень 1 на 1000 мс
$r = DecideSwitch $r.state 1000 @((Event 500 'path-check' 'a' 'timeout')) $rows 'a'
Assert ($r.verdict.action -eq 'probe-active' -and $r.verdict.tag -eq 'a') '2: ступень 1 на 1000 мс даёт probe-active'
# Активный путь ожил на 2500 мс
$r = DecideSwitch $r.state 2500 @((Event 2500 'path-check' 'a' 'ok')) $rows 'a'
Assert ($r.verdict.action -eq 'stay') '2: вердикт stay при оживлении активного'
Assert ($r.state.episode.open -eq $false) '2: эпизод закрыт'
Assert ($r.verdict.penalties.a.step -eq 0 -and $null -eq $r.verdict.penalties.a.until) '2: без штрафа на активном'
# Проверка, что на 10000 мс переключения нет
$r = DecideSwitch $r.state 10000 @() $rows 'a'
Assert ($r.verdict.action -eq 'stay' -and $r.verdict.tag -eq 'a') '2: на 10000 мс переключение не происходит'

# (3) 9999 мс stay, 10000 мс switch
$s = New-TransportDecisionState 0 'a'
$r = DecideSwitch $s 0 @((Event 0 'stall-suspect' 'a')) $rows 'a'
# b ответил ok, a дал timeout
$r = DecideSwitch $r.state 500 @((Event 500 'path-check' 'b' 'ok'), (Event 500 'path-check' 'a' 'timeout')) $rows 'a'
Assert ($r.verdict.action -eq 'stay') '3: на 500 мс вердикт stay'
# 1000 мс - ступень 1
$r = DecideSwitch $r.state 1000 @() $rows 'a'
Assert ($r.verdict.action -eq 'probe-active') '3: на 1000 мс probe-active'
# 3000 мс - ступень 2
$r = DecideSwitch $r.state 3000 @((Event 2000 'path-check' 'a' 'stalled')) $rows 'a'
Assert ($r.verdict.action -eq 'probe-active') '3: на 3000 мс probe-active'
# 9999 мс - ещё ожидание
$r = DecideSwitch $r.state 9999 @() $rows 'a'
Assert ($r.verdict.action -eq 'stay') '3: на 9999 мс вердикт stay'
# 10000 мс - решение blipMs!
$r = DecideSwitch $r.state 10000 @() $rows 'a'
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.tag -eq 'b') '3: на 10000 мс переключение на b'
Assert ($r.verdict.penalties.a.step -eq 1 -and $r.verdict.penalties.a.until -eq 15000) '3: активный получил штраф 5с (лестница 5/15/45/120/300)'
Assert ($r.verdict.notes -contains 'post-switch-verify') '3: пост-проверка post-switch-verify'
# Подтверждение переключения селектора -> post-switch-verify
$r = DecideSwitch $r.state 10050 @() $rows 'b'
Assert ($r.verdict.action -eq 'post-switch-verify' -and $r.verdict.tag -eq 'b') '3: подтверждение селектора запускает post-switch-verify'

# (4) реальный штраф после switch -> новый эпизод без сети -> откат
$s = New-TransportDecisionState 0 'a'
$r = DecideSwitch $s 0 @((Event 0 'dial-fail' 'a'), (Event 0 'path-check' 'b' 'ok')) $rows 'a'
$r = DecideSwitch $r.state 10000 @() $rows 'a'
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.penalties.a.step -eq 1) '4: до отката действительно наложен штраф'
$r = DecideSwitch $r.state 10010 @() $rows 'b'
$r = DecideSwitch $r.state 11000 @((Event 11000 'dial-fail' 'b'), (Event 11000 'net-down' '')) $rows 'b'
Assert ($r.verdict.localNet -eq 'down' -and $r.verdict.penalties.a.step -eq 0) '4/B: net-down при verify сразу откатывает реальный штраф'
$r = DecideSwitch $r.state 21000 @() $rows 'b'
Assert ($r.verdict.action -eq 'stay' -and $r.verdict.tag -eq 'b') '4: при отсутствии сети вердикт stay'
Assert ($r.verdict.penalties.a.step -eq 0 -and $null -eq $r.verdict.penalties.a.until) '4: реальный штраф откатан'
Assert ($r.verdict.reason.code -eq 'local-network-down') '4: причина local-network-down'

# (5) refused -> решение на 3000 мс
$s = New-TransportDecisionState 0 'a'
$r = DecideSwitch $s 0 @((Event 0 'path-check' 'a' 'refused')) $rows 'a'
Assert ($r.verdict.action -eq 'probe-round') '5: refused сразу открывает эпизод'
Assert ($r.state.episode.hardFail -eq $true) '5: refused ставит отметку hardFail'
# b ответил
$r = DecideSwitch $r.state 500 @((Event 500 'path-check' 'b' 'ok')) $rows 'a'
# 1000 мс - ступень 1
$r = DecideSwitch $r.state 1000 @() $rows 'a'
Assert ($r.verdict.action -eq 'stay') '5: исходный refused не является результатом нового раунда'
# 2999 мс - ещё stay
$r = DecideSwitch $r.state 2999 @() $rows 'a'
Assert ($r.verdict.action -eq 'stay') '5: на 2999 мс stay'
# 3000 мс - решение по hardFailMs!
$r = DecideSwitch $r.state 3000 @() $rows 'a'
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.tag -eq 'b') '5: на 3000 мс switch на лучшего ответившего'
Assert ($r.verdict.penalties.a.step -eq 1 -and $r.verdict.penalties.a.until -eq 8000) '5: штраф 5с наложен на отметке 3000 мс'

# Дополнительно: никто не ответил -> stay со статусом "сервер недоступен"
$s = New-TransportDecisionState 0 'a'
$r = DecideSwitch $s 0 @((Event 0 'dial-fail' 'a')) $rows 'a'
$r = DecideSwitch $r.state 10000 @() $rows 'a'
Assert ($r.verdict.action -eq 'stay' -and $r.verdict.tag -eq 'a') 'никто не ответил -> stay'
Assert ($r.verdict.reason.code -eq 'server-unavailable') 'причина server-unavailable'
Assert ($r.verdict.reason.text -eq 'Сервер недоступен') 'текст Сервер недоступен'

# Дополнительно: пороги из конфига
$cfg = @{
    blipMs = 8000
    hardFailMs = 2000
    stageMs = @(500, 1500)
}
$s = New-TransportDecisionState 0 'a'
$r = DecideSwitch $s 0 @((Event 0 'dial-fail' 'a')) $rows 'a' -Config $cfg
$r = DecideSwitch $r.state 500 @((Event 400 'path-check' 'a' 'timeout')) $rows 'a' -Config $cfg
Assert ($r.verdict.action -eq 'probe-active') 'пороги из конфига: stage1 на 500 мс'
$r = DecideSwitch $r.state 600 @((Event 600 'path-check' 'b' 'ok'), (Event 600 'path-check' 'a' 'timeout')) $rows 'a' -Config $cfg
$r = DecideSwitch $r.state 1500 @() $rows 'a' -Config $cfg
Assert ($r.verdict.action -eq 'probe-active') 'пороги из конфига: stage2 на 1500 мс'
$r = DecideSwitch $r.state 7999 @() $rows 'a' -Config $cfg
Assert ($r.verdict.action -eq 'stay') 'пороги из конфига: 7999 stay'
$r = DecideSwitch $r.state 8000 @() $rows 'a' -Config $cfg
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.tag -eq 'b') 'пороги из конфига: 8000 switch'

# Дополнительно: двойной engine-exit ставит hardFail (решение на 3000 мс)
$s = New-TransportDecisionState 0 'a'
$r = DecideSwitch $s 0 @((Event 0 'engine-exit' 'a'), (Event 0 'engine-exit' 'a')) $rows 'a'
Assert ($r.state.episode.hardFail -eq $true) 'двойной engine-exit -> hardFail'
$r = DecideSwitch $r.state 500 @((Event 500 'path-check' 'b' 'ok')) $rows 'a'
$r = DecideSwitch $r.state 3000 @() $rows 'a'
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.tag -eq 'b') 'двойной exit -> решение на 3000 мс'

# Проверка вызова через Invoke-TransportDecision с флагом -SwitchEpisode
$s = New-TransportDecisionState 0 'a'
$r = Invoke-TransportDecision -State $s -Candidates $rows -Now 0 -CurrentTag 'a' -Events @((Event 0 'dial-fail' 'a')) -SwitchEpisode
Assert ($r.verdict.action -eq 'probe-round') 'Invoke-TransportDecision с -SwitchEpisode возвращает probe-round'

# Регрессии ревью 1: пустой/неизвестный/исключённый активный путь.
foreach($current in @('', 'x', 'a')){
    $onlyB=@((Row 'b'))
    $s=New-TransportDecisionState 0 $current
    if($current -eq 'a'){$s.paths.a=New-TransportDecisionPath}
    $r=DecideSwitch $s 0 @((Event 0 'engine-exit' $current), (Event 0 'path-check' 'b' 'ok')) $onlyB $current
    Assert ($r.verdict.action -eq 'probe-round') '1R: отсутствие активного кандидата не роняет engine-exit'
    Assert (-not $r.state.episode.hardFail) '1R: нет счётчика engine-exit для отсутствующего кандидата'
    $r=DecideSwitch $r.state 1 @() $onlyB $current
    Assert ($r.verdict.action -eq 'switch' -and $r.verdict.tag -eq 'b') '1R: ответивший выбирается без ожидания отсутствующего пути'
    Assert (-not $r.state.paths.ContainsKey($current) -or $r.state.paths[$current].step -eq 0) '1R: отсутствующий путь не штрафуется'
    $r=DecideSwitch (New-TransportDecisionState 0 $current) 0 @((Event 0 'net.change' '')) $onlyB $current
    $r=DecideSwitch $r.state 1 @() $onlyB $current
    Assert ($r.verdict.action -eq 'stay') '1R: без ответивших и активного кандидата остаёмся без исключения'
}

# Этап B: явное включение эпизодов сохраняется после закрытия до opt-out.
$s=New-TransportDecisionState 0 'a'
$r=DecideSwitch $s 0 @((Event 0 'dial-fail')) $rows
$r=DecideSwitch $r.state 1 @((Event 1 'path-check' 'a' 'ok')) $rows
$r=Invoke-TransportDecision -State $r.state -Candidates $rows -Now 2 -CurrentTag 'a' -Events @((Event 2 'dial-fail'))
Assert ($r.verdict.action -eq 'probe-round' -and $r.state.episodeEnabled) '2R/B: после закрытия без флага остаётся эпизодный решатель'
foreach($enabled in @($false,$true)){
    $s=New-TransportDecisionState 0 'a'
    $s.paths.a=New-TransportDecisionPath
    Add-TransportDecisionPenalty $s 'a' 'path-dial-failed' 0 0
    $s.episode=@{open=$false;status='closed'}
    $r=Invoke-TransportDecision -State $s -Candidates $rows -Now 1 -CurrentTag 'a' -Events @((Event 1 'path-check' 'a' 'ok')) -SwitchEpisode:$enabled
    Assert ($r.state.paths.a.step -eq 0 -and $null -eq $r.state.paths.a.until -and $r.state.history.Count -eq 0) '2R: восстановление вне эпизода сбрасывает лестницу и историю'
    $r=DecideSwitch $r.state 2 @((Event 2 'dial-fail'), (Event 2 'path-check' 'b' 'ok')) $rows
    $r=DecideSwitch $r.state 10002 @() $rows
    Assert ($r.verdict.penalties.a.step -eq 1) '2R: следующий отказ начинает лестницу с первой ступени'
}
$s=New-TransportDecisionState 0 'a'
$s.paths.a=New-TransportDecisionPath
Add-TransportDecisionPenalty $s 'a' 'path-dial-failed' 0 0
$s.episode=@{open=$false;status='closed'}
$r=Invoke-TransportDecision -State $s -Candidates @((Row 'a')) -Now 5000 -CurrentTag 'a' -SwitchEpisode:$false
Assert ($r.verdict.action -eq 'check-path') '2R: истёкший штраф вне эпизода разрешает восстановительную проверку'

# Ревью 3: все события открывающей пачки и подтверждения селектора сохраняются.
$s=New-TransportDecisionState 0 'a'
$r=DecideSwitch $s 0 @((Event 0 'dial-fail'), (Event 0 'path-check' 'b' 'ok'), (Event 0 'net-down' ''), (Event 0 'net-up' '')) $rows
Assert ($r.state.episode.responded.ContainsKey('b') -and $r.verdict.localNet -eq 'ok') '3R: смешанная открывающая пачка сохраняет b ok и изменения сети'
Assert ($r.verdict.direct -eq $true -and $r.verdict.tags.Count -eq 3) '11R: probe-round явно запрашивает check-direct и пути'
$r=DecideSwitch $r.state 10000 @() $rows
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.tag -eq 'b') '3R: ответ из первой пачки участвует в выборе'
$r=DecideSwitch $r.state 10001 @((Event 10001 'path-check' 'a' 'ok'), (Event 10001 'net-down' ''), (Event 10001 'net-up' '')) $rows 'b'
Assert ($r.verdict.action -eq 'post-switch-verify' -and $r.state.paths.a.step -eq 0 -and $r.verdict.localNet -eq 'ok') '3R: подтверждение не теряет recovery и net-down/up'
$r=DecideSwitch $r.state 10002 @((Event 10002 'dial-fail' 'b')) $rows 'b'
$r=DecideSwitch $r.state 10003 @((Event 10003 'path-check' 'b' 'ok'), (Event 10003 'net-down' '')) $rows 'b'
Assert (-not $r.state.episode.open -and $r.verdict.localNet -eq 'down' -and $r.verdict.reason.code -eq 'local-network-down') '3R: успех активного не обрывает разбор пачки'

$r=DecideSwitch (New-TransportDecisionState 0 'a') 0 @((Event 0 'dial-fail'), (Event 0 'path-check' 'b' 'ok')) $rows
$r=DecideSwitch $r.state 10000 @() $rows
$r=DecideSwitch $r.state 10001 @((Event 10001 'dial-fail' 'b')) $rows 'b'
Assert ($r.verdict.action -eq 'post-switch-verify' -and $r.state.pending.ContainsKey('b') -and $null -eq $r.state.directRequestedAt) '3R: отказ из подтверждающей пачки сохранён, direct не помечен исполненным'
$r=DecideSwitch $r.state 10002 @() $rows 'b'
Assert ($r.verdict.action -eq 'stay' -and $r.state.pending.ContainsKey('b')) '3R/B: сигнал подтверждающей пачки сохранён до исхода verify, legacy direct не запускается'

# Ревью 6: отмены/неизвестные результаты не открывают эпизод и не разрешают повтор.
foreach($code in @('cancelled','canceled','operation-canceled','operation-cancelled','context-canceled','aborted','unknown')){
    $r=DecideSwitch (New-TransportDecisionState 0 'a') 0 @((Event 0 'path-check' 'a' $code)) $rows
    Assert ($null -eq $r.state.episode -and $r.verdict.action -eq 'stay') '6R: отмена/неизвестный результат не открывает эпизод'
    $r=DecideSwitch (New-TransportDecisionState 0 'a') 0 @((Event 0 'dial-fail')) $rows
    $r=DecideSwitch $r.state 1000 @((Event 500 'path-check' 'a' $code)) $rows
    Assert ($r.verdict.action -eq 'stay' -and -not $r.state.episode.activeProbeFailed) '6R: отмена/неизвестный результат внутри эпизода не считается провалом'
}

# Ревью 7/8: сигнал несёт время; старый ok не закрывает новый эпизод;
# начальный раунд не считается провалившимся, один engine-exit не считается двумя.
$r=DecideSwitch (New-TransportDecisionState 0 'a') 9000 @((Event 0 'dial-fail'), (Event 100 'path-check' 'b' 'ok')) $rows
Assert ($r.state.episode.openedAt -eq 0) '7R: openedAt берётся из сигнала, не из времени доставки'
$r=DecideSwitch $r.state 10000 @() $rows
Assert ($r.verdict.action -eq 'stay' -and $r.state.episode.open) '7R/B: задержанный сигнал не обрывает только что выданную пробу'
$r=DecideSwitch (New-TransportDecisionState 0 'a') 100 @((Event 99 'path-check' 'a' 'ok'), (Event 100 'dial-fail')) $rows
Assert ($r.state.episode.open) '7R: старый успех не закрывает новый эпизод'
$r=DecideSwitch (New-TransportDecisionState 0 'a') 0 @((Event 0 'engine-exit')) $rows
Assert (-not $r.state.episode.hardFail -and $r.state.paths.a.exitTimes.Count -eq 1) '8R: одиночный выход учитывается ровно один раз'
$r=DecideSwitch $r.state 1000 @() $rows
Assert ($r.verdict.action -eq 'stay') '8R: нет дублирующей пробы до провала первой'
$r=DecideSwitch $r.state 3000 @((Event 2000 'path-check' 'a' 'timeout')) $rows
Assert ($r.verdict.action -eq 'probe-active') '8R: полученный провал разрешает повтор активного'

# Ревью 9: скаляры, default=0, границы, неверные типы и порядок безопасны.
Assert ((Get-TransportSwitchThreshold -5 10000) -eq 1) '9R: отрицательный порог ограничен снизу'
Assert ((Get-TransportSwitchThreshold @{default=0;min=3000;max=30000} 10000) -eq 3000) '9R: default=0 не приводит объект к long'
Assert ((Get-TransportSwitchThreshold @{default=90000;min=3000;max=30000} 10000) -eq 30000) '9R: верхняя граница схемы применяется'
Assert ((Get-TransportSwitchThreshold @{default='bad';min=3000;max=30000} 10000) -eq 10000) '9R: неверное значение заменяется умолчанием'
Assert ((Get-TransportSwitchThreshold @{default=10000;min=30000;max=3000} 10000) -eq 10000) '9R: обратные границы заменяются безопасными'
foreach($cfg in @(@{blipMs=-5}, @{blipMs=@{default=0}}, @{stageMs=@(3000,1000)}, @{hardFailMs='bad'}, @{stageMs=@('bad')})){
    $r=DecideSwitch (New-TransportDecisionState 0 'a') 0 @((Event 0 'dial-fail'), (Event 0 'path-check' 'b' 'ok')) $rows 'a' $cfg
    $r=DecideSwitch $r.state 1 @() $rows 'a' $cfg
    Assert ($r.verdict.action -eq 'stay') '9R: некорректная конфигурация не вызывает немедленное переключение или исключение'
}

# Ревью 10/13: свежий ответ кандидата подтверждает сеть; ввод ограничен кандидатами.
$r=DecideSwitch (New-TransportDecisionState 0 'a') 0 @((Event 0 'dial-fail'), (Event 0 'net-down' '')) $rows
$r=DecideSwitch $r.state 1 @((Event 1 'path-check' 'b' 'ok'), (Event 1 'path-check' 'not-a-candidate' 'ok'), @{at='bad';kind='net-down'}, (Event 99999 'net-down' '')) $rows
Assert ($r.verdict.localNet -eq 'ok' -and $r.state.episode.responded.Count -eq 1) '10R/13R: только известный свежий ответ подтверждает сеть; мусор отброшен'
$r=DecideSwitch $r.state 10000 @() $rows
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.tag -eq 'b') '10R: после b ok отдельный net-up не нужен'
Assert ($r.verdict.ContainsKey('tags') -and $r.verdict.ContainsKey('direct')) '11R: форма вердиктов едина'

# Правка 3, замечание 1: сеть до открытия эпизода, с РАЗНЫМИ at; откат реального штрафа.
foreach($networkEvent in @((Event 1 'net-down' ''), (Event 1 'dial-fail' 'b' 'timeout' $true))){
    $s=New-TransportDecisionState 0 'a';$s.paths.a=New-TransportDecisionPath
    Add-TransportDecisionPenalty $s 'a' 'path-dial-failed' 0 0
    $r=DecideSwitch $s 2 @($networkEvent, (Event 2 'dial-fail')) $rows
    Assert ($r.state.episode.openedAt -eq 2 -and $r.verdict.localNet -eq 'down') 'F3.1: ранний net-down/local-сигнал сохранён'
    Assert ($r.verdict.penalties.a.step -eq 1) 'F3.1: до решения штраф существует'
    $r=DecideSwitch $r.state 10002 @() $rows
    Assert ($r.verdict.action -eq 'stay' -and $r.verdict.reason.code -eq 'local-network-down') 'F3.1: без сети переключения нет'
    Assert ($r.verdict.penalties.a.step -eq 0 -and $null -eq $r.verdict.penalties.a.until) 'F3.1: прежний штраф откатан'
}
$s=New-TransportDecisionState 0 'a';$s.localNet='down';$s.localNetAt=0
$r=DecideSwitch $s 2 @((Event 1 'net-up' ''), (Event 2 'dial-fail')) $rows
Assert ($r.verdict.localNet -eq 'ok' -and $r.state.localNetAt -eq 1) 'F3.1: ранний net-up тоже сохранён'

# Замечание 2: успех закрывает старый эпизод, следующий провал открывает новый.
$r=DecideSwitch (New-TransportDecisionState 0 'a') 0 @((Event 0 'dial-fail')) $rows
$r=DecideSwitch $r.state 3 @((Event 1 'path-check' 'a' 'ok'), (Event 2 'path-check' 'a' 'timeout'), (Event 3 'path-check' 'b' 'ok')) $rows
Assert ($r.verdict.action -eq 'probe-round' -and $r.state.episode.open -and $r.state.episode.openedAt -eq 2) 'F3.2: провал после успеха открывает следующий эпизод'
Assert ($r.state.episode.responded.ContainsKey('b') -and -not $r.state.episode.activeProbeFailed) 'F3.2: хвост пачки сохранён, новый раунд ещё не провалился'
$r=DecideSwitch $r.state 10002 @() $rows
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.tag -eq 'b' -and $r.verdict.penalties.a.step -eq 1) 'F3.2: новый эпизод действительно участвует в решении'

# Замечание 3: запоздавший провал после свежего успеха не наказывает исправный путь.
foreach($failure in @((Event 9 'path-check' 'a' 'timeout'), (Event 9 'dial-fail'))){
    $r=DecideSwitch (New-TransportDecisionState 0 'a') 0 @((Event 0 'dial-fail')) $rows
    $r=DecideSwitch $r.state 10 @((Event 10 'path-check' 'a' 'ok')) $rows
    $r=DecideSwitch $r.state 11 @($failure, (Event 11 'path-check' 'b' 'ok')) $rows
    Assert (-not $r.state.episode.open -and $r.state.pending.Count -eq 0) 'F3.3: старый провал не открывает эпизод/pending'
    $r=DecideSwitch $r.state 10011 @() $rows
    Assert ($r.verdict.action -eq 'stay' -and $r.verdict.reason.code -eq 'ok' -and $r.verdict.penalties.a.step -eq 0) 'F3.3: исправный a не переключён и не оштрафован'
}

# Замечание 4: вся цепочка через публичный API с явным включением эпизодов.
$r=Invoke-TransportDecision -State (New-TransportDecisionState 0 'a') -Candidates $rows -Now 0 -CurrentTag 'a' -Events @((Event 0 'dial-fail')) -SwitchEpisode
Assert ($r.verdict.action -eq 'probe-round') 'F3.4: публичный API открывает эпизод'
$r=Invoke-TransportDecision -State $r.state -Candidates $rows -Now 1 -CurrentTag 'a' -Events @((Event 1 'path-check' 'b' 'ok')) -SwitchEpisode:$true
Assert ($r.state.episode.open) 'F3.4: публичный API продолжает открытый эпизод'
$r=Invoke-TransportDecision -State $r.state -Candidates $rows -Now 10000 -CurrentTag 'a' -SwitchEpisode:$true
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.tag -eq 'b') 'F3.4: публичный API предлагает b'
$r=Invoke-TransportDecision -State $r.state -Candidates $rows -Now 10001 -CurrentTag 'b' -Events @((Event 10001 'path-check' 'a' 'ok')) -SwitchEpisode:$true
Assert ($r.verdict.action -eq 'post-switch-verify' -and $r.verdict.tag -eq 'b' -and $r.state.episode.status -eq 'verifying') 'F3.4: подтверждение в эпизодном режиме запускает post-switch-verify'
Assert ($r.state.currentTag -eq 'b' -and $r.state.paths.a.step -eq 0) 'F3.4: подтверждение и его события обработаны'
$r=Invoke-TransportDecision -State $r.state -Candidates $rows -Now 10002 -CurrentTag 'b' -Events @((Event 10002 'path-check' 'b' 'ok')) -SwitchEpisode:$true
Assert ($r.verdict.action -eq 'stay' -and $r.state.paths.b.lastResultAt -eq 10002 -and $r.state.episode.status -eq 'closed') 'F3.4/B: проверка не повторяется, эпизодный решатель закрывает verify'

# Замечание 5: timeout, открывший эпизод, не является результатом probe-round.
$r=DecideSwitch (New-TransportDecisionState 0 'a') 0 @((Event 0 'path-check' 'a' 'timeout')) $rows
Assert ($r.verdict.action -eq 'probe-round' -and -not $r.state.episode.activeProbeFailed) 'F3.5: начальный timeout только открывает раунд'
$r=DecideSwitch $r.state 1000 @() $rows
Assert ($r.verdict.action -eq 'stay') 'F3.5: без результата раунда нет дублирующей пробы ступени 1'
$r=DecideSwitch $r.state 1500 @((Event 1500 'path-check' 'a' 'timeout')) $rows
Assert ($r.state.episode.activeProbeFailed) 'F3.5: новый результат раунда разрешает повтор'
$r=DecideSwitch $r.state 3000 @() $rows
Assert ($r.verdict.action -eq 'probe-active' -and -not $r.state.episode.activeProbeFailed) 'F3.5: ступень 2 повторяет пробу после её провала'
$r=DecideSwitch (New-TransportDecisionState 0 'a') 900 @((Event 0 'path-check' 'a' 'timeout')) $rows
$r=DecideSwitch $r.state 1000 @((Event 500 'path-check' 'a' 'timeout')) $rows
Assert ($r.verdict.action -eq 'stay' -and -not $r.state.episode.activeProbeFailed) 'F3.5: задержанный результат до запроса раунда не разрешает повтор'

# Этап B, замечание 1: сигнал старше Now на 10 с. Это события, без ожиданий.
$r=DecideSwitch (New-TransportDecisionState 0 'a') 10000 @((Event 0 'dial-fail')) $rows
Assert ($r.verdict.action -eq 'probe-round' -and $r.state.episode.openedAt -eq 0 -and $r.state.episode.activeProbeAt -eq 10000) 'B1: источник и время запроса пробы различаются'
$r=DecideSwitch $r.state 10001 @((Event 10001 'path-check' 'b' 'ok')) $rows
Assert ($r.verdict.action -eq 'stay' -and $r.state.episode.open) 'B1: поздняя доставка оставляет возможность ответить активному'
$r=DecideSwitch $r.state 10002 @((Event 10002 'path-check' 'a' 'ok')) $rows
Assert ($r.verdict.action -eq 'stay' -and -not $r.state.episode.open -and $r.state.paths.a.step -eq 0) 'B1: реальный ответ закрывает эпизод без штрафа'

# Замечания 2/3: local не открывает раунд; старый успех восстанавливает штраф.
foreach($kind in @('dial-fail','conn-closed-error')){
    $r=DecideSwitch (New-TransportDecisionState 0 'a') 10 @((Event 10 $kind 'a' 'timeout' $true)) $rows
    Assert ($r.verdict.action -eq 'stay' -and $null -eq $r.state.episode -and $r.verdict.localNet -eq 'down') 'B2: локальная ошибка не запускает лёгкие пробы'
}
$s=New-TransportDecisionState 0 'a';$s.paths.b=New-TransportDecisionPath
Add-TransportDecisionPenalty $s 'b' 'path-dial-failed' 0 0
$r=DecideSwitch $s 2 @((Event 1 'path-check' 'b' 'ok'),(Event 2 'dial-fail')) $rows
Assert ($r.state.paths.b.step -eq 0 -and $r.state.paths.b.successStreak -eq 1 -and $r.state.history.Count -eq 0) 'B3: b ok at=1 снимает штраф перед a dial-fail at=2'
Assert (-not $r.state.episode.responded.ContainsKey('b')) 'B3: результат до openedAt не отвечает за новый эпизод'
Assert ($r.state.episode.open -and $r.verdict.tags -contains 'b') 'B3: восстановленный b доступен для нового раунда'

# Явное включение эпизодов не разрешает legacy переключать между эпизодами.
$s=New-TransportDecisionState 0 'a'
$r=Invoke-TransportDecision -State $s -Candidates $rows -Now 0 -CurrentTag 'a' -Events @((Event 0 'dial-fail')) -SwitchEpisode:$true
Assert ($r.verdict.action -eq 'probe-round') 'B4: новый решатель включён явно'
$r=Invoke-TransportDecision -State $r.state -Candidates $rows -Now 1 -CurrentTag 'a' -Events @((Event 1 'path-check' 'a' 'ok')) -SwitchEpisode:$true
$r.state.paths.a.failed=$true
$r=Invoke-TransportDecision -State $r.state -Candidates $rows -Now 30000 -CurrentTag 'a' -SwitchEpisode:$true
Assert ($r.verdict.action -eq 'stay' -and $r.state.episodeEnabled) 'B4: закрытый эпизод не разрешает legacy самостоятельный switch'
$r=Invoke-TransportDecision -State $r.state -Candidates $rows -Now 30001 -CurrentTag 'a' -SwitchEpisode:$false
Assert ($r.verdict.action -eq 'switch' -and -not $r.state.episodeEnabled) 'B4: явный opt-out возвращает старый решатель'

# (6) Три фактических переключения по at событий, включая задержанную пачку.
$flaps=@(@{at=1;kind='transport.switch';from='a';to='b'},@{at=2;kind='transport.switch';from='b';to='c'},@{at=3;kind='transport.switch';from='c';to='a'})
$r=DecideSwitch (New-TransportDecisionState 0 'a') 100 ($flaps+@((Event 100 'dial-fail'),(Event 100 'path-check' 'b' 'ok'))) $rows
Assert ($r.state.flapHistory.Count -eq 3 -and $r.state.episode.policy.blipMs -eq 20000) '6: три switch за окно удваивают blipMs'
Assert ($r.verdict.flapping -and -not $r.verdict.allowImprovement) '6: моргание выключает улучшения'
$r=DecideSwitch $r.state 101 @($flaps[0]) $rows
Assert ($r.state.flapHistory.Count -eq 3) '6: повтор события switch не раздувает счётчик'
$r=DecideSwitch $r.state 20100 @() $rows
Assert ($r.verdict.action -eq 'switch') '6: ответивший кандидат выбирается с порогом эпизода'
$s=New-TransportDecisionState 0 'a';$s.flapHistory=$flaps
$r=DecideSwitch $s 600004 @((Event 600004 'dial-fail')) $rows
Assert (-not $r.verdict.flapping -and $r.state.episode.policy.blipMs -eq 10000) '6: старые события вне окна не вызывают моргание'
$q=@{stage1Ms=2000;stage2Ms=6000;hardFailMs=6000;blipMs=18000;flapping=$true;allowImprovement=$false}
$r=DecideSwitch (New-TransportDecisionState 0 'a') 100 ($flaps+@((Event 100 'dial-fail'))) $rows 'a' $q
Assert ($r.state.episode.policy.blipMs -eq 18000 -and -not $r.verdict.allowImprovement) '6: flapK из Q не применяется дважды'
$s=New-TransportDecisionState 0 'a';$s.flapHistory=$flaps
$r=Invoke-TransportDecision -State $s -Candidates @((Row 'a' 'ok' 200),(Row 'b' 'ok' 50),(Row 'c')) -Now 30000 -CurrentTag 'a' -Events @((Event 30000 'path-check' 'b' 'ok')) -AllowImprovement -SwitchEpisode:$true
Assert ($r.verdict.action -eq 'stay' -and $r.verdict.flapping) '6: AllowImprovement не обходит моргание'

# Подтверждение без события задаёт только minStay, без синтетической смены.
$r=DecideSwitch (New-TransportDecisionState 0 'a') 100 @() $rows 'b'
Assert ($r.state.flapHistory.Count -eq 0 -and $r.state.switches.Count -eq 0) '6R: подтверждение без события не пополняет историю'
Assert ($r.state.selectedAt -eq 100 -and $r.state.lastSwitchAt -eq 100) '6R: подтверждение без события начинает minStay от Now'
$confirmed=Copy-TransportDecisionValue $r.state
$r=DecideSwitch ($r.state|ConvertTo-Json -Depth 30|ConvertFrom-Json) 102 @(@{at=101;kind='transport.switch';from='a';to='b';changed=$true}) $rows 'b'
Assert ($r.state.flapHistory.Count -eq 1 -and $r.state.switches.Count -eq 1 -and $r.state.flapHistory[0].at -eq 101) '6R: позднее событие добавляет ровно одну настоящую смену'
Assert ($r.state.selectedAt -eq 101 -and $r.state.lastSwitchAt -eq 101) '6R: более новое событие уточняет minStay через max(at)'
$r=DecideSwitch $r.state 103 @(@{at=101;kind='transport.switch';from='a';to='b';changed=$true}) $rows 'b'
Assert ($r.state.flapHistory.Count -eq 1 -and $r.state.switches.Count -eq 1) '6R: повтор события не меняет обе истории'
$refined=Copy-TransportDecisionValue $r.state
$r=DecideSwitch $confirmed 104 @(@{at=99;kind='transport.switch';from='a';to='b'}) $rows 'b'
Assert ($r.state.flapHistory.Count -eq 1 -and $r.state.flapHistory[0].at -eq 99 -and $r.state.selectedAt -eq 100 -and $r.state.lastSwitchAt -eq 100) '6R: старое событие сохраняется, но не сдвигает minStay назад'
$r=DecideSwitch $confirmed 104 @() $rows 'c'
$r=DecideSwitch $r.state 105 @((Event 105 'dial-fail' 'c')) $rows 'c'
Assert ($r.state.flapHistory.Count -eq 0 -and $r.state.switches.Count -eq 0 -and -not $r.verdict.flapping -and $r.state.episode.policy.blipMs -eq 10000) '6R: несколько подтверждений без событий не вызывают моргание'
$stayRows=@((Row 'a' 'ok' 100),(Row 'b' 'ok' 200))
foreach($case in @(@{state=$confirmed;selected=100},@{state=$refined;selected=101})){
    $r=Invoke-TransportDecision -State $case.state -Candidates $stayRows -Now ($case.selected+29999) -CurrentTag 'b' -Events @((Event 200 'path-check' 'a' 'ok')) -AllowImprovement -SwitchEpisode:$true
    Assert ($r.verdict.action -eq 'stay') '6R: улучшение ждёт полный minStay от selectedAt'
    $r=Invoke-TransportDecision -State $r.state -Candidates $stayRows -Now ($case.selected+30000) -CurrentTag 'b' -AllowImprovement -SwitchEpisode:$true
    Assert ($r.verdict.action -eq 'switch' -and $r.verdict.tag -eq 'a') '6R: улучшение разрешено на границе minStay от selectedAt'
}
$noChanges=@(
    @{at=1;kind='transport.switch';from='a';to='a';changed=$false},
    @{at=2;kind='transport.switch';from='a';to='a'},
    @{at=3;kind='transport.switch';from='a';to='b';changed=$false},
    @{at=4;kind='transport.switch';from='bad tag';to='b'},
    @{at=5;kind='transport.switch';to='b'},
    @{at=6;kind='transport.switch';from='a';to='unknown'},
    @{at=7;kind='transport.switch';from='unavailable';to='b'},
    @{at='bad';kind='transport.switch';from='a';to='b'},
    @{at=-1;kind='transport.switch';from='a';to='b'},
    @{at=101;kind='transport.switch';from='a';to='b'}
)
$r=DecideSwitch (New-TransportDecisionState 0 'a') 100 ($noChanges+@((Event 100 'dial-fail'))) $rows
Assert ($r.state.flapHistory.Count -eq 0 -and $r.state.switches.Count -eq 0 -and -not $r.verdict.flapping -and $r.verdict.allowImprovement -and $r.state.episode.policy.blipMs -eq 10000) '6R: неизменившийся селектор, неверные теги и времена не считаются сменами'

# Ревью D: цепочка a-b-c не создаёт прямую a-c, при любом порядке доставки.
$chain=@(@{at=100000;kind='transport.switch';from='a';to='b'},@{at=200000;kind='transport.switch';from='b';to='c'})
foreach($delivery in @(@{items=$chain},@{items=@($chain[1],$chain[0])})){
    $r=DecideSwitch (New-TransportDecisionState 0 'a') 200000 $delivery.items $rows 'c'
    Assert ($r.state.flapHistory.Count -eq 2 -and $r.state.switches.Count -eq 2 -and -not $r.verdict.flapping) '6D: пачка a-b-c содержит ровно две смены без моргания'
    Assert (@($r.state.flapHistory|Where-Object {$_.from -eq 'a' -and $_.to -eq 'c'}).Count -eq 0) '6D: синтетической a-c нет'
    Assert (($r.state.switches.at -join ',') -eq '100000,200000' -and $r.state.selectedAt -eq 200000 -and $r.state.lastSwitchAt -eq 200000) '6D: пачка сохраняет порядок at и последнее время выбора'
    $batched=Copy-TransportDecisionValue $r.state
    $s=New-TransportDecisionState 0 'a';$now=200000
    foreach($ev in $delivery.items){
        $r=DecideSwitch ($s|ConvertTo-Json -Depth 30|ConvertFrom-Json) $now @($ev,$ev) $rows 'c'
        $s=$r.state;$now++
    }
    $r=DecideSwitch ($s|ConvertTo-Json -Depth 30|ConvertFrom-Json) $now $chain $rows 'c'
    Assert ($r.state.flapHistory.Count -eq 2 -and $r.state.switches.Count -eq 2 -and -not $r.verdict.flapping) '6D: раздельная доставка, JSON и дубли оставляют две смены'
    foreach($name in @('flapHistory','switches')){
        Assert ((($r.state[$name]|ForEach-Object {"$($_.at):$($_.from):$($_.to)"}) -join ',') -eq (($batched[$name]|ForEach-Object {"$($_.at):$($_.from):$($_.to)"}) -join ',')) ('6D: раздельная доставка совпадает с пачкой для '+$name)
    }
    Assert ($r.state.selectedAt -eq $batched.selectedAt -and $r.state.lastSwitchAt -eq $batched.lastSwitchAt) '6D: время выбора не зависит от порядка доставки цепочки'
}

# Известное событие и последовательные подтверждения также не создают записей.
$r=DecideSwitch (New-TransportDecisionState 0 'a') 200000 $chain $rows 'a'
$r=DecideSwitch ($r.state|ConvertTo-Json -Depth 30|ConvertFrom-Json) 210000 @() $rows 'c'
Assert ($r.state.flapHistory.Count -eq 2 -and $r.state.switches.Count -eq 2 -and $r.state.selectedAt -eq 200000 -and $r.state.lastSwitchAt -eq 200000) '6D: событие до подтверждения задаёт minStay своим временем'
$r=DecideSwitch (New-TransportDecisionState 0 'a') 100000 @($chain[0]) $rows 'b'
$r=DecideSwitch ($r.state|ConvertTo-Json -Depth 30|ConvertFrom-Json) 200000 @($chain[1]) $rows 'c'
Assert ($r.state.flapHistory.Count -eq 2 -and $r.state.switches.Count -eq 2 -and $r.state.selectedAt -eq 200000 -and -not $r.verdict.flapping) '6D: последовательные реальные подтверждения a-b-c дают две записи'

# Повторная пара — самостоятельные факты, подтверждение не поглощает ни один.
$batch=@(@{at=100000;kind='transport.switch';from='a';to='b'},@{at=200000;kind='transport.switch';from='b';to='a'},@{at=300000;kind='transport.switch';from='a';to='b'})
foreach($delivery in @(@{items=$batch},@{items=@($batch[2],$batch[1],$batch[0])})){
    $r=DecideSwitch (New-TransportDecisionState 0 'a') 300000 $delivery.items $rows 'b'
    Assert ($r.state.flapHistory.Count -eq 3 -and $r.state.switches.Count -eq 3 -and $r.verdict.flapping -and -not $r.verdict.allowImprovement) '6D: повторная пара в пачке даёт три смены и моргание'
    Assert (($r.state.switches.at -join ',') -eq '100000,200000,300000' -and $r.state.selectedAt -eq 300000) '6D: повторные пары упорядочены по at'
    $r=DecideSwitch (New-TransportDecisionState 0 'a') 100000 @() $rows 'b'
    $now=300000
    foreach($ev in $delivery.items){
        $r=DecideSwitch ($r.state|ConvertTo-Json -Depth 30|ConvertFrom-Json) $now @($ev,$ev) $rows 'b'
        $now++
    }
    $r=DecideSwitch ($r.state|ConvertTo-Json -Depth 30|ConvertFrom-Json) $now $batch $rows 'b'
    Assert ($r.state.flapHistory.Count -eq 3 -and $r.state.switches.Count -eq 3 -and $r.verdict.flapping) '6D: раздельные повторные пары с JSON и дублями сохраняют три события'
    Assert (($r.state.switches.at -join ',') -eq '100000,200000,300000' -and $r.state.selectedAt -eq 300000 -and $r.state.lastSwitchAt -eq 300000) '6D: старые события не меняют последнее время выбора'
}

# (7) Возврат: два успеха подряд, minStay, max(30 мс,20%), маркер переживает reset.
$returnRows=@((Row 'a' 'ok' 100),(Row 'b' 'ok' 200))
$s=New-TransportDecisionState 0 'b';$s.paths.a=New-TransportDecisionPath
Add-TransportDecisionPenalty $s 'a' 'path-dial-failed' 0 0
$r=Invoke-TransportDecision -State $s -Candidates $returnRows -Now 10000 -CurrentTag 'b' -Events @((Event 10000 'path-check' 'a' 'ok')) -AllowImprovement -SwitchEpisode:$true
Assert ($r.verdict.action -eq 'stay' -and $r.state.paths.a.successStreak -eq 1 -and $r.state.paths.a.recentPenaltyAt -eq 0) '7: один успех не разрешает возврат, маркер наказания сохранён'
$r=Invoke-TransportDecision -State $r.state -Candidates $returnRows -Now 11000 -CurrentTag 'b' -Events @((Event 11000 'path-check' 'a' 'ok')) -AllowImprovement -SwitchEpisode:$true
Assert ($r.verdict.action -eq 'stay' -and $r.state.paths.a.successStreak -eq 2) '7: два успеха не обходят minStay'
$ready=Copy-TransportDecisionValue $r.state
$r=Invoke-TransportDecision -State $ready -Candidates @((Row 'a' 'ok' 180),(Row 'b' 'ok' 200)) -Now 30000 -CurrentTag 'b' -AllowImprovement -SwitchEpisode:$true
Assert ($r.verdict.action -eq 'stay') '7: улучшение 20 мс недостаточно'
$r=Invoke-TransportDecision -State $ready -Candidates @((Row 'a' 'ok' 170),(Row 'b' 'ok' 200)) -Now 30000 -CurrentTag 'b' -AllowImprovement -SwitchEpisode:$true
Assert ($r.verdict.action -eq 'stay') '7: 30 мс не обходят порог 20% от 200 мс'
$r=Invoke-TransportDecision -State $ready -Candidates $returnRows -Now 30000 -CurrentTag 'b' -AllowImprovement -SwitchEpisode:$true
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.tag -eq 'a' -and $r.verdict.notes -contains 'improvement') '7: все три условия разрешают возврат'
$r=Invoke-TransportDecision -State $ready -Candidates $returnRows -Now 12000 -CurrentTag 'b' -Events @((Event 12000 'path-check' 'a' 'timeout')) -AllowImprovement -SwitchEpisode:$true
Assert ($r.state.paths.a.successStreak -eq 0) '7: провал прерывает серию успехов'
$r=Invoke-TransportDecision -State $r.state -Candidates $returnRows -Now 30000 -CurrentTag 'b' -Events @((Event 30000 'path-check' 'a' 'ok')) -AllowImprovement -SwitchEpisode:$true
Assert ($r.verdict.action -eq 'stay' -and $r.state.paths.a.successStreak -eq 1) '7: после провала счёт успехов начинается заново'
# Тот же запрет действует при аварийном выборе кандидата, а не только improvement.
$r=DecideSwitch $r.state 30001 @((Event 30001 'dial-fail' 'b'),(Event 30001 'path-check' 'a' 'ok')) $returnRows 'b'
$r=DecideSwitch $r.state 40001 @() $returnRows 'b'
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.tag -eq 'a') '7: недавно наказанный кандидат после двух успехов и minStay доступен эпизоду'
$s=Copy-TransportDecisionValue $ready;$s.paths.a.successStreak=1
$r=DecideSwitch $s 30001 @((Event 30001 'dial-fail' 'b')) $returnRows 'b'
$r.state.episode.responded.a=@{at=30001;tag='a'}
$r=DecideSwitch $r.state 40001 @() $returnRows 'b'
Assert ($r.verdict.action -eq 'stay' -and $r.verdict.reason.code -eq 'server-unavailable') '7: аварийный выбор тоже требует два успеха'

# (8) verify failure -> следующий уже ответивший кандидат в той же пачке.
$chainRows=@((Row 'a' 'ok' 200),(Row 'b' 'ok' 100),(Row 'c' 'ok' 150))
$r=DecideSwitch (New-TransportDecisionState 0 'a') 0 @((Event 0 'dial-fail'),(Event 0 'path-check' 'b' 'ok'),(Event 0 'path-check' 'c' 'ok')) $chainRows
$r=DecideSwitch $r.state 10000 @() $chainRows
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.tag -eq 'b') '8: выбран лучший ответивший b'
$proposal=Copy-TransportDecisionValue $r.state
$r=DecideSwitch $r.state 10001 @() $chainRows
Assert ($r.verdict.action -eq 'switch' -and $r.state.paths.a.step -eq 1) '8: неуспешный PUT повторяет предложение без нового штрафа'
$r=DecideSwitch $r.state 10002 @((Event 10002 'path-check' 'a' 'ok')) $chainRows 'b'
Assert ($r.verdict.action -eq 'post-switch-verify' -and $r.state.episode.responded.ContainsKey('c')) '8: подтверждение сохраняет ответы остальных'
$verifying=Copy-TransportDecisionValue $r.state
$r=DecideSwitch $verifying 10003 @((Event 10001 'post-switch-verify' 'b' 'timeout')) $chainRows 'b'
Assert ($r.verdict.action -eq 'stay' -and $r.state.episode.status -eq 'verifying') '8: результат до запроса verify игнорируется'
$r=DecideSwitch $verifying 10003 @((Event 10003 'post-switch-verify' 'b' 'timeout')) $chainRows 'b'
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.tag -eq 'c' -and $r.state.episode.openedAt -eq 0) '8: провал verify сразу выбирает c без нового эпизода и ожидания'
Assert ($r.state.paths.b.step -eq 1 -and $r.state.episode.attempted.ContainsKey('b')) '8: провалившийся b оштрафован и исключён из цепочки'
Assert ($r.state.episode.probed.b -eq 1 -and $r.state.episode.probed.c -eq 1) '8/9: цепочка не запускает повторные лёгкие пробы'
$r=DecideSwitch $r.state 10004 @() $chainRows 'c'
Assert ($r.verdict.action -eq 'post-switch-verify') '8: следующий подтверждённый выбор тоже запрашивает verify через бюджет Q'
$lastVerify=Copy-TransportDecisionValue $r.state
$r=DecideSwitch $lastVerify 10005 @((Event 10005 'post-switch-verify' 'c' 'ok')) $chainRows 'c'
Assert ($r.verdict.action -eq 'stay' -and $r.state.episode.status -eq 'closed') '8: успешный verify закрывает цепочку'
$r=DecideSwitch $lastVerify 10005 @((Event 10005 'post-switch-verify' 'c' 'timeout')) $chainRows 'c'
Assert ($r.verdict.action -eq 'stay' -and $r.verdict.reason.code -eq 'server-unavailable') '8: исчерпание кандидатов не создаёт цикл'
$r=DecideSwitch $verifying 10003 @((Event 10003 'post-switch-verify' 'b' 'timeout'),(Event 10003 'net-down' '')) $chainRows 'b'
Assert ($r.verdict.action -eq 'stay' -and $r.state.paths.b.step -eq 0 -and $r.verdict.localNet -eq 'down') '8: нет сети при verify — откат, без нового switch'

# Бюджет Q допускает одну 64 КиБ за эпизод: пропуск следующей не выдаёт успех.
$r=DecideSwitch $lastVerify 10005 @((Event 10005 'post-switch-verify' 'c' 'skipped')) $chainRows 'c'
Assert ($r.verdict.action -eq 'stay' -and $r.state.episode.status -eq 'closed' -and $r.state.paths.c.successStreak -eq 1 -and $r.verdict.notes -contains 'post-switch-verify-skipped') '8/Q: отказ бюджета завершает verify без выдуманного успеха'
$r=DecideSwitch $r.state 10006 @((Event 10006 'dial-fail' 'c')) $chainRows 'c'
Assert ($r.verdict.action -eq 'probe-round') '8/Q: пропущенный verify не блокирует последующие эпизоды'

# Настоящий отказ выбранного пути приходит В ПАЧКЕ подтверждения, Q пропускает verify.
$r=DecideSwitch $proposal 10002 @((Event 10002 'dial-fail' 'b')) $chainRows 'b'
Assert ($r.verdict.action -eq 'post-switch-verify' -and $r.state.pending.ContainsKey('b')) '8R: отказ из подтверждающей пачки сохранён до verify'
$pendingVerify=Copy-TransportDecisionValue $r.state
$r=DecideSwitch $pendingVerify 10003 @((Event 10003 'post-switch-verify' 'b' 'skipped')) $chainRows 'b'
Assert ($r.verdict.action -eq 'probe-round' -and $r.state.pending.ContainsKey('b') -and $r.state.episode.openedAt -eq 10002) '8R: skipped обрабатывает сохранённый реальный отказ новым раундом'
Assert ($r.state.paths.b.step -eq 0 -and $r.state.paths.b.successStreak -eq 0 -and $r.state.paths.b.lastResultAt -eq 0 -and $r.verdict.notes -contains 'post-switch-verify-skipped') '8R: skipped не подменяет отказ успехом или штрафом'
$retry=Copy-TransportDecisionValue $r.state
$r=DecideSwitch $retry 10004 @((Event 10004 'path-check' 'b' 'ok')) $chainRows 'b'
Assert ($r.verdict.action -eq 'stay' -and $r.state.episode.status -eq 'closed' -and -not $r.state.pending.ContainsKey('b')) '8R: только настоящий успех закрывает сохранённый отказ'
$r=DecideSwitch $retry 10004 @((Event 10004 'path-check' 'b' 'timeout'),(Event 10004 'path-check' 'c' 'ok')) $chainRows 'b'
$r=DecideSwitch $r.state 20002 @() $chainRows 'b'
Assert ($r.verdict.action -eq 'switch' -and $r.verdict.tag -eq 'c' -and $r.state.paths.b.step -eq 1) '8R: отказ после skipped доходит до штрафа и переключения'

# Время подтверждённого switch берётся из события, а не из задержанной доставки.
$r=DecideSwitch $proposal 11000 @(@{at=10010;kind='transport.switch';from='a';to='b'}) $chainRows 'b'
Assert ($r.state.lastSwitchAt -eq 10010 -and $r.state.selectedAt -eq 10010 -and $r.state.flapHistory.Count -eq 1) '8: задержанный switch не считается дважды и задаёт minStay по at'

# (9) Один раунд, одна лёгкая на каждого кандидата, не более трёх активному.
$r=DecideSwitch (New-TransportDecisionState 0 'a') 0 @((Event 0 'dial-fail')) $chainRows
$r=DecideSwitch $r.state 1000 @((Event 500 'path-check' 'a' 'timeout'),(Event 500 'path-check' 'b' 'timeout')) $chainRows
Assert ($r.verdict.action -eq 'probe-active' -and $r.state.episode.probed.a -eq 2) '9: первый повтор только активному'
$r=DecideSwitch $r.state 1001 @((Event 1001 'dial-fail'),(Event 1001 'dial-fail' 'b')) $chainRows
Assert ($r.verdict.action -eq 'stay') '9: повторные сигналы не выдают ещё один probe-round'
$r=DecideSwitch $r.state 3000 @((Event 2000 'path-check' 'a' 'timeout')) $chainRows
Assert ($r.verdict.action -eq 'probe-active' -and $r.state.episode.probed.a -eq 3) '9: второй и последний повтор активному'
$r=DecideSwitch $r.state 4000 @((Event 4000 'path-check' 'a' 'timeout'),(Event 4000 'path-check' 'b' 'timeout')) $chainRows
Assert ($r.verdict.action -eq 'stay' -and $r.state.episode.probed.a -eq 3 -and $r.state.episode.probed.b -eq 1 -and $r.state.episode.probed.c -eq 1) '9: повторов кандидатов и четвёртой активному нет'

# Пороги Q и все параметры политики замораживаются на эпизод целиком.
$next=@{stage1Ms=500;stage2Ms=1500;hardFailMs=2000;blipMs=6000;minStayMs=45000;improvementMs=80;improvementRatio=0.4;penaltyMs=@(7000,17000,47000,122000,302000)}
$r=DecideSwitch (New-TransportDecisionState 0 'a') 0 @((Event 0 'dial-fail')) $chainRows
$r=DecideSwitch $r.state 100 @(@{at=100;kind='net.quality';fields=$next}) $chainRows
Assert ($r.state.episode.policy.blipMs -eq 10000 -and $r.state.episode.policy.stage1Ms -eq 1000 -and $r.state.episode.policy.minStayMs -eq 30000) 'Q: обновление внутри эпизода не меняет снимок'
Assert ($r.state.switchPolicy.blipMs -eq 6000 -and $r.state.switchPolicy.penaltyMs[0] -eq 7000) 'Q: новая политика сохранена для следующего эпизода'
$r=DecideSwitch $r.state 101 @(@{at=50;kind='net.quality';fields=@{blipMs=4000}},@{at=500;kind='net.quality';fields=@{blipMs=5000}}) $chainRows
Assert ($r.state.switchPolicy.blipMs -eq 6000 -and $r.state.qualityAt -eq 100) 'Q: старый и будущий snapshot не заменяют последний принятый'
$r=DecideSwitch $r.state 200 @((Event 200 'path-check' 'a' 'ok')) $chainRows
$r=DecideSwitch $r.state 300 @((Event 300 'dial-fail'),(Event 300 'path-check' 'b' 'ok')) $chainRows
Assert ($r.state.episode.policy.stage1Ms -eq 500 -and $r.state.episode.policy.stage2Ms -eq 1500 -and $r.state.episode.policy.hardFailMs -eq 2000 -and $r.state.episode.policy.blipMs -eq 6000) 'Q: следующий эпизод принимает плоский snapshot Q'
Assert ($r.state.episode.policy.minStayMs -eq 45000 -and $r.state.episode.policy.improvementMs -eq 80 -and $r.state.episode.policy.improvementRatio -eq 0.4) 'Q: minStay и улучшение тоже параметры снимка'
$r=DecideSwitch $r.state 6300 @() $chainRows
Assert ($r.verdict.action -eq 'switch' -and $r.state.paths.a.until -eq 13300) 'Q: новая лестница используется при реальном решении'
$s=Copy-TransportDecisionValue $r.state
foreach($delay in @(17000,47000,122000,302000,302000)){
    Add-TransportDecisionPenalty $s 'a' 'path-dial-failed' 7000 7000
    Assert ($s.paths.a.until -eq 7000+$delay) 'Q: все пять ступеней лестницы параметризованы'
}
$r=DecideSwitch (New-TransportDecisionState 0 'a') 0 @((Event 0 'dial-fail')) $chainRows
$r=DecideSwitch $r.state 100 @() $chainRows 'a' $next
Assert ($r.state.episode.policy.blipMs -eq 10000 -and $r.state.switchPolicy.blipMs -eq 6000) 'Q: изменение SwitchConfig внутри эпизода тоже отложено'
$r=Invoke-TransportDecision -State $r.state -Candidates $chainRows -Now 200 -CurrentTag 'a' -Events @((Event 200 'path-check' 'a' 'ok')) -BlipMs 9000 -SwitchEpisode:$true
$r=Invoke-TransportDecision -State $r.state -Candidates $chainRows -Now 300 -CurrentTag 'a' -Events @((Event 300 'dial-fail')) -SwitchEpisode:$true
Assert ($r.state.episode.policy.blipMs -eq 9000) 'Q: скалярный параметр API сохраняется до нового эпизода'
$r=DecideSwitch $r.state 400 @(@{at=50;kind='net.quality';fields=@{blipMs=4000}},@{at=500;kind='net.quality';fields=@{blipMs=5000}}) $chainRows
Assert ($r.state.episode.policy.blipMs -eq 9000) 'Q: старый/будущий net.quality не меняет текущий снимок'

# Порядок Q важен и при общей пачке открытия.
$r=DecideSwitch (New-TransportDecisionState 0 'a') 2 @((Event 0 'dial-fail'),@{at=1;kind='net.quality';fields=$next}) $chainRows
Assert ($r.state.episode.policy.blipMs -eq 10000 -and $r.state.switchPolicy.blipMs -eq 6000) 'Q: качество после сигнала в той же пачке отложено'
$r=DecideSwitch (New-TransportDecisionState 0 'a') 2 @(@{at=0;kind='net.quality';fields=$next},(Event 1 'dial-fail')) $chainRows
Assert ($r.state.episode.policy.blipMs -eq 6000) 'Q: качество до сигнала в той же пачке применяется при открытии'

# Публичный snapshot настоящего Q из допустимого config: hardFail независим от stage2/blip.
foreach($switch in @(
    @{hardFailMs=@{default=1000;min=1000;max=10000}},
    @{stageMs=@(1,300000);blipMs=@{default=300000;min=1;max=300000};hardFailMs=@{default=1;min=1;max=300000}},
    @{stageMs=@(1,2);blipMs=@{default=2;min=1;max=300000};hardFailMs=@{default=300000;min=1;max=300000}}
)){
    $quality=New-TransportQualityState @{transport=@{switch=$switch}}
    $snapshot=Get-TransportQualitySnapshot $quality 0
    $r=DecideSwitch (New-TransportDecisionState 0 'a') 0 @((Event 0 'dial-fail')) $chainRows 'a' $snapshot
    foreach($name in @('stage1Ms','stage2Ms','hardFailMs','blipMs')){
        Assert ($r.state.episode.policy[$name] -eq $snapshot[$name]) ('Q/R: допустимый snapshot Q сохраняет '+$name)
    }
    $r=DecideSwitch (New-TransportDecisionState 0 'a') 1 @(@{at=0;kind='net.quality';fields=$snapshot},(Event 1 'dial-fail')) $chainRows
    Assert ($r.state.episode.policy.hardFailMs -eq $snapshot.hardFailMs -and $r.state.episode.policy.stage2Ms -eq $snapshot.stage2Ms) 'Q/R: тот же snapshot без подмены принимается через net.quality'
}

# Настоящий адаптивный Q: stage2 > blip допустимо после net.change mobile.
$quality=New-TransportQualityState @{transport=@{switch=@{blipMs=@{default=3000;min=3000;max=3000}}}}
$null=Update-TransportQuality $quality 'net.change' @{id='mobile-test';class='mobile'} 0
$snapshot=Get-TransportQualitySnapshot $quality 0
Assert ($snapshot.stage1Ms -eq 1500 -and $snapshot.stage2Ms -eq 4500 -and $snapshot.hardFailMs -eq 4500 -and $snapshot.blipMs -eq 3000) 'Q/C: адаптация mobile даёт настоящий снимок со stage2 выше blip'
$r=DecideSwitch (New-TransportDecisionState 0 'a') 0 @((Event 0 'dial-fail')) $chainRows 'a' $snapshot
foreach($name in @('stage1Ms','stage2Ms','hardFailMs','blipMs')){
    Assert ($r.state.switchPolicy[$name] -eq $snapshot[$name] -and $r.state.episode.policy[$name] -eq $snapshot[$name]) ('Q/C: SwitchConfig сохраняет адаптивный '+$name)
}
$r=DecideSwitch (New-TransportDecisionState 0 'a') 1 @(@{at=0;kind='net.quality';fields=$snapshot},(Event 1 'dial-fail')) $chainRows
foreach($name in @('stage1Ms','stage2Ms','hardFailMs','blipMs')){
    Assert ($r.state.switchPolicy[$name] -eq $snapshot[$name] -and $r.state.episode.policy[$name] -eq $snapshot[$name]) ('Q/C: net.quality сохраняет адаптивный '+$name)
}

# Ревью D: реальные крайние снимки после адаптации net.change.
foreach($case in @(
    @{class='fixed';switch=@{stageMs=@(1,2)};stage1=1;stage2=1},
    @{class='mobile';switch=@{stageMs=@(200000,300000);blipMs=@{default=300000;min=3000;max=300000}};stage1=300000;stage2=450000}
)){
    $quality=New-TransportQualityState @{transport=@{switch=$case.switch}}
    $null=Update-TransportQuality $quality 'net.change' @{id=('extreme-'+$case.class);class=$case.class} 0
    $snapshot=Get-TransportQualitySnapshot $quality 0
    Assert ($snapshot.stage1Ms -eq $case.stage1 -and $snapshot.stage2Ms -eq $case.stage2) 'Q/D: настоящий адаптивный снимок имеет ожидаемые крайние стадии'
    foreach($viaEvent in @($false,$true)){
        if($viaEvent){
            $r=DecideSwitch (New-TransportDecisionState 0 'a') 1 @(@{at=0;kind='net.quality';fields=($snapshot|ConvertTo-Json|ConvertFrom-Json)},(Event 1 'dial-fail')) $chainRows
        }else{
            $r=DecideSwitch (New-TransportDecisionState 0 'a') 0 @((Event 0 'dial-fail')) $chainRows 'a' $snapshot
        }
        foreach($name in @('stage1Ms','stage2Ms','hardFailMs','blipMs')){
            $expected=[Math]::Max(1L,[Math]::Min(300000L,[long]$snapshot[$name]))
            Assert ($r.state.switchPolicy[$name] -eq $expected -and $r.state.episode.policy[$name] -eq $expected) ('Q/D: крайний адаптивный '+$name+' сохраняется с clamp через оба входа')
        }
    }
}
$bad=@{stage1Ms='bad';stage2Ms=@{};hardFailMs=$null;blipMs=@{default='bad'}}
$r=DecideSwitch (New-TransportDecisionState 0 'a') 0 @((Event 0 'dial-fail')) $chainRows 'a' $bad
foreach($pair in @(@('stage1Ms',1000),@('stage2Ms',3000),@('hardFailMs',3000),@('blipMs',10000))){
    Assert ($r.state.episode.policy[$pair[0]] -eq $pair[1]) ('Q/D: мусор заменяется умолчанием для '+$pair[0])
}
$r=DecideSwitch (New-TransportDecisionState 0 'a') 0 @((Event 0 'dial-fail')) $chainRows 'a' @{stage1Ms=3000;stage2Ms=1000;hardFailMs=7000;blipMs=9000}
Assert ($r.state.episode.policy.stage1Ms -eq 1000 -and $r.state.episode.policy.stage2Ms -eq 3000 -and $r.state.episode.policy.hardFailMs -eq 7000 -and $r.state.episode.policy.blipMs -eq 9000) 'Q/D: неверный порядок стадий не сбрасывает остальные числовые пороги'

# §4б: ограничены накопленные словари/истории и рабочая пачка; старое удаляется.
$manyRows=@(1..270|ForEach-Object {Row ('p'+$_)})
$s=New-TransportDecisionState 0 'p270'
foreach($row in $manyRows){$s.paths[$row.tag]=New-TransportDecisionPath;$s.pending[$row.tag]=@{at=0;stage='path'}}
$s.paths.p1.exitTimes=@(1..100)
$s.history=@(1..1030|ForEach-Object {@{at=$_;tag='p1';before=(New-TransportDecisionPath)}})
$s.flapHistory=@(1..1030|ForEach-Object {@{at=$_;from='p1';to='p2'}})
$s.episode=New-TransportSwitchEpisode 0 0 'p270' (Get-TransportSwitchPolicy $null 1000 3000 10000 3000)
foreach($row in $manyRows){$s.episode.responded[$row.tag]=@{at=0;tag=$row.tag};$s.episode.probed[$row.tag]=1;$s.episode.attempted[$row.tag]=$true}
$r=DecideSwitch $s 2000 @() $manyRows 'p270'
Assert ($r.state.paths.Count -eq 256 -and $r.state.paths.ContainsKey('p270') -and $r.state.pending.Count -le 256) '4б: 256 кандидатов, активный сохраняется даже в конце входа'
Assert ($r.state.history.Count -eq 1024 -and $r.state.flapHistory.Count -eq 1024 -and $r.state.paths.p1.exitTimes.Count -eq 2) '4б: история и повторные exits имеют численный предел'
Assert ($r.state.episode.responded.Count -le 256 -and $r.state.episode.probed.Count -le 256 -and $r.state.episode.attempted.Count -le 256) '4б: результаты и попытки эпизода ограничены кандидатами'
Assert ($r.verdict.boundsOverflow) '4б: усечение видно в вердикте для журнала T2'
$r=DecideSwitch $r.state 2001 @() @((Row 'p270')) 'p270'
Assert ($r.state.paths.Count -eq 1 -and $r.state.history.Count -eq 0 -and $r.state.episode.responded.Count -le 1) '4б: удалённые кандидаты не накапливают штрафы и ответы'
$r=DecideSwitch (New-TransportDecisionState 0 'a') 1000 @(1..700|ForEach-Object {Event $_ 'engine-exit'}) $chainRows
Assert ($r.state.paths.a.exitTimes.Count -eq 2 -and $r.verdict.boundsOverflow) '4б: переполнение входной пачки ограничено и отражено в вердикте'

# JSON-состояние, чистота входов и никаких подробностей событий в результате.
$s=New-TransportDecisionState 0 'a';$events=@((Event 0 'dial-fail'));$before=ConvertTo-Json -InputObject @($s,$chainRows,$events) -Depth 30 -Compress
$r=DecideSwitch $s 0 $events $chainRows
Assert ((ConvertTo-Json -InputObject @($s,$chainRows,$events) -Depth 30 -Compress) -ceq $before) 'B: входное состояние/кандидаты/события не изменены'
$r=DecideSwitch ($r.state|ConvertTo-Json -Depth 30|ConvertFrom-Json) 1 @((Event 1 'path-check' 'b' 'ok')) $chainRows
Assert ($r.state.episode.responded.ContainsKey('b') -and -not (($r|ConvertTo-Json -Depth 30 -Compress) -match 'test-detail')) 'B: JSON round-trip и фиксированные поля без event detail'
Write-Host ('PASS: switch episode reducer, '+$count+' assertions; scenarios 1-9, Q snapshots and bounds')
