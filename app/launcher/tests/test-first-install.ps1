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
. (Join-Path $repo 'build/Process.Common.ps1')
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
