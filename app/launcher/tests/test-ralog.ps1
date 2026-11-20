# Проверка PowerShell-копии единого формата журнала: те же фикстуры, что у C# (LoggingTests.cs).
# Запуск: pwsh -NoProfile -File app/launcher/tests/test-ralog.ps1 <корень-репозитория>
param([Parameter(Mandatory)][string]$Root)
$ErrorActionPreference='Stop'
$script:checks=0
function Assert($Condition,[string]$Name){if(-not $Condition){Write-Host ('FAIL: '+$Name);exit 1};$script:checks++}
. (Join-Path $Root 'transport/Transport.Common.ps1')
$fx=Join-Path $Root 'app/launcher/tests/fixtures/logging'
$utf8=New-Object Text.UTF8Encoding($false)

# 1. Формат: те же строки, что у C#.
$now=[DateTimeOffset]::new(2026,11,20,12,13,5,123,[TimeSpan]::FromHours(3))
$cases=@([IO.File]::ReadAllText((Join-Path $fx 'golden-cases.json'),$utf8)|ConvertFrom-Json)
$expected=@([IO.File]::ReadAllLines((Join-Path $fx 'golden-lines.txt'),$utf8))
Assert ($cases.Count -eq $expected.Count) 'число golden-случаев'
for($i=0;$i -lt $cases.Count;$i++){
    $c=$cases[$i];$fields=[ordered]@{};$index=0
    foreach($pair in $c.fields){
        $value=[string]$pair[1]
        if($c.PSObject.Properties['repeat'] -and $c.repeat.index -eq $index){$value=$c.repeat.text*[int]$c.repeat.count}
        $fields[[string]$pair[0]]=$value;$index++
    }
    $line=Format-RaLogLine $now $c.level $c.comp $c.evt $fields '7f3a'
    if($expected[$i] -eq '@long'){Assert ($line.Length -eq [int]$c.expectLength -and $line.EndsWith([string]$c.endsWith)) 'длинная строка обрезается'}
    else{Assert ($line -ceq $expected[$i]) ('golden '+$i+': '+$line)}
}

# 2. Маскирование: тот же файл, что у C# и Python.
foreach($c in @([IO.File]::ReadAllText((Join-Path $fx 'mask-cases.json'),$utf8)|ConvertFrom-Json)){
    $got=Protect-RaLogText ([string]$c.in)
    Assert ($got -ceq [string]$c.out) ('mask: '+$c.in+' -> '+$got)
}

# Длинные строки без разделителя не должны вызывать квадратичный поиск поля.
foreach($inputText in @(('.'*8192),('_-'*4000))){
    $null=Protect-RaLogText $inputText # прогрев JIT
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $got=Protect-RaLogText $inputText
    $watch.Stop()
    Assert ($got -ceq $inputText -and $watch.Elapsed.TotalMilliseconds -lt 50) ('mask linear <50ms: '+$watch.Elapsed.TotalMilliseconds)
}
# Литерал \n, настоящий перенос, кавычки и обратные слеши разбираются за один проход.
$value='path C:\new\name literal \n quote " and newline'+"`n"+'end'
$encoded=Format-RaLogLine $now 'INFO' 'transport' 'test' ([ordered]@{msg=$value}) '1234'
Assert ((ConvertFrom-RaLogLine $encoded).Text -ceq $value) 'quoted msg roundtrip'

# 3. Write-TransportLog: старое событие, новое событие, чужое имя, секрет.
$work=Join-Path ([IO.Path]::GetTempPath()) ('ra-ralog-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($work)
try{
    Write-TransportLog $work 'start'
    Write-TransportLog $work 'path.check' ([ordered]@{candidate='vless-direct';result='fail';reason='timeout'})
    Write-TransportLog $work 'password=do-not-log'
    Write-TransportLog $work 'fatal' 'Имена узлов должны быть уникальны @Transport.Common.ps1:12'
    $path=Join-Path $work 'logs/transport.log'
    $bytes=[IO.File]::ReadAllBytes($path)
    Assert ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'BOM при создании файла'
    $text=[IO.File]::ReadAllText($path,$utf8)
    $lines=@($text.TrimStart([char]0xFEFF) -split "`n"|Where-Object {$_})
    Assert ($lines[0] -match '^\d{4}-\d\d-\d\dT[\d:.]+Z \S+ INFO  transport start\s+s=[0-9a-f]{4}$') ('событие start: '+$lines[0])
    Assert ($lines[1] -match ' INFO  transport path\.check\s+s=[0-9a-f]{4} candidate=vless-direct result=fail reason=timeout$') 'новое событие не превращается в process-failed'
    Assert ($lines[2] -match ' WARN  transport process-failed ' -and $text -notmatch 'do-not-log') 'чужое имя события становится process-failed, секрет не пишется'
    Assert ($lines[3] -match ' ERROR transport fatal ' -and $lines[3].Contains('уникальны @Transport.Common.ps1:12')) 'fatal: уровень ERROR и своя причина'
    # Ротация .1…5 при 2 МБ.
    [IO.File]::WriteAllText($path,('x'*(2MB+1)))
    Write-TransportLog $work 'start'
    Assert ([IO.File]::Exists($path+'.1')) 'ротация в .1'
    for($n=0;$n -lt 7;$n++){[IO.File]::WriteAllText($path,('x'*(2MB+1)));Write-TransportLog $work 'start'}
    Assert ([IO.File]::Exists($path+'.5') -and -not [IO.File]::Exists($path+'.6')) 'не больше пяти архивов'
}finally{Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}

# 4. Экранирование инвентаря: вне ASCII -> \uXXXX, JSON возвращается без потерь.
$json=(@{Name='Беспроводная сеть'}|ConvertTo-Json -Compress)
$escaped=[regex]::Replace($json,'[^\x00-\x7F]',{param($m)('\u{0:x4}' -f [int][char]$m.Value)})
Assert ($escaped -cmatch '^[\x00-\x7F]+$') 'после экранирования только ASCII'
Assert ((($escaped|ConvertFrom-Json).Name) -ceq 'Беспроводная сеть') 'экранированный JSON читается обратно'
Write-Host ('PASS: test-ralog '+$script:checks+' checks')
