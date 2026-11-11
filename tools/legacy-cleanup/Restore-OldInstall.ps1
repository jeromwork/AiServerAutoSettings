#requires -Version 5.1
# ВРЕМЕННЫЙ одноразовый инструмент: возвращает старую установку из последней копии
# %LOCALAPPDATA%\RemoteAgents-old-backup-* (или -Backup <папка>) по manifest.json.
# Коды: 0 готово, 1 часть шагов не удалась, 2 отменено, 3 ошибка, 4 копия не найдена.
param([string]$Backup, [switch]$Yes)
$ErrorActionPreference = 'Stop'
function Invoke-Native([string]$Exe, [string[]]$A) {
    $ErrorActionPreference = 'Continue'; $o = & (Join-Path $env:SystemRoot ('System32\' + $Exe)) @A 2>&1
    [pscustomobject]@{ code = $LASTEXITCODE; out = (@($o | ForEach-Object { [string]$_ }) -join ' ') }
}
try {
    $B = $Backup
    if (-not $B) { $B = @(Get-ChildItem -LiteralPath $env:LOCALAPPDATA -Directory -Filter 'RemoteAgents-old-backup-*' | Where-Object { (Test-Path (Join-Path $_.FullName 'manifest.json')) -and -not (Test-Path (Join-Path $_.FullName 'restored.txt')) } | Sort-Object Name -Descending | Select-Object -First 1 | ForEach-Object { $_.FullName }) }
    if (-not $B -or -not (Test-Path -LiteralPath (Join-Path $B 'manifest.json'))) { Write-Host 'Невосстановленная резервная копия не найдена.' -ForegroundColor Yellow; exit 4 }
    $m = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $B 'manifest.json') | ConvertFrom-Json
    Write-Host ('Восстановление из ' + $B) -ForegroundColor Cyan
    foreach ($f in @($m.folders)) { Write-Host ('  ' + $f.path) }
    foreach ($k in @($m.regkeys)) { Write-Host ('  меню ' + $k.key) }
    foreach ($r in @($m.runs)) { Write-Host ('  значение ' + $r.name) }
    foreach ($t in @($m.tasks)) { Write-Host ('  задача ' + $t.name) }
    if (Get-Process -Name RemoteAgents -ErrorAction SilentlyContinue) { Write-Host 'Сначала закройте RemoteAgents.exe (значок в трее → Выход).' -ForegroundColor Yellow }
    if (-not $Yes -and @('да', 'д', 'yes', 'y', 'lf') -notcontains ([string](Read-Host 'Восстановить? (да/нет)')).Trim().ToLowerInvariant()) { Write-Host 'Отменено.'; exit 2 }
    $fail = 0
    foreach ($f in @($m.folders)) {
        try {
            if (-not (Test-Path -LiteralPath (Join-Path $B $f.backup))) { Write-Host ('Уже возвращена: ' + $f.path); continue }
            # Папку, созданную новой программой, не удаляем, а отодвигаем в эту же копию.
            if (Test-Path -LiteralPath $f.path) { $aside = Join-Path $B ('replaced-' + (Split-Path $f.path -Leaf) + '-' + (Get-Date -Format 'HHmmss')); Move-Item -LiteralPath $f.path -Destination $aside; Write-Host ('  текущая папка отодвинута в ' + $aside) -ForegroundColor Yellow }
            [void][IO.Directory]::CreateDirectory((Split-Path $f.path)); Move-Item -LiteralPath (Join-Path $B $f.backup) -Destination $f.path; Write-Host ('Возвращено: ' + $f.path)
        } catch { $fail++; Write-Host ('ОШИБКА, папка ' + $f.path + ': ' + $_.Exception.Message) -ForegroundColor Red }
    }
    foreach ($k in @($m.regkeys)) { $r = Invoke-Native 'reg.exe' @('import', (Join-Path $B $k.file)); if ($r.code) { $fail++; Write-Host ('ОШИБКА, меню ' + $k.key + ': ' + $r.out) -ForegroundColor Red } }
    $run = 'Software\Microsoft\Windows\CurrentVersion\Run'
    foreach ($r in @($m.runs)) {
        $kp = $run; $kind = 'String'; if ($r.key) { $kp = $r.key }; if ($r.kind) { $kind = $r.kind }
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($kp); try { $key.SetValue($r.name, $r.value, $kind) } finally { $key.Dispose() }
        Write-Host ('Значение возвращено: ' + $r.name)
    }
    foreach ($t in @($m.tasks)) {
        $r = Invoke-Native 'schtasks.exe' @('/Create', '/TN', $t.name, '/XML', (Join-Path $B $t.file), '/F')
        if ($r.code) { $fail++; Write-Host ('ОШИБКА, задача ' + $t.name + ': ' + $r.out) -ForegroundColor Red; continue }
        Write-Host ('Задача возвращена: ' + $t.name)
        if ($t.name -like 'RemoteDisk*') { [void](Invoke-Native 'schtasks.exe' @('/Run', '/TN', $t.name)) }
    }
    foreach ($r in @($m.runs | Where-Object { -not $_.key -or $_.key -like '*\Run' })) { [void](Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = [string]$r.value }) }
    if ($fail) { Write-Host ('Ошибок: ' + $fail + '. Исправьте причину и запустите снова с -Backup "' + $B + '".') -ForegroundColor Red; exit 1 }
    Set-Content -LiteralPath (Join-Path $B 'restored.txt') -Value (Get-Date).ToString('o')
    Write-Host 'Старая установка возвращена.' -ForegroundColor Green; exit 0
} catch { Write-Host ('Ошибка: ' + $_.Exception.Message) -ForegroundColor Red; exit 3 }
