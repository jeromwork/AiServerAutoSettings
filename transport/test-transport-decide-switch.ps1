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

# (4) нет сети -> откат штрафов
$s = New-TransportDecisionState 0 'a'
$r = DecideSwitch $s 0 @((Event 0 'dial-fail' 'a')) $rows 'a'
# Сеть упала
$r = DecideSwitch $r.state 4000 @((Event 4000 'net-down' '')) $rows 'a'
Assert ($r.verdict.localNet -eq 'down') '4: локальная сеть down'
# На 10000 мс - решение при отсутствии сети
$r = DecideSwitch $r.state 10000 @() $rows 'a'
Assert ($r.verdict.action -eq 'stay' -and $r.verdict.tag -eq 'a') '4: при отсутствии сети вердикт stay'
Assert ($r.verdict.penalties.a.step -eq 0) '4: штрафы откатаны'
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
$r = DecideSwitch $r.state 500 @() $rows 'a' -Config $cfg
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

Write-Host ('PASS: switch episode reducer, '+$count+' assertions; all scenarios 1-5 verified')
