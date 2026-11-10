#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$env:LOCALAPPDATA=$TestHome
$root=Join-Path $TestHome 'RemoteAgents'
[void][IO.Directory]::CreateDirectory($root)
. (Join-Path $repo 'build/FirstInstall.ps1') -LibraryOnly
$count=0
function Assert($ok,$name){if(-not $ok){throw ('FAIL '+$name)};$script:count++}
$script:steps=New-Object Collections.ArrayList
function Get-MigrationRun($Name){'fixture-control-run'}
$script:profile='';$script:failSsh=$false
function Find-InstallProfile($Root){$script:profile}
function Invoke-TransportText($Exe,$Arguments){if($script:failSsh){throw 'fixture no SSH'};[void]$script:steps.Add('verify');' '}
function Invoke-InstallChild($Bundle,$Script,$Arguments){
    [void]$script:steps.Add($Script)
    if($Script -eq 'setup-vps-ssh.ps1'){
        Assert ('-SetupOnly' -in $Arguments) 'wizard reuses SSH key and askpass path'
        $script:profile=Join-Path $root 'fixture-profile.json'
        [IO.File]::WriteAllText($script:profile,'{"sshExecutable":"fixture","arguments":["-T","example.invalid"]}'+"`r`n")
    }
}
Invoke-FirstInstall $root $repo 'example.invalid' 'tester'
Assert (($script:steps -join ',') -eq 'setup-vps-ssh.ps1,verify,Setup-All.ps1,build/Migrate.ps1') 'clean machine runs setup then real SSH then disk/control then rollback migration'
$selectionPath=Join-Path $TestHome 'RemoteDisk/selection.json'
Assert (([IO.File]::ReadAllText($selectionPath)|ConvertFrom-Json).schema -eq 1 -and @(([IO.File]::ReadAllText($selectionPath)|ConvertFrom-Json).paths).Count -eq 0) 'clean wizard defaults to server-only before autoaccept'
[IO.File]::WriteAllText($selectionPath,'{"schema":1,"paths":["project/src"]}'+"`r`n")
$script:steps.Clear()
Invoke-FirstInstall $root $repo '' ''
Assert (-not $script:steps.Contains('setup-vps-ssh.ps1')) 'shared profile never prompts credentials again'
Assert (([IO.File]::ReadAllText($selectionPath)|ConvertFrom-Json).paths[0] -eq 'project/src') 'rerun preserves existing selective choice (CRLF)'
$disk=Join-Path $TestHome 'RemoteDisk/state';$control=Join-Path $TestHome 'RemoteAgents/control'
[void][IO.Directory]::CreateDirectory((Join-Path $TestHome 'RemoteDisk/channel'));[IO.File]::WriteAllText((Join-Path $TestHome 'RemoteDisk/channel/config.json'),'{}')
[void][IO.Directory]::CreateDirectory($disk);[void][IO.Directory]::CreateDirectory($control)
[IO.File]::WriteAllText((Join-Path $disk 'config.xml'),'<configuration/>');[IO.File]::WriteAllText((Join-Path $control 'config.json'),'{}')
$script:steps.Clear();Invoke-FirstInstall $root $repo '' ''
Assert (($script:steps -join ',') -eq 'verify,build/Migrate.ps1') 'legacy install uses unchanged migration without disk reinstall'
$script:steps.Clear();$script:failSsh=$true
try{Invoke-FirstInstall $root $repo '' '';throw 'expected failure'}catch{Assert ($_.Exception.Message -eq 'fixture no SSH') 'saved profile verified before skipping'}
Assert (-not $script:steps.Contains('build/Migrate.ps1')) 'failed verification cannot proceed'
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
try{Start-DiskHeadless;throw 'expected duplicate refusal'}catch{Assert ($_.Exception.Message -like 'Остался прежний*') 'unowned engine blocks duplicate state instance'}

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
Assert (($script:stopped -join ',') -eq '1000002,1000001') 'migration stops GUI before embedded engine'
Assert ($script:inventory.Count -eq 1 -and $script:inventory[0].ProcessId -eq 1000003) 'different Syncthing state untouched'
Write-Output ('OK: '+$count+' first-install/headless checks (fixtures)')
