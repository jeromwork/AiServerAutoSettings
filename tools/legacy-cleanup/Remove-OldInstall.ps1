#requires -Version 5.1
# ВРЕМЕННЫЙ одноразовый инструмент: начисто убирает прежние установки RemoteAgents/RemoteDisk,
# включая ранние тестовые RemoteAgents.exe в %LOCALAPPDATA%\RemoteAgents.
# Показывает план и спрашивает «Удалить? (да/нет)». -Plan: только план. -Yes: без вопроса.
# Ничего не удаляет: папки, XML задач, .reg и значения автозапуска уходят в
# %LOCALAPPDATA%\RemoteAgents-old-backup-<время>\ (manifest.json), откат: Restore-OldInstall.cmd.
# Никогда не трогает ~\.ssh и папку Disk. Старые ключи сервера (ssh-profiles) тоже уходят в копию;
# в конце печатается путь ключа, который можно выбрать в новом мастере («Файл ключа…»).
# Коды: 0 готово/нечего делать, 1 часть шагов не удалась, 2 отменено, 3 ошибка.
param([switch]$Plan, [switch]$Yes, [string]$Adapter)
$ErrorActionPreference = 'Stop'
$L = $env:LOCALAPPDATA; $U = $env:USERPROFILE
$Disk = Join-Path $L 'RemoteDisk'; $Agents = Join-Path $L 'RemoteAgents'
$RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run'; $NavGuid = '{5D8A825B-EDEA-4B5E-97FC-96ABDC8A78E9}'
# Значения реестра (HKCU): автозапуск и скрытие значка Disk с рабочего стола (disk\Disk.NavPane.ps1)
$Values = @(@('RemoteDisk', 'RemoteAgents', 'RemoteAgentsControl', 'RemoteVPN') | ForEach-Object { , @($RunKey, $_) }) + @(, @('Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel', $NavGuid))
$RegKeys = @('HKCU\Software\Classes\Directory\shell\RemoteDisk_add',
    'HKCU\Software\Classes\Directory\shell\AiServerSync', 'HKCU\Software\Classes\Directory\shell\AiServerUnsync',
    'HKCU\Software\Classes\Directory\Background\shell\AiServerSync', 'HKCU\Software\Classes\Directory\Background\shell\AiServerUnsync',
    ('HKCU\Software\Classes\CLSID\' + $NavGuid), ('HKCU\Software\Classes\Wow6432Node\CLSID\' + $NavGuid),
    ('HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\' + $NavGuid))
# Вызовы Windows (smoke-тест подменяет их через -Adapter)
function Invoke-Native([string]$Exe, [string[]]$A) {
    $ErrorActionPreference = 'Continue'; $o = & (Join-Path $env:SystemRoot ('System32\' + $Exe)) @A 2>&1
    [pscustomobject]@{ code = $LASTEXITCODE; out = (@($o | ForEach-Object { [string]$_ }) -join "`r`n") }
}
function Get-TaskNames { @('RemoteDiskChannel', 'RemoteDiskFolders') + @(Get-ScheduledTask -TaskPath '\' -TaskName 'RemoteAgents*' -ErrorAction SilentlyContinue | ForEach-Object { $_.TaskName }) }
function Get-Val([string]$K, [string]$N) { $h = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($K); if ($h) { try { $v = $h.GetValue($N, $null, 'DoNotExpandEnvironmentNames'); if ($null -ne $v) { [pscustomobject]@{ key = $K; name = $N; value = $v; kind = [string]$h.GetValueKind($N) } } } finally { $h.Dispose() } } }
function Remove-Val([string]$K, [string]$N) { $h = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($K, $true); if ($h) { try { $h.DeleteValue($N, $false) } finally { $h.Dispose() } } }
function Get-Parent { try { [int](Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId } catch { 0 } }
function Get-Procs { @(Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID }) }
if ($Adapter) { . ([IO.Path]::GetFullPath($Adapter)) }
function N([string]$P) { ([IO.Path]::GetFullPath($P)).Replace('/', '\').TrimEnd('\').ToLowerInvariant() }
function Test-Under([string]$Child, [string]$Parent) { $c = N $Child; $p = N $Parent; ($c -eq $p) -or $c.StartsWith($p + '\') }
try {
    $tasks = @(Get-TaskNames | Select-Object -Unique | Where-Object { (Invoke-Native 'schtasks.exe' @('/Query', '/TN', $_, '/XML')).code -eq 0 })
    $runs = @($Values | ForEach-Object { Get-Val $_[0] $_[1] })
    $keys = @($RegKeys | Where-Object { (Invoke-Native 'reg.exe' @('query', $_)).code -eq 0 })
    $base = Join-Path $U 'Disk'; $bt = Join-Path $Disk 'base.txt'; if (Test-Path -LiteralPath $bt) { $base = ([IO.File]::ReadAllText($bt)).Trim([char]0xFEFF, ' ', "`r", "`n") }
    $protect = @($base, (Join-Path $U '.ssh'))
    # Всё, что запущено из RemoteAgents/RemoteDisk или ссылается на них, кроме себя, своего окна и запущенного из Disk (release\RemoteAgents.exe).
    $roots = @(((N $Agents) + '\'), ((N $Disk) + '\')); $self = @($PID, (Get-Parent))
    $procs = @(Get-Procs | Where-Object {
        $e = ''; if ($_.ExecutablePath) { $e = (N $_.ExecutablePath) }; $c = ([string]$_.CommandLine).Replace('/', '\').ToLowerInvariant()
        $self -notcontains [int]$_.ProcessId -and -not ($e -and (Test-Under $_.ExecutablePath $base)) -and @($roots | Where-Object { $e.StartsWith($_) -or $c.Contains($_) }).Count })
    $folders = @(); $skipped = @()
    $cands = @($Disk) + @(Get-ChildItem -LiteralPath $Agents -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    foreach ($f in $cands) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        if (@($protect | Where-Object { (Test-Under $_ $f) -or (Test-Under $f $_) }).Count) { $skipped += $f } else { $folders += $f }
    }
    Write-Host 'Старая установка RemoteAgents / RemoteDisk:' -ForegroundColor Cyan
    foreach ($t in $tasks) { Write-Host ('  задача планировщика: ' + $t) }
    foreach ($r in $runs) { Write-Host ('  значение реестра: ' + $r.name + ' = ' + $r.value) }
    foreach ($k in $keys) { Write-Host ('  ключ реестра (меню/значок Disk): ' + $k) }
    foreach ($p in $procs) { Write-Host ('  процесс: PID ' + $p.ProcessId + ' ' + $p.Name) }
    foreach ($f in $folders) { Write-Host ('  перенос в копию: ' + $f) }
    foreach ($f in $skipped) { Write-Host ('  папку НЕ переношу (внутри или рядом Disk/.ssh): ' + $f) -ForegroundColor Yellow }
    Write-Host ('Не трогаю: ' + ($protect -join ', ') + ', OpenVPN.') -ForegroundColor Cyan
    if (-not ($tasks.Count + $runs.Count + $keys.Count + $procs.Count + $folders.Count)) { Write-Host 'Старая установка не найдена — удалять нечего.' -ForegroundColor Green; exit 0 }
    if ($Plan) { Write-Host 'Режим просмотра: ничего не изменено.' -ForegroundColor Yellow; exit 0 }
    if (-not $Yes -and @('да', 'д', 'yes', 'y', 'lf') -notcontains ([string](Read-Host 'Удалить? (да/нет)')).Trim().ToLowerInvariant()) { Write-Host 'Отменено, ничего не изменено.'; exit 2 }

    $B = Join-Path $L ('RemoteAgents-old-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss')); [void][IO.Directory]::CreateDirectory($B)
    $log = Join-Path $B 'cleanup.log'; $fail = 0
    function Log([string]$T) { Write-Host $T; Add-Content -LiteralPath $log -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $T) -Encoding UTF8 }
    $m = [ordered]@{ created = (Get-Date).ToString('o'); computer = $env:COMPUTERNAME; tasks = @(); runs = @(); regkeys = @(); folders = @() }
    function Save { $m | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $B 'manifest.json') -Encoding UTF8 }
    $i = 0
    foreach ($t in $tasks) { # задачи первыми: иначе повтор каждую минуту снова поднимет канал
        try {
            $i++; $file = 'task-' + $i + '.xml'; $r = Invoke-Native 'schtasks.exe' @('/Query', '/TN', $t, '/XML'); [void][xml]$r.out
            [IO.File]::WriteAllText((Join-Path $B $file), $r.out, [Text.Encoding]::Unicode)
            [void](Invoke-Native 'schtasks.exe' @('/End', '/TN', $t)); $r = Invoke-Native 'schtasks.exe' @('/Delete', '/TN', $t, '/F'); if ($r.code) { throw $r.out }
            $m.tasks += [pscustomobject]@{ name = $t; file = $file }; Save; Log ('Задача удалена: ' + $t)
        } catch { $fail++; Log ('ОШИБКА, задача ' + $t + ': ' + $_.Exception.Message) }
    }
    foreach ($r in $runs) { try { Remove-Val $r.key $r.name; $m.runs += $r; Save; Log ('Значение удалено: ' + $r.name) } catch { $fail++; Log ('ОШИБКА, значение ' + $r.name + ': ' + $_.Exception.Message) } }
    foreach ($p in $procs) { [void](Invoke-Native 'taskkill.exe' @('/T', '/F', '/PID', [string]$p.ProcessId)); Log ('Остановлен: PID ' + $p.ProcessId + ' ' + $p.Name) }
    if ($procs.Count) { Start-Sleep -Seconds 2 }
    foreach ($k in $keys) {
        try {
            $i++; $file = 'reg-' + $i + '.reg'; $r = Invoke-Native 'reg.exe' @('export', $k, (Join-Path $B $file), '/y'); if ($r.code) { throw $r.out }
            $r = Invoke-Native 'reg.exe' @('delete', $k, '/f'); if ($r.code) { throw $r.out }
            $m.regkeys += [pscustomobject]@{ key = $k; file = $file }; Save; Log ('Пункт меню удалён: ' + $k)
        } catch { $fail++; Log ('ОШИБКА, меню ' + $k + ': ' + $_.Exception.Message) }
    }
    foreach ($f in $folders) {
        $i++; $to = 'folder-' + $i + '-' + (Split-Path $f -Leaf); $err = $null
        for ($a = 0; $a -lt 3; $a++) { try { Move-Item -LiteralPath $f -Destination (Join-Path $B $to); $err = $null; break } catch { $err = $_.Exception.Message; Start-Sleep -Seconds 2 } }
        if ($err) { $fail++; Log ('ОШИБКА, перенос ' + $f + ' (файлы заняты?): ' + $err) } else { $m.folders += [pscustomobject]@{ path = $f; backup = $to }; Save; Log ('Перенесено: ' + $f) }
    }
    Save; Log ('Резервная копия: ' + $B)
    foreach ($k in @(Get-ChildItem -LiteralPath $B -Recurse -File -Filter 'id_ed25519' -ErrorAction SilentlyContinue)) { Log ('Ключ для входа на сервер (в мастере «Файл ключа…»): ' + $k.FullName) }
    if ($fail) { Log ('Ошибок: ' + $fail + '. Повторный запуск безопасен; вернуть всё: Restore-OldInstall.cmd'); exit 1 }
    Write-Host 'Готово. Теперь запустите release\RemoteAgents.exe. Если не заработает: Restore-OldInstall.cmd.' -ForegroundColor Green
    exit 0
} catch { Write-Host ('Ошибка: ' + $_.Exception.Message) -ForegroundColor Red; exit 3 }
