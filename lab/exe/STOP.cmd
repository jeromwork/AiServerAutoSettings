@echo off
rem RemoteAgents-Lab STOP: emergency switch. Needs no Python and no network, only cmd + PowerShell 5.1.
rem Everything after "exit /b" is PowerShell (UTF-8); cmd never reads past exit /b, so Russian text is safe.
chcp 65001 >nul
set "RA_SELF=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$f=[IO.File]::ReadAllText($env:RA_SELF,[Text.Encoding]::UTF8); $i=$f.LastIndexOf('#PS-BEGIN'); Invoke-Expression $f.Substring($i)"
exit /b
#PS-BEGIN
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
$labHome = Join-Path $env:LOCALAPPDATA 'RemoteAgents-lab'
$results = New-Object System.Collections.ArrayList

Write-Host ''
Write-Host '=== RemoteAgents-Lab: СТОП ===' -ForegroundColor Yellow
Write-Host 'Гашу лабораторные процессы, откатываю её системные изменения, сохраняю журнал и удаляю папку лаборатории.'
Write-Host 'Установленная RemoteAgents, её папка, ключи и ~\.ssh не затрагиваются.'
Write-Host ''

# Права администратора: лаборатория сама работает с ними, без них её не погасить. Просим один раз (UAC).
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Нужны права администратора, запрашиваю (окно UAC)...'
    try {
        Start-Process -FilePath $env:ComSpec -ArgumentList ('/c ""' + $env:RA_SELF + '""') -Verb RunAs -ErrorAction Stop
        exit
    } catch {
        Write-Host 'Права не получены. Продолжаю без них: процессы с правами администратора так не погасить.' -ForegroundColor Red
    }
}

# Каждый шаг выполняется, даже если предыдущий не удался.
function Step([string]$name, [scriptblock]$body) {
    Write-Host ''
    Write-Host ('--> ' + $name) -ForegroundColor Cyan
    try {
        & $body
        [void]$results.Add('готово    ' + $name)
    } catch {
        Write-Host ('    ошибка: ' + $_.Exception.Message) -ForegroundColor Red
        [void]$results.Add('ОШИБКА    ' + $name + ' (' + $_.Exception.Message + ')')
    }
}

Step '1. Гашу процессы лаборатории' {
    # Job Object гасит всех детей вместе с EXE; затем добиваем по пути/командной строке с папкой \RemoteAgents-lab\
    # (так находится и sing-box из папки установленной программы, запущенный с лабораторным конфигом).
    & cmd.exe /c 'taskkill.exe /F /T /IM RemoteAgents-Lab.exe >nul 2>&1'
    if ($LASTEXITCODE -eq 0) { Write-Host '    RemoteAgents-Lab.exe погашен' } else { Write-Host '    RemoteAgents-Lab.exe не запущен' }
    $all = @(Get-CimInstance Win32_Process)
    $byId = @{}
    foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
    $skip = @{}
    $cur = [int]$PID
    while ($byId.ContainsKey($cur) -and -not $skip.ContainsKey($cur)) { $skip[$cur] = $true; $cur = [int]$byId[$cur].ParentProcessId }   # сам скрипт и его родители (cmd) не трогаем
    $needle = '*\RemoteAgents-lab\*'
    $killed = 0
    foreach ($p in $all) {
        if ($skip.ContainsKey([int]$p.ProcessId)) { continue }
        if (($p.ExecutablePath -like $needle) -or ($p.CommandLine -like $needle)) {
            Write-Host ('    гашу ' + $p.Name + ' (pid ' + $p.ProcessId + ')')
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            $killed++
        }
    }
    Write-Host ('    добито процессов: ' + $killed)
}

Step '2a. Откатываю системные изменения по undo-файлам (в обратном порядке)' {
    $undo = Join-Path $labHome 'undo'
    if (-not (Test-Path -LiteralPath $undo)) { Write-Host '    undo-файлов нет'; return }
    $files = @(Get-ChildItem -LiteralPath $undo -Filter '*.cmd' -File | Sort-Object LastWriteTime, Name -Descending)
    if ($files.Count -eq 0) { Write-Host '    undo-файлов нет' }
    foreach ($f in $files) {
        Write-Host ('    undo: ' + $f.Name)
        try { & cmd.exe /c ('"' + $f.FullName + '"') | Out-Null } catch { Write-Host ('      ошибка: ' + $_.Exception.Message) -ForegroundColor Red }
    }
}

