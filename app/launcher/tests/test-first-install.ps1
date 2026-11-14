#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$env:LOCALAPPDATA=$TestHome
$root=Join-Path $TestHome 'RemoteAgents'
[void][IO.Directory]::CreateDirectory($root)
. (Join-Path $repo 'build/Setup.Common.ps1')
$count=0
function Assert($ok,$name){if(-not $ok){throw ('FAIL '+$name)};$script:count++}
Assert ((Find-InstallProfile $root) -eq '') 'empty home has no SSH profile'
$own=Join-Path $root 'ssh-profiles/a/project-connections/server/ssh-transport.json';[void][IO.Directory]::CreateDirectory((Split-Path $own -Parent))
[IO.File]::WriteAllText($own,'{"sshExecutable":"fixture","arguments":["-T","example.invalid"]}'+"`r`n")
Assert ((Find-InstallProfile $root) -eq $own) 'single profile of this home is found'
Write-TransportJson (Join-Path $root 'config.json') @{wizard=@{pendingProfile='pending.json'};transport=@{profilePath='saved.json'}}
Assert ((Find-InstallProfile $root) -eq 'pending.json') 'pending wizard profile wins'
Write-TransportJson (Join-Path $root 'config.json') @{transport=@{profilePath='saved.json'}}
Assert ((Find-InstallProfile $root) -eq 'saved.json') 'configured profile is used'
Remove-Item -LiteralPath (Join-Path $root 'config.json')
# Exercise real headless start against a local fake executable, never Syncthing/Windows.
. (Join-Path $repo 'disk/Disk.Common.ps1')
. (Join-Path $repo 'disk/Disk.Engine.ps1')
$script:DiskHome=Join-Path $TestHome 'engine'
[void][IO.Directory]::CreateDirectory((Join-Path $script:DiskHome 'tray'))
$exe=Join-Path $script:DiskHome 'tray/syncthingtray.exe'
$shell='#!/bin/sh'+"`n"+'printf ''%s\n'' "$@" > "'+$TestHome+'/engine-args"'+"`n"+'sleep 30'+"`n"
[IO.File]::WriteAllText($exe,$shell)
& chmod +x $exe
$script:foreign=$false
function Get-DiskEngineProcesses($Root){if($script:foreign){[pscustomobject]@{ProcessId=123}}}
try{
    Start-DiskHeadless;$first=$script:DiskEngine.Id
    Start-DiskHeadless
    Assert ($script:DiskEngine.Id -eq $first) 'headless owner reuses one process'
    Start-Sleep -Milliseconds 150
    $arguments=[IO.File]::ReadAllLines((Join-Path $TestHome 'engine-args'))
    Assert ($arguments[0] -eq 'syncthing' -and $arguments[1] -eq 'serve' -and '--no-browser' -in $arguments -and '--no-restart' -in $arguments -and '--wait' -notin $arguments) 'embedded Syncthing runs without tray against existing state'
}finally{if($script:DiskEngine){$script:DiskEngine.Kill();$script:DiskEngine.WaitForExit();$script:DiskEngine.Dispose();$script:DiskEngine=$null}}
$script:foreign=$true
$script:restPolls=0
function Invoke-DiskApi($Route){$script:restPolls++;if($script:restPolls -lt 3){throw 'REST is starting'};@{myID='LOCAL'}}
Start-DiskHeadless
Assert ($script:restPolls -eq 3 -and $null -eq $script:DiskEngine) 'existing Tray engine waits for REST without launching a second process'
function Invoke-DiskApi {throw 'REST is unavailable'}
$readyWatch=[Diagnostics.Stopwatch]::StartNew();$failed=$false
try{Wait-DiskEngineReady -TimeoutSeconds 1}catch{$failed=$_.Exception.Message -like 'Syncthing уже запущен, но REST не ответил*'}
Assert ($failed -and $readyWatch.Elapsed.TotalSeconds -ge 1 -and $readyWatch.Elapsed.TotalSeconds -lt 3) 'REST wait is bounded and reports the unavailable running engine'


# Inspect and stop only GUI + the exact existing state; another state is untouched.
. (Join-Path $repo 'disk/Disk.Engine.ps1')
$script:inventory=@(
    [pscustomobject]@{ProcessId=1000001;ExecutablePath=$exe;CommandLine=((Quote-Disk $exe)+' "syncthing" "serve" "--home" '+(Quote-Disk (Join-Path $script:DiskHome 'state')));CreationDate='fixture'},
    [pscustomobject]@{ProcessId=1000002;ExecutablePath=$exe;CommandLine=((Quote-Disk $exe)+' --wait');CreationDate='fixture'},
    [pscustomobject]@{ProcessId=1000003;ExecutablePath=$exe;CommandLine=((Quote-Disk $exe)+' syncthing serve --home '+(Quote-Disk (Join-Path $TestHome 'other-state')));CreationDate='fixture'})
