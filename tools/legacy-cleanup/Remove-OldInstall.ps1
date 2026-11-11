#requires -Version 5.1
# ВРЕМЕННЫЙ одноразовый инструмент: убирает старую (до RemoteAgents.exe) установку RemoteAgents/RemoteDisk.
# Показывает план и спрашивает «Удалить? (да/нет)». -Plan: только план. -Yes: без вопроса.
# Ничего не удаляет: папки, XML задач, .reg и значения автозапуска уходят в
# %LOCALAPPDATA%\RemoteAgents-old-backup-<время>\ (manifest.json), откат: Restore-OldInstall.cmd.
# Никогда не трогает ~\.ssh, файлы папки Disk и файлы новой RemoteAgents.exe.
# Коды: 0 готово/нечего делать, 1 часть шагов не удалась, 2 отменено, 3 ошибка.
param([switch]$Plan, [switch]$Yes, [string]$Adapter)
$ErrorActionPreference = 'Stop'
$L = $env:LOCALAPPDATA; $U = $env:USERPROFILE
$Disk = Join-Path $L 'RemoteDisk'; $Agents = Join-Path $L 'RemoteAgents'; $Control = Join-Path $Agents 'control'
$RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run'
$RegKeys = @('HKCU\Software\Classes\Directory\shell\RemoteDisk_add',
    'HKCU\Software\Classes\Directory\shell\AiServerSync', 'HKCU\Software\Classes\Directory\shell\AiServerUnsync',
    'HKCU\Software\Classes\Directory\Background\shell\AiServerSync', 'HKCU\Software\Classes\Directory\Background\shell\AiServerUnsync')
