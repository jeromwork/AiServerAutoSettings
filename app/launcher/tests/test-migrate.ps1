#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Migrate.Common.ps1')
$script:passed=0
function Assert($Value,[string]$Name){if(-not $Value){throw ('FAIL '+$Name)};$script:passed++;Write-Output ('PASS '+$Name)}
if(-not $TestHome){$TestHome=Join-Path ([IO.Path]::GetTempPath()) ('remoteagents-migrate-'+[Guid]::NewGuid().ToString('N'))}
[void][IO.Directory]::CreateDirectory($TestHome)
$env:LOCALAPPDATA=$TestHome;$env:USERPROFILE=$TestHome
$root=Join-Path $TestHome 'RemoteAgents';$disk=Join-Path $TestHome 'RemoteDisk'
[void][IO.Directory]::CreateDirectory((Join-Path $disk 'channel'));[void][IO.Directory]::CreateDirectory($root)
$profile=Join-Path $TestHome 'ssh-transport.json';$ssh=Join-Path $TestHome 'ssh config'
$original="Host example.invalid`r`n    User tester`r`n    ProxyCommand ssh gateway -W %h:%p`r`nHost other.invalid`r`n    Port 9922`r`n"
[IO.File]::WriteAllText($ssh,$original,(New-Object Text.UTF8Encoding($true)))
Write-TransportJson $profile @{sshExecutable='ssh';serverAddress='example.invalid';login='tester';configPath=$ssh;keyPath='unused';knownHostsPath='unused';arguments=@('-p','22')}
[IO.File]::WriteAllText((Join-Path $disk 'profile.txt'),($profile+"`r`n"))
Write-TransportJson (Join-Path $disk 'channel/config.json') @{inbounds=@(@{tag='ssh';listen_port=2222;override_port=22},@{tag='sync';listen_port=22071;override_port=22000})}
Write-TransportJson (Join-Path $root 'config.json') @{foreign=@{value='keep'};transport=@{apiPort=29981;entries=@(@{name='keep-entry';ssh='keep'})};components=@{other=@{enabled=$true;value=42}}}
$c=Import-MigrationConfig $root $disk
Assert ($c.transport.profilePath -eq $profile -and $c.transport.channelPath -eq (Join-Path $disk 'channel/config.json')) 'legacy paths import CRLF'
Assert ($c.transport.syncPort -eq 22071 -and $c.transport.apiPort -eq 29981) 'import sync port and preserve configured ports'
Assert ($c.foreign.value -eq 'keep' -and $c.components.other.value -eq 42 -and $c.transport.entries[0].name -eq 'keep-entry') 'recursive config merge preserves unrelated keys and entries'
$null=Import-MigrationConfig $root $disk;$c=Read-TransportJson (Join-Path $root 'config.json')
Assert ($c.transport.entries.Count -eq 1) 'import idempotent'
$blank=Join-Path $TestHome 'blank';$null=Import-MigrationConfig $blank $disk
Assert (@((Read-TransportJson (Join-Path $blank 'config.json')).transport.entries).Count -eq 0) 'entry defaults empty'
Set-MigrationSshBlock $ssh $root example.invalid 22371
$first=[IO.File]::ReadAllBytes($ssh);$text=[IO.File]::ReadAllText($ssh)
Assert ($text.StartsWith('# BEGIN RemoteAgents transport ') -and $text.Contains("    HostName 127.0.0.1`r`n") -and $text.Contains('    Port 22371')) 'managed block first and CRLF'
Set-MigrationSshBlock $ssh $root example.invalid 22371
Assert ([Convert]::ToBase64String($first) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($ssh))) 'managed add byte idempotent'
Set-MigrationSshBlock $ssh $root example.invalid 22372
Assert (([regex]::Matches([IO.File]::ReadAllText($ssh),'# BEGIN')).Count -eq 1) 'managed update no duplicate'
Set-MigrationSshBlock $ssh $root example.invalid 22372 -Remove
Assert ([IO.File]::ReadAllText($ssh) -ceq $original) 'managed removal restores CRLF text'
Set-MigrationSshBlock $ssh $root example.invalid 22372 -Remove
Assert ([IO.File]::ReadAllBytes($ssh)[0] -eq 239) 'removal preserves UTF8 BOM'
# Check actual OpenSSH interpretation without connecting or reading any private keys.
if(Get-Command ssh -ErrorAction SilentlyContinue){
    [IO.File]::WriteAllText($ssh,$original,(New-Object Text.UTF8Encoding($false)))
    Set-MigrationSshBlock $ssh $root example.invalid 22371
    $effective=(& ssh -G -F $ssh example.invalid 2>$null) -join "`n"
    Assert ($effective -match '(?m)^hostname 127\.0\.0\.1$' -and $effective -match '(?m)^port 22371$' -and $effective -match '(?m)^hostkeyalias example.invalid$') 'real ssh -G applies route'
    Set-MigrationSshBlock $ssh $root example.invalid 22371 -Remove
}
# Missing config is a supported legacy state; rollback must restore absence.
$absent=Join-Path $TestHome 'new ssh/config'
Set-MigrationSshBlock $absent $root example.invalid 22371
Assert ([IO.File]::Exists($absent)) 'managed route creates absent SSH config'
Set-MigrationSshBlock $absent $root example.invalid 22371 -Remove -OriginallyAbsent
Assert (-not [IO.File]::Exists($absent)) 'rollback restores absent SSH config'
Set-MigrationSshBlock $absent $root example.invalid 22371 -Remove -OriginallyAbsent
Assert (-not [IO.File]::Exists($absent)) 'rollback absent config idempotent'
Set-MigrationSshBlock $absent $root example.invalid 22371
[IO.File]::AppendAllText($absent,"Host added.invalid`n    User keep`n")
Set-MigrationSshBlock $absent $root example.invalid 22371 -Remove -OriginallyAbsent
Assert ([IO.File]::ReadAllText($absent).Contains('User keep')) 'rollback preserves edits to newly created config'
$probeRoot=Join-Path $root 'state/migration-probe'
Write-TransportJson (Join-Path $probeRoot 'status/transport.json') @{network='current-network'}
Write-TransportJson (Join-Path $probeRoot 'state/transport-memory.json') @{version=1;networks=@{'current-network'=@{candidates=@(@{tag='fast-path';state='ok';kbps=150})}}}
Write-TransportJson (Join-Path $root 'state/transport-memory.json') @{version=1;networks=@{'other-network'=@{keep='yes'}}}
Merge-MigrationProbeMemory $root;$memory=Read-TransportMemory $root
Assert ($memory.networks['other-network'].keep -eq 'yes' -and $memory.networks['current-network'].candidates[0].tag -eq 'fast-path') 'carry preflight path without losing other network memory'
$remembered=@(Get-TransportRemembered $memory 'current-network' @([pscustomobject]@{tag='fast-path';title='Fast';kind='test';via='test';enabled=$true}))
Assert ($remembered[0].state -eq 'remembered') 'carried path still requires a new live probe'
# Preserve the scheduler's valid disabled-but-running state.
$script:taskOps=New-Object Collections.ArrayList
function Enable-ScheduledTask($TaskName){[void]$script:taskOps.Add('enable')}
function Start-ScheduledTask($TaskName){[void]$script:taskOps.Add('start')}
function Disable-ScheduledTask($TaskName){[void]$script:taskOps.Add('disable')}
Restore-MigrationChannel fixture ([pscustomobject]@{exists=$true;enabled=$false;running=$true})
Assert (($script:taskOps -join ',') -ceq 'enable,start,disable') 'rollback restarts disabled-but-running channel before restoring disabled flag'
# Platform adapters: isolated registry/tasks/process ledger; no Windows calls.
$script:runs=@{Disk='old-disk';Control='old-control';Launcher=$null};$script:task=[pscustomobject]@{exists=$true;enabled=$true;running=$true};$script:events=New-Object Collections.ArrayList
function Get-MigrationRun($Name){$script:runs[$Name]}
function Set-MigrationRun($Name,$Value){$script:runs[$Name]=$Value;[void]$script:events.Add('run.'+$Name)}
function Get-MigrationTask($Name){if($Name -eq 'Rollback'){[pscustomobject]@{exists=($script:events.Contains('watchdog') -and -not $script:events.Contains('unwatchdog'));enabled=$true;running=$false}}else{$script:task}}
function Register-MigrationRollback($Root,$Bundle,$State){if($script:failWatchdog){throw 'fixture watchdog failure'};[void]$script:events.Add('watchdog')}
function Register-MigrationRecovery($Root,$State){if($script:failRecovery){throw 'fixture recovery failure'};[void]$script:events.Add('recovery-task')}
function Unregister-MigrationRecovery($Root,$State){[void]$script:events.Add('unrecovery-task')}
function Unregister-MigrationRollback($Name){[void]$script:events.Add('unwatchdog')}
function Invoke-MigrationPreflight($Root,$Bundle,$Config){if($script:failPreflight){throw 'fixture preflight failure'};[void]$script:events.Add('preflight')}
function Suspend-MigrationChannel($Name){[void]$script:events.Add('suspend')}
function Restore-MigrationChannel($Name,$Snapshot){if($script:failRestore){throw 'fixture'};Assert ($Snapshot.enabled -and $Snapshot.running) 'rollback restores original channel state';[void]$script:events.Add('restore-channel')}
function Stop-MigrationLauncher($Root){[void]$script:events.Add('stop-launcher')}
function Start-MigrationDetached($Exe,$Arguments){[void]$script:events.Add('start-launcher')}
function Wait-MigrationTransport($Root,$Timeout){[void]$script:events.Add('transport-ready')}
function Test-MigrationSsh($Root,$Port){$true}
function Start-MigrationControl($Root,$Bundle,$State){[void]$script:events.Add('start-control')}
function Stop-MigrationControl($Root){[void]$script:events.Add('stop-control')}
function Start-MigrationRun($Command){[void]$script:events.Add('restore-process')}
function Test-MigrationHealth($Root){$script:health}
$names=[pscustomobject]@{channelTask='Channel';rollbackTask='Rollback';diskRun='Disk';controlRun='Control';launcherRun='Launcher'}
$script:failWatchdog=$true
try{Invoke-MigrationTransition $root $repo $disk $names;throw 'expected fixture watchdog failure'}catch{Assert ($_.Exception.Message -eq 'fixture watchdog failure') 'registration failure aborts transition'}
Assert (-not $script:events.Contains('suspend') -and -not $script:events.Contains('stop-launcher')) 'watchdog failure leaves running services untouched'
Remove-Item -LiteralPath (Get-MigrationStatePath $root)
$script:failWatchdog=$false;$script:failPreflight=$true
try{Invoke-MigrationTransition $root $repo $disk $names;throw 'expected fixture preflight failure'}catch{Assert ($_.Exception.Message -eq 'fixture preflight failure') 'preflight failure aborts transition'}
Assert (-not $script:events.Contains('suspend') -and -not $script:events.Contains('stop-launcher')) 'preflight failure leaves original launcher and channel untouched'
$script:failPreflight=$false;$script:events.Clear()
Invoke-MigrationTransition $root $repo $disk $names
$state=Read-TransportJson (Get-MigrationStatePath $root)
Assert ($state.phase -eq 'pending' -and $script:runs.Disk -eq $null -and $script:runs.Launcher) 'migration pending and autostart transfer'
Assert ($script:events.IndexOf('watchdog') -lt $script:events.IndexOf('preflight') -and $script:events.IndexOf('preflight') -lt $script:events.IndexOf('suspend') -and $script:events.IndexOf('suspend') -lt $script:events.IndexOf('start-launcher')) 'watchdog before preflight before channel cutover'
$count=$script:events.Count;Invoke-MigrationTransition $root $repo $disk $names
Assert ($script:events.Count -eq $count+1) 'repeat install no new watchdog or switch'
$script:health=$false;Confirm-Migration $root -Explicit
Assert ((Read-TransportJson (Get-MigrationStatePath $root)).phase -eq 'pending') 'explicit confirm cannot bypass failed health'
$script:health=$true;$script:failRecovery=$true
try{Confirm-Migration $root -Explicit;throw 'expected recovery registration failure'}catch{Assert ($_.Exception.Message -eq 'fixture recovery failure') 'recovery registration failure prevents acceptance'}
Assert ((Read-TransportJson (Get-MigrationStatePath $root)).phase -eq 'pending' -and -not $script:events.Contains('unwatchdog')) 'failed recovery keeps rollback armed'
$script:failRecovery=$false;Confirm-Migration $root
Assert ((Read-TransportJson (Get-MigrationStatePath $root)).phase -eq 'pending') 'green requires three minutes'
$state=Read-TransportJson (Get-MigrationStatePath $root);$state.greenSince=[DateTime]::UtcNow.AddSeconds(-181).ToString('o');$state.lastHealthyAt=[DateTime]::UtcNow.ToString('o');Write-TransportJson (Get-MigrationStatePath $root) $state
Confirm-Migration $root -Observer 'new-launcher-session'
Assert ((Read-TransportJson (Get-MigrationStatePath $root)).phase -eq 'pending') 'launcher restart resets three-minute green window'
$state=Read-TransportJson (Get-MigrationStatePath $root);$state.greenSince=[DateTime]::UtcNow.AddSeconds(-181).ToString('o');$state.lastHealthyAt=[DateTime]::UtcNow.ToString('o');Write-TransportJson (Get-MigrationStatePath $root) $state
Confirm-Migration $root -Observer 'new-launcher-session'
Assert ((Read-TransportJson (Get-MigrationStatePath $root)).phase -eq 'accepted' -and $script:events.Contains('unwatchdog')) 'three green minutes remove watchdog'
Invoke-MigrationRollback $root $state.session
Assert ((Read-TransportJson (Get-MigrationStatePath $root)).phase -eq 'accepted') 'late watchdog cannot roll back accepted session'
$script:failRestore=$true
try{Invoke-MigrationRollback $root -Force;throw 'Expected incomplete rollback'}catch{Assert ($_.Exception.Message -match 'Откат неполный') 'rollback failure explicit and retryable'}
Assert ($script:runs.Disk -eq 'old-disk' -and $script:runs.Control -eq 'old-control') 'rollback continues independent restorations after failure'
$script:failRestore=$false;Invoke-MigrationRollback $root -Force
Assert ((Read-TransportJson (Get-MigrationStatePath $root)).phase -eq 'rolled-back' -and -not $script:runs.Launcher) 'uninstall same rollback without waiting'
Assert ([IO.File]::ReadAllText($ssh) -ceq $original) 'rollback restores SSH without touching other hosts'
$c=Read-TransportJson (Join-Path $root 'config.json');Assert ($c.foreign.value -eq 'keep' -and -not $c.components.transport.enabled) 'rollback preserves foreign config and disables supervision'
$count=$script:events.Count;Invoke-MigrationRollback $root -Force
Assert ($script:events.Count -eq $count) 'rollback idempotent'
# Status and pause tests call real functions with a fake REST API, never expose API keys.
. (Join-Path $repo 'disk/Disk.Status.ps1') -LibraryOnly
Initialize-DiskMonitor $root
[IO.File]::WriteAllText((Join-Path $disk 'server.txt'),'SERVER')
$script:connected=$true;$script:paused=$false;$script:need=0;$script:apiDown=$false
function Invoke-DiskApi($Route,$Method='GET',$Body=$null){
    if($script:apiDown){throw 'fixture'}
    switch -Regex ($Route){
        '^system/status$' {[pscustomobject]@{myID='LOCAL'}}
        '^system/connections$' {[pscustomobject]@{connections=[pscustomobject]@{SERVER=[pscustomobject]@{connected=$script:connected}}}}
        '^config/folders$' {,[pscustomobject]@{id='f';label='Folder';paused=$script:paused;devices=@(@{deviceID='SERVER'})}}
        '^db/status' {[pscustomobject]@{state='idle';globalBytes=100;needBytes=$script:need;needTotalItems=$script:need;pullErrors=0}}
        '^config/folders/f$' {$script:paused=$Body.paused}
        '^config/folders/missing$' {throw '404 fixture'}
    }
}
$s=Get-DiskMonitorStatus;Assert ($s.ok -and $s.summary -eq 'Синхронизировано: 1 папок' -and $s.folders.Count -eq 1) 'disk single-folder REST array PS51 shape'
$script:need=25;$s=Get-DiskMonitorStatus;Assert ($s.folders[0].completion -eq 75 -and $s.summary -match 'Синхронизация: 0 из 1') 'disk honest progress'
$script:connected=$false;Assert ((Get-DiskMonitorStatus).summary -eq 'Нет связи с сервером') 'disk disconnected'
$script:apiDown=$true;Assert ((Get-DiskMonitorStatus).summary -eq 'Syncthing не запущен') 'disk API unavailable'
$script:apiDown=$false;Set-DiskPause Pause30;Assert $script:paused 'REST pause'
Set-DiskPause Resume -Expected 'obsolete-timer';Assert $script:paused 'old timed-resume cannot undo a newer pause'
Set-DiskPause Resume;Assert (-not $script:paused) 'REST resume owned pause'
Set-DiskPause Pause30
$pauseFile=Join-Path $root 'state/disk-pause.json';$pause=Read-TransportJson $pauseFile;$pause.folders=@('missing','f');Write-TransportJson $pauseFile $pause
Set-DiskPause Resume;Assert (-not $script:paused -and -not (Test-Path $pauseFile)) 'removed folder cannot block timed resume of remaining folders'
$script:paused=$true;Set-DiskPause Pause120;Set-DiskPause Resume;Assert $script:paused 'resume preserves earlier user pause'
Write-Output ('OK: '+$script:passed+' migration/status checks (fixtures, no live Windows).')
# Actual bridge profile parser honors managed Port despite the legacy explicit -p 22.
$fixtureProfile=$profile
. (Join-Path $repo 'Start-WindowsControl.ps1') -LibraryOnly
Set-MigrationSshBlock $ssh $root example.invalid 22371
$connection=Read-ControlProfile $fixtureProfile
Assert ($connection.port -eq 22371) 'control parser overrides legacy explicit port from managed block'
Set-MigrationSshBlock $ssh $root example.invalid 22371 -Remove
Assert ((Read-ControlProfile $fixtureProfile).port -eq 22) 'control returns original port after rollback'
$originalProfile=Read-TransportJson $fixtureProfile;$originalProfile.configPath=Join-Path $TestHome 'missing-config'
$originalProfile.keyPath=Join-Path $TestHome 'Пользователь с пробелом/key'
Write-TransportJson $fixtureProfile $originalProfile
$legacyConnection=Read-ControlProfile $fixtureProfile
Assert ($legacyConnection.port -eq 22 -and $legacyConnection.keyPath -ceq $originalProfile.keyPath) 'legacy missing config and UTF8 profile path preserved'
$originalProfile.configPath=$ssh;Write-TransportJson $fixtureProfile $originalProfile