function Get-CimInstance($ClassName,$Filter,$ErrorAction){if($Filter){$script:inventory|Where-Object {('ProcessId='+$_.ProcessId) -eq $Filter}}else{$script:inventory}}
$script:stopped=@()
function Stop-Process($Id,[switch]$Force,$ErrorAction){$script:stopped+=@($Id);$script:inventory=@($script:inventory|Where-Object {$_.ProcessId -ne $Id})}
Assert (@(Get-DiskEngineProcesses $script:DiskHome).Count -eq 2) 'inventory isolates exact state and adjacent GUI'
Stop-DiskEngineProcesses $script:DiskHome
Assert (($script:stopped -join ',') -eq '1000002,1000001') 'stop ends GUI before embedded engine'
Assert ($script:inventory.Count -eq 1 -and $script:inventory[0].ProcessId -eq 1000003) 'different Syncthing state untouched'
# Managed bridge cleanup is scoped to this Home and never touches a configured installation.
. (Join-Path $repo 'Start-WindowsControl.ps1') -LibraryOnly
$command='powershell.exe -NoProfile -File "'+(Join-Path $root 'managed-control/app/version/Start-WindowsControl.ps1')+'" -LauncherHome "'+$root+'"'
Assert (Test-ManagedControlCommand $command $root) 'owned bridge command matches exact Home'
Assert (-not (Test-ManagedControlCommand $command ($root+'-other'))) 'different Home is not owned'
Assert (-not (Test-ManagedControlCommand ($command.Replace('managed-control/app','control/app')) $root)) 'original control is not owned'
$script:bridgeCommand=$command;$script:removedRun=0;$script:bridgeStopped=0
function Get-ItemProperty($Path,$Name,$ErrorAction){[pscustomobject]@{RemoteAgentsControl=$script:bridgeCommand}}
function Remove-ItemProperty($Path,$Name,$ErrorAction){$script:removedRun++}
function Get-CimInstance($ClassName,$Filter,$ErrorAction){[pscustomobject]@{CommandLine=$script:bridgeCommand}}
function Stop-ControlInstance($PidFile){$script:bridgeStopped++}
$pidFile=Join-Path $root 'managed-control/control.pid';[void][IO.Directory]::CreateDirectory((Split-Path $pidFile -Parent));[IO.File]::WriteAllText($pidFile,'1000001')
Write-TransportJson (Join-Path $root 'config.json') @{wizard=@{configured=$false}}
Stop-ManagedControl $root
Assert ($script:removedRun -eq 1 -and $script:bridgeStopped -eq 1) 'unfinished setup stops owned bridge and its Run entry'
$script:bridgeCommand=$command.Replace($root,($root+'-other'));Stop-ManagedControl $root
Assert ($script:removedRun -eq 1 -and $script:bridgeStopped -eq 1) 'foreign bridge and Run entry untouched'
$script:bridgeCommand=$command;Write-TransportJson (Join-Path $root 'config.json') @{wizard=@{configured=$true}};Stop-ManagedControl $root
Assert ($script:removedRun -eq 1 -and $script:bridgeStopped -eq 1) 'configured installation never stopped by first-run cleanup'
# The launcher's shutdown helper stops configured processes too, but removes Run only for unfinished setup.
Remove-Item -LiteralPath $pidFile
. (Join-Path $repo 'build/Setup.Common.ps1')
$script:runRemoved=0
function Get-RunValue($Name){return $script:bridgeCommand}
function Set-RunValue($Name,$Value){Assert ($Name -eq 'RemoteAgentsControl' -and $null -eq $Value) 'shutdown only deletes the owned Run value';$script:runRemoved++}
Write-TransportJson (Join-Path $root 'config.json') @{wizard=@{configured=$false}}
$script:bridgeCommand=$command
Stop-ManagedControl $root
Assert ($script:runRemoved -eq 1) 'launcher shutdown removes unfinished owned bridge autostart even without PID file'
$script:bridgeCommand=$command.Replace($root,($root+'-other'));Stop-ManagedControl $root
Assert ($script:runRemoved -eq 1) 'launcher shutdown preserves foreign Home autostart'
$script:bridgeCommand=$command.Replace('managed-control/app','control/app');Stop-ManagedControl $root
Assert ($script:runRemoved -eq 1) 'launcher shutdown preserves unmanaged bridge autostart'
$script:bridgeCommand=$command;Write-TransportJson (Join-Path $root 'config.json') @{wizard=@{configured=$true}}
Stop-ManagedControl $root
Assert ($script:runRemoved -eq 1) 'launcher shutdown preserves completed installation autostart'
Write-Output ('OK: '+$count+' setup/headless checks (fixtures)')
