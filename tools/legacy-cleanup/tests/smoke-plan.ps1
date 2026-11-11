# Smoke-тест (Linux, pwsh): план на временном поддельном профиле ничего не меняет.
# timeout 60 pwsh -NoProfile -NonInteractive -File tests/smoke-plan.ps1 < /dev/null
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('lc-smoke-' + [Guid]::NewGuid().ToString('N'))
$env:LOCALAPPDATA = Join-Path $root 'L'; $env:USERPROFILE = Join-Path $root 'U'
foreach ($f in @('L/RemoteDisk/tray/syncthingtray.exe', 'L/RemoteAgents/RemoteAgents.exe', 'L/RemoteAgents/config.json', 'L/RemoteAgents/control/app/Start-WindowsControl.ps1', 'L/RemoteAgents/ssh-profiles/s/key', 'U/.ssh/id_ed25519', 'U/Disk/p/file.txt', 'U/Disk/release/RemoteAgents.exe')) {
    $p = Join-Path $root $f; [void][IO.Directory]::CreateDirectory((Split-Path $p)); [IO.File]::WriteAllText($p, 'x')
}
$L = $env:LOCALAPPDATA; $tray = "$L/RemoteDisk/tray/syncthingtray.exe"; $exe = "$L/RemoteAgents/RemoteAgents.exe"; $rel = "$env:USERPROFILE/Disk/release/RemoteAgents.exe"
# Подмена Windows: только чтение разрешено, любое изменение — провал.
Set-Content (Join-Path $root 'adapter.ps1') @"
function Invoke-Native([string]`$Exe, [string[]]`$A) {
    if (`$A[0] -notin @('/Query', 'query')) { throw ('изменение в режиме плана: ' + `$Exe + ' ' + (`$A -join ' ')) }
    [pscustomobject]@{ code = [int](`$A[2] -ne 'RemoteDiskChannel' -and `$A[1] -notlike '*CLSID*'); out = '<Task/>' }
}
function Get-TaskNames { @('RemoteDiskChannel', 'RemoteDiskFolders') }
function Get-Val([string]`$K, [string]`$N) { if (`$N -in 'RemoteDisk', 'RemoteAgents') { [pscustomobject]@{ key = `$K; name = `$N; value = 'x'; kind = 'String' } } }
function Remove-Val { throw 'изменение в режиме плана' }
function Get-Parent { 0 }
function Get-Procs { @(
    [pscustomobject]@{ ProcessId = 101; Name = 'syncthingtray.exe'; ExecutablePath = '$tray'; CommandLine = 'tray' },
    [pscustomobject]@{ ProcessId = 102; Name = 'RemoteAgents.exe'; ExecutablePath = '$exe'; CommandLine = 'x --tray' },
    [pscustomobject]@{ ProcessId = 103; Name = 'ssh.exe'; ExecutablePath = '/win/ssh.exe'; CommandLine = 'ssh -F "$L/RemoteAgents/ssh-profiles/s/config" srv' },
    [pscustomobject]@{ ProcessId = 201; Name = 'RemoteAgents.exe'; ExecutablePath = '$rel'; CommandLine = '"$rel" --home "$L/RemoteAgents"' },
    [pscustomobject]@{ ProcessId = 202; Name = 'notepad.exe'; ExecutablePath = '/x/notepad.exe'; CommandLine = 'notepad' }) }
"@
$tree = { (Get-ChildItem -Recurse -Force $root | ForEach-Object FullName | Sort-Object) -join "`n" }
$before = & $tree
$out = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File (Join-Path (Split-Path $PSScriptRoot) 'Remove-OldInstall.ps1') -Plan -Adapter (Join-Path $root 'adapter.ps1') 2>&1 | Out-String
$code = $LASTEXITCODE; Write-Host $out
$bad = @()
if ($code -ne 0) { $bad += "код $code" }
foreach ($w in @('задача планировщика: RemoteDiskChannel', 'значение реестра: RemoteDisk', 'значение реестра: RemoteAgents', 'CLSID', 'PID 101', 'PID 102', 'PID 103', ('копию: ' + (Join-Path $L 'RemoteDisk')), 'RemoteAgents.exe', 'config.json', 'control', 'Режим просмотра')) { if (-not $out.Contains($w)) { $bad += "нет «$w»" } }
foreach ($w in @('RemoteDiskFolders', 'PID 201', 'PID 202', ('копию: ' + (Join-Path $L 'RemoteAgents/ssh-profiles')), ('копию: ' + $env:USERPROFILE))) { if ($out.Contains($w)) { $bad += "лишнее «$w»" } }
if ((& $tree) -ne $before) { $bad += 'файлы изменены' }
Remove-Item -Recurse -Force $root
if ($bad.Count) { Write-Host ('SMOKE FAIL: ' + ($bad -join '; ')) -ForegroundColor Red; exit 1 }
Write-Host 'SMOKE OK' -ForegroundColor Green