. (Join-Path $repo 'app/launcher/control/Control.Status.ps1') -LibraryOnly
$controlBase=Join-Path $env:LOCALAPPDATA 'RemoteAgents/control';[void][IO.Directory]::CreateDirectory((Join-Path $controlBase 'logs'))
[IO.File]::WriteAllText((Join-Path $controlBase 'control.pid'),'12345')
$script:rootProcess=$true;$script:socketLive=$true;$script:created=(Get-Date).AddMinutes(-2)
function Get-CimInstance($ClassName){if($script:rootProcess){[pscustomobject]@{ProcessId=12345;ParentProcessId=0;CommandLine='powershell -File Start-WindowsControl.ps1';Name='powershell.exe';CreationDate=$script:created};[pscustomobject]@{ProcessId=12346;ParentProcessId=12345;Name='ssh.exe';CommandLine='ssh.exe -R 127.0.0.1:111:127.0.0.1:222';CreationDate=$script:created}}}
function Get-NetTCPConnection($OwningProcess,$State){if($script:socketLive){[pscustomobject]@{State='Established'}}}
$log=Join-Path $controlBase 'logs/control.log'
[IO.File]::WriteAllText($log,((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')+' bridge.connected synthetic'))
Assert ((Get-ControlMonitorStatus $root).ok) 'control requires live root, child SSH socket and connected log'
$script:socketLive=$false;Assert (-not (Get-ControlMonitorStatus $root).ok) 'historic bridge log alone is not green'
$script:socketLive=$true;[IO.File]::AppendAllText($log,"`r`n"+(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')+' bridge.disconnected synthetic')
Assert (-not (Get-ControlMonitorStatus $root).ok) 'later disconnect invalidates successful contact'
$script:rootProcess=$false;Assert ((Get-ControlMonitorStatus $root).summary -eq 'Управление выключено') 'control absent process'
Write-Output ('OK FINAL: '+$script:passed+' migration/status checks (fixtures).')

# A missing watchdog at confirm cannot turn a pending transition into acceptance.
$state=Read-TransportJson (Get-MigrationStatePath $root);$state.phase='pending';$state.startedAt=[DateTime]::UtcNow.ToString('o');Write-TransportJson (Get-MigrationStatePath $root) $state
$script:events.Clear();$script:health=$true
try{Confirm-Migration $root -Explicit;throw 'expected missing watchdog'}catch{Assert ($_.Exception.Message -match 'Watchdog') 'confirm refuses missing watchdog'}
Assert ((Read-TransportJson (Get-MigrationStatePath $root)).phase -eq 'rolled-back') 'missing watchdog forces restoration'
Write-Output ('OK REVIEW: '+$script:passed+' migration/status checks (fixtures).')

$state=Read-TransportJson (Get-MigrationStatePath $root);$state.phase='pending';$state.startedAt=[DateTime]::UtcNow.AddHours(1).ToString('o');Write-TransportJson (Get-MigrationStatePath $root) $state
$watch=[Diagnostics.Stopwatch]::StartNew()
Assert (Wait-MigrationDeadline $root $state.session 0.5) 'watchdog expires despite clock moving backwards'
Assert ($watch.Elapsed.TotalSeconds -lt 3) 'watchdog uses bounded monotonic time'
$state.phase='accepted';Write-TransportJson (Get-MigrationStatePath $root) $state
Assert (-not (Wait-MigrationDeadline $root $state.session)) 'watchdog does not revert accepted session'
Write-Output ('OK WATCHDOG: '+$script:passed+' migration/status checks (fixtures).')

Assert ((Get-MigrationMarker ($root+'/')) -ceq (Get-MigrationMarker $root)) 'trailing separator has same SSH ownership and mutex home'
Assert ((Get-TransportHome ([IO.Path]::GetPathRoot($root))) -ceq [IO.Path]::GetPathRoot($root)) 'canonical Home preserves filesystem root'
Write-Output ('OK COMPLETE: '+$script:passed+' migration/status checks (fixtures).')

Write-TransportJson (Join-Path $root 'status/transport.json') @{ok=$true;updatedAt=[DateTime]::UtcNow.ToString('o');configError='fixture invalid reload'}
Assert (-not (Test-MigrationFresh $root transport)) 'pending install rejects old healthy engine after invalid config reload'
Write-Output ('OK TOTAL: '+$script:passed+' migration/status checks (fixtures).')
