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
try{Start-DiskHeadless;throw 'expected duplicate refusal'}catch{Assert ($_.Exception.Message -like 'С этим состоянием уже работает*') 'unowned engine blocks duplicate state instance'}

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
Write-Output ('OK: '+$count+' setup/headless checks (fixtures)')