Step '2b. Страховочная уборка: адаптер RemoteAgents-Lab' {
    $adapters = @(Get-NetAdapter -Name 'RemoteAgents-Lab' -IncludeHidden -ErrorAction SilentlyContinue)
    if ($adapters.Count -eq 0) { Write-Host '    адаптера нет' }
    foreach ($a in $adapters) { & pnputil.exe /remove-device $a.PnPDeviceID | ForEach-Object { Write-Host ('    ' + $_) } }
}

Step '2c. Страховочная уборка: правила NRPT RemoteAgents-Lab:*' {
    $rules = @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { $_.Comment -like 'RemoteAgents-Lab:*' })
    if ($rules.Count -eq 0) { Write-Host '    правил нет' }
    foreach ($r in $rules) { Remove-DnsClientNrptRule -Name $r.Name -Force; Write-Host ('    удалено правило ' + $r.Name) }
}

Step '2d. Страховочная уборка: блок в hosts' {
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $text = [IO.File]::ReadAllText($hosts, [Text.Encoding]::UTF8)
    $clean = [regex]::Replace($text, '(?ms)^# RemoteAgents-Lab begin.*?^# RemoteAgents-Lab end[^\r\n]*(\r\n|\n|$)', '')
    if ($clean -ne $text) { [IO.File]::WriteAllText($hosts, $clean, (New-Object Text.UTF8Encoding($false))); Write-Host '    блок удалён' } else { Write-Host '    блока нет' }
}

Step '2e. Страховочная уборка: автозапуск (Run) и задачи планировщика' {
    foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run')) {
        $value = Get-ItemProperty -Path $key -Name 'RemoteAgents-Lab' -ErrorAction SilentlyContinue
        if ($value) { Remove-ItemProperty -Path $key -Name 'RemoteAgents-Lab' -ErrorAction Stop; Write-Host ('    удалено значение Run в ' + $key) }
    }
    $tasks = @(Get-ScheduledTask -TaskName 'RemoteAgents-Lab*' -ErrorAction SilentlyContinue)
    if ($tasks.Count -eq 0) { Write-Host '    задач планировщика нет' }
    foreach ($t in $tasks) { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false; Write-Host ('    удалена задача ' + $t.TaskName) }
}

Step '3. Сохраняю журнал на рабочий стол' {
    $logs = Join-Path $labHome 'logs'
    if (-not (Test-Path -LiteralPath $logs)) { Write-Host '    журнала нет'; return }
    $dst = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'RemoteAgents-Lab-журнал'
    if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
    New-Item -ItemType Directory -Path $dst | Out-Null
    $total = 0
    $limit = 20MB
    $list = @(Get-ChildItem -LiteralPath $logs -File | Sort-Object LastWriteTime -Descending)
    foreach ($extra in @('code\state.json', 'state\ranking.json')) {
        $path = Join-Path $labHome $extra
        if (Test-Path -LiteralPath $path) { $list += Get-Item -LiteralPath $path }
    }
    foreach ($f in $list) {
        if ($total + $f.Length -gt $limit) { Write-Host ('    пропущен (предел 20 МБ): ' + $f.Name); continue }
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dst $f.Name) -Force
        $total += $f.Length
    }
    Write-Host ('    сохранено в ' + $dst + ' (' + [int]($total / 1KB) + ' КБ)')
}

Step '4. Удаляю папку лаборатории' {
    if (-not (Test-Path -LiteralPath $labHome)) { Write-Host '    папки нет'; return }
    Remove-Item -LiteralPath $labHome -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $labHome) { & cmd.exe /c ('rd /s /q "' + $labHome + '" >nul 2>&1') }
    if (Test-Path -LiteralPath $labHome) { throw ('папка осталась (занята файлами), удалите вручную: ' + $labHome) }
    Write-Host ('    удалена ' + $labHome)
}

Write-Host ''
Write-Host '=== Итог ===' -ForegroundColor Yellow
foreach ($line in $results) { Write-Host ('  ' + $line) }
Write-Host ''
Write-Host 'Сам файл RemoteAgents-Lab.exe можно удалить вручную. Установленная RemoteAgents не тронута.'
Write-Host ''
Read-Host 'Нажмите Enter, чтобы закрыть окно'
