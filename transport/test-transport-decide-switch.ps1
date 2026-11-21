#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Transport.Decide.ps1')

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
    return Invoke-TransportSwitchEpisode -State $State -Candidates $Rows -Now $Now -Events $Events -CurrentTag $Current -SwitchConfig $Config
}

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
Assert ($r.verdict.localNet -eq 'down' -and $r.verdict.penalties.a.step -eq 1) '4: новый эпизод хранит net-down и прежний штраф'
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
Assert ($r.verdict.action -eq 'probe-active') '5: на 1000 мс probe-active'
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

# Ревью 2: закрытый эпизод не включает новый решатель; общая логика сохраняется.
$s=New-TransportDecisionState 0 'a'
$r=DecideSwitch $s 0 @((Event 0 'dial-fail')) $rows
$r=DecideSwitch $r.state 1 @((Event 1 'path-check' 'a' 'ok')) $rows
$r=Invoke-TransportDecision -State $r.state -Candidates $rows -Now 2 -CurrentTag 'a' -Events @((Event 2 'dial-fail'))
Assert ($r.verdict.action -eq 'check-direct' -and $r.state.pending.ContainsKey('a')) '2R: после закрытия без флага работает pending/check-direct'
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
$r=Invoke-TransportDecision -State $s -Candidates @((Row 'a')) -Now 5000 -CurrentTag 'a'
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
Assert ($r.verdict.action -eq 'check-direct' -and $r.verdict.tag -eq 'b') '3R: отложенный direct действительно возвращается следующим вызовом'

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
Assert ($r.verdict.action -eq 'switch') '7R: задержка доставки не сдвигает эпизод'
$r=DecideSwitch (New-TransportDecisionState 0 'a') 100 @((Event 99 'path-check' 'a' 'ok'), (Event 100 'dial-fail')) $rows
Assert ($r.state.episode.open) '7R: старый успех не закрывает новый эпизод'
$r=DecideSwitch (New-TransportDecisionState 0 'a') 0 @((Event 0 'engine-exit')) $rows
Assert (-not $r.state.episode.hardFail -and $r.state.paths.a.exitTimes.Count -eq 1) '8R: одиночный выход учитывается ровно один раз'
$r=DecideSwitch $r.state 1000 @() $rows
Assert ($r.verdict.action -eq 'stay') '8R: нет дублирующей пробы до провала первой'
$r=DecideSwitch $r.state 3000 @((Event 2000 'path-check' 'a' 'timeout')) $rows
Assert ($r.verdict.action -eq 'probe-active') '8R: полученный провал разрешает повтор активного'

# Ревью 9: скаляры, default=0, границы, неверные типы и порядок безопасны.
Assert ((Get-TransportSwitchThreshold -5 10000) -eq 100) '9R: отрицательный порог ограничен снизу'
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

Write-Host ('PASS: switch episode reducer, '+$count+' assertions; scenarios 1-5 and review regressions')