# Вызовы Windows (smoke-тест подменяет их через -Adapter)
function Invoke-Native([string]$Exe, [string[]]$A) {
    $ErrorActionPreference = 'Continue'; $o = & (Join-Path $env:SystemRoot ('System32\' + $Exe)) @A 2>&1
    [pscustomobject]@{ code = $LASTEXITCODE; out = (@($o | ForEach-Object { [string]$_ }) -join "`r`n") }
}
function Get-TaskNames { @('RemoteDiskChannel', 'RemoteDiskFolders', 'RemoteAgents rollback') + @(Get-ScheduledTask -TaskPath '\' -TaskName 'RemoteAgents-Recovery-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.TaskName }) }
function Get-Run([string]$N) { $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RunKey); if ($k) { try { $k.GetValue($N) } finally { $k.Dispose() } } }
function Remove-Run([string]$N) { $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RunKey, $true); if ($k) { try { $k.DeleteValue($N, $false) } finally { $k.Dispose() } } }
function Get-Procs { @(Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID }) }
if ($Adapter) { . ([IO.Path]::GetFullPath($Adapter)) }
function N([string]$P) { ([IO.Path]::GetFullPath($P)).Replace('/', '\').TrimEnd('\').ToLowerInvariant() }
function Test-Under([string]$Child, [string]$Parent) { $c = N $Child; $p = N $Parent; ($c -eq $p) -or $c.StartsWith($p + '\') }
try {
    # Новая программа живёт в том же %LOCALAPPDATA%\RemoteAgents и использует RemoteDisk: тогда общие папки не трогаем.
    $new = Test-Path -LiteralPath (Join-Path $Agents 'RemoteAgents.exe')
    $tasks = @(Get-TaskNames | Where-Object { (Invoke-Native 'schtasks.exe' @('/Query', '/TN', $_, '/XML')).code -eq 0 })
    $runs = @()
    $v = Get-Run 'RemoteDisk'; if ($v) { $runs += [pscustomobject]@{ name = 'RemoteDisk'; value = [string]$v } }
    $v = [string](Get-Run 'RemoteAgentsControl') # мост новой программы (managed-control, -LauncherHome) не трогаем
    if ($v -match 'Start-WindowsControl\.ps1' -and $v -notmatch 'managed-control|-LauncherHome') { $runs += [pscustomobject]@{ name = 'RemoteAgentsControl'; value = $v } }
    $keys = @($RegKeys | Where-Object { (Invoke-Native 'reg.exe' @('query', $_)).code -eq 0 })
    $tray = N (Join-Path (Join-Path $Disk 'tray') 'syncthingtray.exe'); $sb = N (Join-Path (Join-Path $Disk 'channel') 'sing-box.exe')
    $ctl = N (Join-Path (Join-Path $Control 'app') 'Start-WindowsControl.ps1'); $diskApp = (N (Join-Path $Disk 'app')) + '\'
    $procs = @(Get-Procs | Where-Object {
        $e = ''; if ($_.ExecutablePath) { $e = N $_.ExecutablePath }; $c = ([string]$_.CommandLine).Replace('/', '\').ToLowerInvariant()
        ($e -eq $tray -and (-not $new -or $c -notmatch '"?syncthing"?\s+"?serve')) -or ($e -eq $sb -and -not $new) -or $c.Contains($ctl) -or (-not $new -and $c.Contains($diskApp)) })
    $base = Join-Path $U 'Disk'; $bt = Join-Path $Disk 'base.txt'; if (Test-Path -LiteralPath $bt) { $base = ([IO.File]::ReadAllText($bt)).Trim([char]0xFEFF, ' ', "`r", "`n") }
    $protect = @($base, (Join-Path $U '.ssh'), (Join-Path $Agents 'ssh-profiles'))
    $folders = @(); $skipped = @()
    foreach ($f in $(if ($new) { @(Join-Path $Control 'app') } else { @($Disk, $Control) })) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        if (@($protect | Where-Object { (Test-Under $_ $f) -or (Test-Under $f $_) }).Count) { $skipped += $f } else { $folders += $f }
    }
    Write-Host 'Старая установка RemoteAgents / RemoteDisk:' -ForegroundColor Cyan
    if ($new) { Write-Host 'Найдена новая RemoteAgents.exe: общие с ней папки (RemoteDisk, control\config.json) оставляю.' -ForegroundColor Yellow }
    foreach ($t in $tasks) { Write-Host ('  задача планировщика: ' + $t) }
    foreach ($r in $runs) { Write-Host ('  автозапуск: ' + $r.name + ' = ' + $r.value) }
    foreach ($k in $keys) { Write-Host ('  меню Проводника: ' + $k) }
    foreach ($p in $procs) { Write-Host ('  процесс: PID ' + $p.ProcessId + ' ' + $p.Name) }
    foreach ($f in $folders) { Write-Host ('  папка (перенос в копию): ' + $f) }
    foreach ($f in $skipped) { Write-Host ('  папку НЕ переношу (внутри или рядом Disk/.ssh/ssh-profiles): ' + $f) -ForegroundColor Yellow }
    Write-Host ('Не трогаю: ' + ($protect -join ', ') + ', файлы новой RemoteAgents.exe, OpenVPN.') -ForegroundColor Cyan
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
    foreach ($r in $runs) { try { Remove-Run $r.name; $m.runs += $r; Save; Log ('Автозапуск удалён: ' + $r.name) } catch { $fail++; Log ('ОШИБКА, автозапуск ' + $r.name + ': ' + $_.Exception.Message) } }
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
        for ($a = 0; $a -lt 3; $a++) { try { [IO.Directory]::Move($f, (Join-Path $B $to)); $err = $null; break } catch { $err = $_.Exception.Message; Start-Sleep -Seconds 2 } }
        if ($err) { $fail++; Log ('ОШИБКА, папка ' + $f + ' (файлы заняты?): ' + $err) } else { $m.folders += [pscustomobject]@{ path = $f; backup = $to }; Save; Log ('Папка перенесена: ' + $f) }
    }
    Save; Log ('Резервная копия: ' + $B)
    if ($fail) { Log ('Ошибок: ' + $fail + '. Повторный запуск безопасен; вернуть всё: Restore-OldInstall.cmd'); exit 1 }
    Write-Host 'Готово. Теперь запустите release\RemoteAgents.exe. Если не заработает: Restore-OldInstall.cmd.' -ForegroundColor Green
    exit 0
} catch { Write-Host ('Ошибка: ' + $_.Exception.Message) -ForegroundColor Red; exit 3 }
