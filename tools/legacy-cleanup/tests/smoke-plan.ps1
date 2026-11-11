# Smoke-тест (Linux, pwsh): план на временном поддельном профиле ничего не меняет.
# timeout 60 pwsh -NoProfile -NonInteractive -File tests/smoke-plan.ps1 < /dev/null
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('lc-smoke-' + [Guid]::NewGuid().ToString('N'))
$env:LOCALAPPDATA = Join-Path $root 'L'; $env:USERPROFILE = Join-Path $root 'U'
foreach ($f in @('L/RemoteDisk/tray/syncthingtray.exe', 'L/RemoteDisk/state/config.xml', 'L/RemoteAgents/control/app/Start-WindowsControl.ps1', 'L/RemoteAgents/ssh-profiles/s/key', 'U/.ssh/id_ed25519', 'U/Disk/p/file.txt')) {
    $p = Join-Path $root $f; [void][IO.Directory]::CreateDirectory((Split-Path $p)); [IO.File]::WriteAllText($p, 'x')
}
$tray = Join-Path $env:LOCALAPPDATA 'RemoteDisk/tray/syncthingtray.exe'
# Подмена Windows: только чтение разрешено, любое изменение — провал.
Set-Content (Join-Path $root 'adapter.ps1') @"
function Invoke-Native([string]`$Exe, [string[]]`$A) {
    if (`$A[0] -notin @('/Query', 'query')) { throw ('изменение в режиме плана: ' + `$Exe + ' ' + (`$A -join ' ')) }
    [pscustomobject]@{ code = [int](`$A[2] -ne 'RemoteDiskChannel' -and `$A[1] -notlike '*RemoteDisk_add'); out = '<Task/>' }
}
function Get-TaskNames { @('RemoteDiskChannel', 'RemoteDiskFolders') }
function Get-Run([string]`$N) { if (`$N -eq 'RemoteDisk') { '"$tray" --wait' } }
function Remove-Run([string]`$N) { throw 'изменение в режиме плана' }
function Get-Procs { @([pscustomobject]@{ ProcessId = 101; Name = 'syncthingtray.exe'; ExecutablePath = '$tray'; CommandLine = '"$tray" --wait' }, [pscustomobject]@{ ProcessId = 7; Name = 'notepad.exe'; ExecutablePath = '/x/notepad.exe'; CommandLine = 'notepad' }) }
"@
$tree = { (Get-ChildItem -Recurse -Force $root | ForEach-Object FullName | Sort-Object) -join "`n" }
$before = & $tree
$out = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File (Join-Path (Split-Path $PSScriptRoot) 'Remove-OldInstall.ps1') -Plan -Adapter (Join-Path $root 'adapter.ps1') 2>&1 | Out-String
$code = $LASTEXITCODE; Write-Host $out
$bad = @()
if ($code -ne 0) { $bad += "код $code" }
foreach ($w in @('задача планировщика: RemoteDiskChannel', 'автозапуск: RemoteDisk', 'RemoteDisk_add', 'PID 101', 'RemoteDisk', 'control', 'Режим просмотра')) { if (-not $out.Contains($w)) { $bad += "нет «$w»" } }
foreach ($w in @('RemoteDiskFolders', 'PID 7', 'ssh-profiles (перенос')) { if ($out.Contains("задача планировщика: $w") -or $out.Contains($w + ' notepad')) { $bad += "лишнее «$w»" } }
if ((& $tree) -ne $before) { $bad += 'файлы изменены' }
Remove-Item -Recurse -Force $root
if ($bad.Count) { Write-Host ('SMOKE FAIL: ' + ($bad -join '; ')) -ForegroundColor Red; exit 1 }
Write-Host 'SMOKE OK' -ForegroundColor Green
