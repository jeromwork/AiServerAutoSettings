#requires -Version 5.1
# Микро-тесты T0: выключатели диагностики, журнал памяти, предохранитель, кэш ревизии, статус только при изменении.
# Без реального времени и сети: счётчики вместо ожиданий.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
$count=0
function Assert($Condition,[string]$Message) {
    if(-not $Condition){throw ('Тест T0: '+$Message)}
    $script:count++
}
$work=Join-Path ([IO.Path]::GetTempPath()) ('transport-leak-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
try{
    # --- разбор RA_TRANSPORT_DIAG
    $f=Get-TransportDiagFlags ' No-Revision, gc-collect ,bogus,,STATUS-30S '
    Assert ($f.Count -eq 3 -and $f['no-revision'] -and $f['gc-collect'] -and $f['status-30s']) 'флаги: регистр, пробелы, неизвестные отброшены'
    Assert ((Get-TransportDiagFlags '').Count -eq 0 -and (Get-TransportDiagFlags $null).Count -eq 0) 'пустая переменная — без флагов'
    $script:TransportDiag=@{}
    Assert (-not (Test-TransportDiag 'no-revision')) 'без флагов выключателей нет'
    Assert ((Get-TransportMemIntervalSec) -eq 60) 'память: без диагностики раз в 60 с'
    $script:TransportDiag=Get-TransportDiagFlags 'no-revision'
    Assert ((Test-TransportDiag 'no-revision') -and -not (Test-TransportDiag 'no-metered')) 'флаг виден только свой'
    Assert ((Get-TransportMemIntervalSec) -eq 10) 'память: в диагностике раз в 10 с'

    # --- no-metered: WinRT-вызов не выполняется
    $script:costCalls=0
    function Get-TransportConnectionCost { $script:costCalls++; $true }
    $opts=[pscustomobject]@{metered='auto'}
    $script:TransportDiag=@{}
    Assert ((Get-TransportMetered $opts) -eq $true -and $script:costCalls -eq 1) 'metered: без флага вызывает опрос'
    $script:TransportDiag=Get-TransportDiagFlags 'no-metered'
    Assert ($null -eq (Get-TransportMetered $opts) -and $script:costCalls -eq 1) 'no-metered: опрос не вызывается'
    Assert ((Get-TransportMetered ([pscustomobject]@{metered='true'})) -eq $true -and $script:costCalls -eq 1) 'явный metered не зависит от опроса'

    # --- no-network: после первого результата опрос не повторяется
    $script:netCalls=0
    function Get-TransportNetworkProbe { $script:netCalls++; [pscustomobject]@{id='n'+$script:netCalls;available=$true} }
    $script:TransportDiag=@{};$script:TransportNetworkStub=$null
    [void](Get-TransportNetwork);[void](Get-TransportNetwork)
    Assert ($script:netCalls -eq 2) 'network: без флага опрос каждый раз'
    $script:TransportDiag=Get-TransportDiagFlags 'no-network';$script:netCalls=0
    $a=Get-TransportNetwork;$b=Get-TransportNetwork;$c=Get-TransportNetwork
    Assert ($script:netCalls -eq 0 -and $a.id -eq $b.id -and $b.id -eq $c.id) 'no-network: возвращается заглушка (последний результат), опроса нет'

    # --- gc-collect
    $script:TransportDiag=@{}
    $g0=[GC]::CollectionCount(0)
    Assert (-not (Invoke-TransportDiagGc) -and [GC]::CollectionCount(0) -eq $g0) 'gc-collect выключен: сборки нет'
    $script:TransportDiag=Get-TransportDiagFlags 'gc-collect'
    Assert ((Invoke-TransportDiagGc) -and [GC]::CollectionCount(0) -gt $g0) 'gc-collect включён: сборка выполнена'

    # --- решатель по событию или по tick
    $script:TransportDiag=@{}
    Assert (-not (Test-TransportDecisionDue 0 1000 2000)) 'решатель: нет событий и tick не наступил — не вызывается'
    Assert (Test-TransportDecisionDue 1 1000 2000) 'решатель: непустая очередь — вызывается'
    Assert (Test-TransportDecisionDue 0 2000 2000) 'решатель: tick наступил — вызывается'
    $script:TransportDiag=Get-TransportDiagFlags 'decide-every-tick'
    Assert (Test-TransportDecisionDue 0 1 2000) 'decide-every-tick возвращает старое поведение'

    # --- статус: при изменении или по сердцебиению
    $script:TransportDiag=@{}
    Assert (-not (Test-TransportStatusWrite 'k' 'k' 1000 5000)) 'статус: без изменений до сердцебиения не пишется'
    Assert (Test-TransportStatusWrite 'k' 'k' 5000 5000) 'статус: сердцебиение'
    Assert (Test-TransportStatusWrite 'k2' 'k' 0 5000) 'статус: изменение пишется сразу'
    Assert ((Get-TransportStatusIntervalSec 1) -eq 1) 'интервал статуса по умолчанию'
    $script:TransportDiag=Get-TransportDiagFlags 'status-30s'
    Assert ((Get-TransportStatusIntervalSec 1) -eq 30 -and -not (Test-TransportStatusWrite 'k' 'k' 6000 5000)) 'status-30s'
    $script:TransportDiag=Get-TransportDiagFlags 'status-always'
    Assert (Test-TransportStatusWrite 'k' 'k' 0 5000) 'status-always'
    $script:TransportDiag=@{}

    # --- строка transport.mem и предохранитель
    $sample=Get-TransportMemSample
    Assert ($sample.ws -gt 0 -and $sample.private -gt 0 -and $sample.gcHeap -gt 0 -and $sample.gen2 -ge 0) 'образец памяти заполнен'
    $fields=Get-TransportMemFields $sample 400
    $line=Format-RaLogLine ([DateTimeOffset]::Now) 'INFO' 'transport' 'transport.mem' $fields
    foreach($k in @('ws=','private=','gcHeap=','gen2=','limit=400')){Assert ($line.Contains($k)) ('transport.mem содержит '+$k)}
    Assert ($line.Contains('transport.mem')) 'transport.mem: имя события'
    Assert (-not (Test-TransportMemoryHigh (400L*1MB) 400) -and (Test-TransportMemoryHigh (401L*1MB) 400)) 'предохранитель: порог 400 МБ'
    Assert (-not (Test-TransportMemoryHigh (900L*1MB) 0)) 'предохранитель: 0 отключает'

    # --- диагностика строки статуса не больше 1 КБ
    $small=[pscustomobject]@{candidate='a';reason='timeout';stderr='short'}
    Assert ([object]::ReferenceEquals((Limit-TransportDiagnostic $small),$small)) 'малая диагностика не копируется'
    $big=[pscustomobject]@{candidate='a';reason='timeout';portConflict=$null;exitCode=1;stderr=('s'*5000);error=('e'*4000);engineStderr=('g'*3000)}
    $cut=Limit-TransportDiagnostic $big
    Assert ((ConvertTo-Json -InputObject $cut -Depth 6 -Compress).Length -le 1024) 'большая диагностика усечена до 1 КБ'
    Assert ($cut.candidate -eq 'a' -and $cut.reason -eq 'timeout') 'усечение сохраняет короткие поля'
    Assert ($null -eq (Limit-TransportDiagnostic $null)) 'пустая диагностика'

    # --- поле строки без накопления членов
    $row=[pscustomobject]@{tag='t'}
    Set-TransportRowField $row order 1
    $members=@($row.PSObject.Properties).Count
    for($i=0;$i -lt 500;$i++){Set-TransportRowField $row order $i}
    Assert ($row.order -eq 499 -and @($row.PSObject.Properties).Count -eq $members) 'Set-TransportRowField обновляет, не накапливая члены'

    # --- кэш ревизии по штампу файлов
    $h=Join-Path $work 'home';[void][IO.Directory]::CreateDirectory((Join-Path $h 'secrets/entries'))
    [IO.File]::WriteAllText((Join-Path $h 'profile.json'),'{"p":1}');[IO.File]::WriteAllText((Join-Path $h 'channel.json'),'{"c":1}')
    [IO.File]::WriteAllText((Join-Path $h 'secrets/entries/a.json'),'{"a":1}')
    $cfg=[ordered]@{transport=[ordered]@{profilePath=(Join-Path $h 'profile.json');channelPath=(Join-Path $h 'channel.json')}}
    [IO.File]::WriteAllText((Join-Path $h 'config.json'),(ConvertTo-Json -InputObject $cfg -Depth 5))
    $original=${function:Get-TransportRevisionInputs};$script:inputsCalls=0
    function Get-TransportRevisionInputs([string]$Root) { $script:inputsCalls++; & $original $Root }
    $state=@{}
    $r1=Get-TransportRevisionCached $h $state
    Assert ($r1 -ceq (Get-TransportRevision $h)) 'кэш: первая ревизия равна полной'
    $base=$script:inputsCalls
    $r2=Get-TransportRevisionCached $h $state;$r3=Get-TransportRevisionCached $h $state
    Assert ($r2 -ceq $r1 -and $r3 -ceq $r1 -and $script:inputsCalls -eq $base) 'кэш: без изменений на диске файлы не читаются'
    [IO.File]::WriteAllText((Join-Path $h 'profile.json'),'{"p":12345}')
    $r4=Get-TransportRevisionCached $h $state
    Assert ($r4 -cne $r1 -and $r4 -ceq (Get-TransportRevision $h) -and $script:inputsCalls -gt $base) 'кэш: изменение профиля пересчитывает ревизию'
    $base=$script:inputsCalls
    [IO.File]::WriteAllText((Join-Path $h 'secrets/entries/b.json'),'{"b":1}')
    $r5=Get-TransportRevisionCached $h $state
    Assert ($r5 -cne $r4 -and $r5 -ceq (Get-TransportRevision $h) -and $script:inputsCalls -gt $base) 'кэш: новый файл secrets/entries виден'
    $base=$script:inputsCalls
    [IO.File]::Delete((Join-Path $h 'secrets/entries/b.json'))
    $r6=Get-TransportRevisionCached $h $state
    Assert ($r6 -ceq $r4 -and $script:inputsCalls -gt $base) 'кэш: удаление файла secrets/entries видно'
    $base=$script:inputsCalls
    $cfg.transport['probePortBase']=26001;[IO.File]::WriteAllText((Join-Path $h 'config.json'),(ConvertTo-Json -InputObject $cfg -Depth 5))
    $r7=Get-TransportRevisionCached $h $state
    Assert ($r7 -cne $r6 -and $r7 -ceq (Get-TransportRevision $h) -and $script:inputsCalls -gt $base) 'кэш: изменение config.json видно'

    # --- Publish-TransportStatus: запись при изменении или по сердцебиению (функция берётся из демона по AST)
    $daemonPath=Join-Path $PSScriptRoot 'Transport.Daemon.ps1'
    $ast=[Management.Automation.Language.Parser]::ParseFile($daemonPath,[ref]$null,[ref]$null)
    foreach($fn in @($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Publish-TransportStatus','Get-DaemonTime')},$true))){. ([scriptblock]::Create($fn.Extent.Text))}
    $root=Join-Path $work 'statusroot';[void][IO.Directory]::CreateDirectory($root)
    $rows=@(1..3|ForEach-Object {[pscustomobject]@{tag=('p'+$_);title=('P'+$_);enabled=$true;state='ok';kbps=1;latencyMs=$_;priority=$_}})
    $paths=[pscustomobject]@{Outbounds=@();Candidates=@()};$active='p1';$confirmed=$true;$engine=$null;$network=$null;$reloadError=$null;$portConflict=$null;$stopping=$false;$exitCode=0
    $settings=$null;$errorText=$null;$verdict=$null;$decision=$null;$initialRound=$false;$pin=[pscustomobject]@{mode='auto';tag=$null};$metered=$null;$revision='r';$retryAt=[DateTime]::UtcNow
    $daemonStarted=[DateTime]::Now;$script:engineAttempted=$true;$script:checkingSince=$null;$script:lastStatus=[DateTime]::MinValue;$script:lastStatusKey=$null;$script:lastStatusWriteMs=[long]0;$StatusHeartbeatMs=5000
    $file=Join-Path $root 'status/transport.json'
    Publish-TransportStatus
    Assert ([IO.File]::Exists($file)) 'статус: первая запись есть'
    $first=[IO.File]::ReadAllText($file);$writeMs=$script:lastStatusWriteMs
    Publish-TransportStatus
    Assert ([IO.File]::ReadAllText($file) -ceq $first -and $script:lastStatusWriteMs -eq $writeMs) 'статус: без изменений файл не переписывается'
    $errorText='другое'
    Publish-TransportStatus
    Assert ((Read-TransportJson $file).error -eq 'другое') 'статус: изменение записано сразу'
    $second=[IO.File]::ReadAllText($file)
    $script:lastStatusWriteMs=$script:lastStatusWriteMs-6000
    Publish-TransportStatus
    $parsed=Read-TransportJson $file
    Assert ($parsed.updatedAt -and $parsed.error -eq 'другое' -and $script:lastStatusWriteMs -gt ((Get-DaemonTime)-5000)) 'статус: сердцебиение обновляет файл'
    $exitCode=75;Publish-TransportStatus
    Assert ((Read-TransportJson $file).fatal -eq $false) 'код 75 (перезапуск по памяти) не объявляется фатальным'
    $exitCode=1;Publish-TransportStatus
    Assert ((Read-TransportJson $file).fatal -eq $true) 'код 1 фатален'

    # --- все выключатели действительно используются в коде; демон содержит предохранитель и кэш
    $daemonText=[IO.File]::ReadAllText($daemonPath);$commonText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Transport.Common.ps1'))
    $reader=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-DaemonReader'},$true)[0].Extent.Text
    Assert ($reader.Contains("Test-TransportDiag 'no-connections'")) 'no-connections: читатель /connections не запускается'
    Assert ($daemonText.Contains("-not (Test-TransportDiag 'no-revision')") -and $daemonText.Contains('Get-TransportRevisionCached $root $revState')) 'no-revision: блок ревизии пропускается, ревизия кэшируется'
    foreach($flag in @('no-revision','status-30s','decide-on-event','no-connections','no-metered','no-network','gc-collect')){Assert ($script:TransportDiagKnown -contains $flag) ('известный выключатель '+$flag)}
    Assert ($daemonText.Contains('Test-TransportMemoryHigh $sample.private $memLimitMb') -and $daemonText.Contains('$exitCode=75') -and $daemonText.Contains('transport.mem-high')) 'предохранитель памяти: журнал и код 75'
    Assert ($daemonText.Contains('Предохранитель (конституция 4а)')) 'предохранитель: комментарий 4а'
    Assert ($daemonText.Contains('Test-TransportDecisionDue $eventQueue.Count')) 'решатель вызывается через проверку события/tick'
    Assert ($daemonText.Contains('Set-TransportProcessPriority $engine')) 'приоритет sing-box выставляется после запуска'
    $components=Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path $PSScriptRoot -Parent) 'build/components.json')|ConvertFrom-Json
    Assert (@($components.components|Where-Object {$_.name -eq 'transport' -and $_.priority -eq 'above-normal'}).Count -eq 1) 'components.json: приоритет демона выше обычного'
    Assert (-not (Set-TransportProcessPriority $null) -and -not (Set-TransportProcessPriority ([pscustomobject]@{Process=$null}))) 'приоритет: нет процесса — не ошибка'
    $schema=Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot 'config.schema.json')|ConvertFrom-Json
    Assert ($schema.properties.memSoftLimitMb.default -eq 400 -and $schema.properties.memSoftLimitMb.minimum -eq 64) 'схема: memSoftLimitMb'
    'transport leak tests passed: '+$count
}finally{try{[IO.Directory]::Delete($work,$true)}catch{}}
