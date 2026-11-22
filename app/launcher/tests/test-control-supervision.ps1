#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$temporary=-not $TestHome
if($temporary){$TestHome=Join-Path ([IO.Path]::GetTempPath()) ('control-supervision-'+[guid]::NewGuid().ToString('N'))}
$oldLocal=$env:LOCALAPPDATA;$oldSystemRoot=$env:SystemRoot
$env:LOCALAPPDATA=Join-Path $TestHome 'local'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'app/launcher/control/Control.Status.ps1') -LibraryOnly
$root=Join-Path $TestHome 'Launcher Home'
$managed=Join-Path $root 'managed-control';$foreign=Join-Path $env:LOCALAPPDATA 'RemoteAgents/control'
foreach($path in @($managed,$foreign)){[void][IO.Directory]::CreateDirectory($path)}
$count=0;$script:starts=0;$script:processes=@{}
function Assert($Value,[string]$Why){if(-not $Value){throw ('FAIL: '+$Why)};$script:count++}
# Only OS process lookup and starting a Windows bridge are stubbed; PID files and status parsing are real.
function Get-CimInstance($ClassName,$Filter){
    Assert ($ClassName -ceq 'Win32_Process' -and $Filter -match '^ProcessId=\d+$') 'lookup is restricted to the PID file'
    $script:processes[[int]$Filter.Substring('ProcessId='.Length)]
}
function Restart-ManagedControl([string]$Root){Assert ($Root -ceq (Join-Path $TestHome 'Launcher Home')) 'start targets only this launcher Home';$script:starts++}
function Tick($State,[DateTime]$At){Update-ControlSupervision $root (Get-ControlMonitorStatus $root) $State $At}
function PidFile([string]$Directory,[string]$Value){[IO.File]::WriteAllText((Join-Path $Directory 'control.pid'),($Value+"`r`n"))}
$now=[DateTime]::UtcNow
try{
    $state=@{failures=0;nextRestart=$now.AddSeconds(90)}
    Tick $state $now
    Assert ($script:starts -eq 1 -and $state.failures -eq 0) 'missing PID starts on the first tick despite the 90-second grace period'
    PidFile $managed '101'
    $script:processes[101]=[pscustomobject]@{ProcessId=101;CommandLine='powershell.exe -File Start-WindowsControl.ps1';CreationDate=$now.AddMinutes(-5)}
    $state=@{failures=0;nextRestart=$now.AddSeconds(90)};$script:starts=0
    foreach($second in @(0,10,20,89)){Tick $state $now.AddSeconds($second)}
    Assert ($script:starts -eq 0) 'live bridge without heartbeat keeps the initial 90-second grace period'
    Tick $state $now.AddSeconds(90)
    Assert ($script:starts -eq 1 -and $state.nextRestart -eq $now.AddSeconds(210)) 'three heartbeat failures restart only after grace; retry cooldown is preserved'
    foreach($second in @(100,110,200)){Tick $state $now.AddSeconds($second)}
    Assert ($script:starts -eq 1) 'live bridge respects the restart cooldown'
    Tick $state $now.AddSeconds(210)
    Assert ($script:starts -eq 2) 'live unhealthy bridge may restart after cooldown'
    $script:starts=0;$state=@{failures=0;nextRestart=$now}
    Tick $state $now;Tick $state $now.AddSeconds(10)
    Assert ($script:starts -eq 0) 'two failed heartbeats do not restart a live bridge'
    Tick $state $now.AddSeconds(20)
    Assert ($script:starts -eq 1) 'third failed heartbeat restarts an eligible live bridge'
    Write-TransportJson (Join-Path $managed 'heartbeat.json') @{ok=$true;pid=101;updatedAt=$now.ToString('o')}
    Tick $state $now.AddSeconds(30)
    Assert ($state.failures -eq 0 -and $script:starts -eq 1) 'valid authenticated heartbeat clears failures without restart'
    [IO.File]::Delete((Join-Path $managed 'heartbeat.json'))
    $script:processes.Remove(101)
    Tick $state $now.AddSeconds(31)
    Assert ($script:starts -eq 2) 'process death bypasses both failure threshold and restart cooldown'
    [IO.File]::Delete((Join-Path $managed 'control.pid'))
    Tick $state $now.AddSeconds(32)
    Assert ($script:starts -eq 3) 'removed managed PID file also starts immediately'
    PidFile $managed '102'
    $script:processes[102]=[pscustomobject]@{ProcessId=102;CommandLine='some-other-program.exe';CreationDate=$now}
    Tick $state $now.AddSeconds(33)
    Assert ($script:starts -eq 4) 'PID reused by another program is treated as absent bridge'
    PidFile $managed 'not a PID'
    Tick $state $now.AddSeconds(34)
    Assert ($script:starts -eq 5) 'invalid PID file does not postpone bridge start'
    [IO.File]::Delete((Join-Path $managed 'control.pid'))
    PidFile $foreign '201'
    $script:processes[201]=[pscustomobject]@{ProcessId=201;CommandLine='powershell.exe -File Start-WindowsControl.ps1';CreationDate=$now.AddMinutes(-5)}
    $status=Get-ControlMonitorStatus $root
    Assert ($status.processAlive -and -not $status.managed -and -not $status.ok) 'manual bridge is observed as foreign even without heartbeat'
    $state=@{failures=3;nextRestart=$now.AddMinutes(-1)}
    Tick $state $now
    Assert ($script:starts -eq 5) 'supervision never restarts a live foreign bridge without heartbeat'
    Write-TransportJson (Join-Path $foreign 'heartbeat.json') @{ok=$true;pid=201;updatedAt=$now.ToString('o')}
    Tick $state $now
    Assert ((Get-ControlMonitorStatus $root).ok -and $script:starts -eq 5) 'healthy foreign bridge supplies status and stays untouched'
    # The running owner, not the supervisor, restores a missing PID without a new Install.
    . (Join-Path $repo 'Start-WindowsControl.ps1') -LibraryOnly
    $pidFile=Join-Path $managed 'control.pid';$logFile=Join-Path $managed 'control.log'
    $script:processes[$PID]=[pscustomobject]@{ProcessId=$PID;CommandLine='powershell.exe -File Start-WindowsControl.ps1';CreationDate=$now.AddMinutes(-1)}
    Write-TransportJson (Join-Path $managed 'heartbeat.json') @{ok=$true;pid=$PID;updatedAt=$now.ToString('o')}
    Assert (-not (Test-Path $pidFile)) 'owner is alive with a missing PID file'
    Repair-ControlPidFile $pidFile $logFile
    $written=(Get-Item $pidFile).LastWriteTimeUtc
    for($i=0;$i -lt 20;$i++){Repair-ControlPidFile $pidFile $logFile}
    Assert ([IO.File]::ReadAllText($pidFile).Trim() -eq [string]$PID) 'owner restores its own PID'
    Assert ((Get-Item $pidFile).LastWriteTimeUtc -eq $written) 'ordinary ticks do not rewrite the PID'
    Assert (@(Get-Content $logFile|Where-Object {$_ -match 'restored pid='}).Count -eq 1) 'one recovery log entry, no per-tick noise'
    $state=@{failures=0;nextRestart=$now};Tick $state $now
    Assert ((Get-ControlMonitorStatus $root).ok -and $script:starts -eq 5) 'restored owner is healthy and supervision starts no replacement'
    Remove-Item $pidFile
    Repair-ControlPidFile $pidFile $logFile
    Assert (@(Get-Content $logFile|Where-Object {$_ -match 'restored pid='}).Count -eq 2) 'a second disappearance is repaired and logged once'

    # Stop must not erase evidence of a live owner when CIM failed, or a newer PID after waiting.
    function Get-CimInstance {[CmdletBinding()]param($ClassName,$Filter) Write-Error 'fixture: CIM unavailable'}
    $failed=$false;try{Stop-ControlInstance $pidFile}catch{$failed=$true}
    Assert ($failed -and (Test-Path $pidFile)) 'CIM failure leaves PID intact and aborts Stop/Install'
    PidFile $managed '2147483000'
    function Get-CimInstance {param($ClassName,$Filter,$ErrorAction) [pscustomobject]@{CommandLine='powershell.exe -File Start-WindowsControl.ps1'}}
    function taskkill.exe {PidFile $managed '2147483001';$global:LASTEXITCODE=0}
    Stop-ControlInstance $pidFile
    Assert ([IO.File]::ReadAllText($pidFile).Trim() -eq '2147483001') 'Stop preserves a PID replaced by a concurrent start'
    function Get-CimInstance {param($ClassName,$Filter,$ErrorAction) $null}
    Stop-ControlInstance $pidFile -KeepPid
    Assert (Test-Path $pidFile) 'KeepPid preserves stale state for rollback'
    Stop-ControlInstance $pidFile
    Assert (-not (Test-Path $pidFile)) 'confirmed stale PID is removed normally'

    # Execute the actual Install branch; only Windows OS adapters and profile selection are fixtures.
    $source=[IO.File]::ReadAllText((Join-Path $repo 'Start-WindowsControl.ps1'))
    $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$null,[ref]$null)
    $installBranch=$ast.EndBlock.Statements|Where-Object {$_.Extent.Text.StartsWith('if($Install){')}
    $Install=$true;$LauncherHome=$root;$base=$managed;$app=Join-Path $base 'app'
    $configPath=Join-Path $TestHome 'control-config.json';$Profile='fixture';$AgentUser='tester'
    $env:SystemRoot=Join-Path $TestHome 'Windows'
    $script:creates=0;$script:startup=$null
    function Read-ControlProfile {param($Path) [pscustomobject]@{profilePath='fixture'}}
    function Set-ItemProperty {param($Path,$Name,$Value) Assert ($Name -eq 'RemoteAgentsControl') 'Install registers control autostart'}
    function New-CimInstance {param($ClassName,[switch]$ClientOnly,$Property)
        Assert ($ClassName -eq 'Win32_ProcessStartup' -and $ClientOnly) 'startup information is client-only Win32_ProcessStartup'
        Assert ($Property.ShowWindow -is [uint16] -and $Property.ShowWindow -eq 0) 'startup requests SW_HIDE with uint16 ShowWindow=0'
        $script:startup=[pscustomobject]$Property;$script:startup
    }
    function Invoke-CimMethod {param($ClassName,$MethodName,$Arguments)
        Assert ($ClassName -eq 'Win32_Process' -and $MethodName -eq 'Create') 'Install uses detached WMI Create'
        Assert ([object]::ReferenceEquals($Arguments.ProcessStartupInformation,$script:startup)) 'Create receives the actual hidden startup information'
        Assert ($Arguments.CommandLine -match 'Start-WindowsControl\.ps1' -and $Arguments.CommandLine -match '-WindowStyle Hidden') 'hidden command starts the control bridge'
        $script:creates++;[pscustomobject]@{ReturnValue=0}
    }
    function Start-Sleep {param($Seconds) Write-ControlLog $logFile 'bridge.connected fixture'}
    function Test-ControlPidRecoveryPending {param($PidFile) $false}
    & {$PSScriptRoot=$repo;Invoke-Expression $installBranch.Extent.Text}
    Assert ($script:creates -eq 1) 'normal Install creates exactly one hidden process'
    Write-Output ('PASS: '+$count+' control supervision checks (real CRLF PID files; Windows process/start fixtures)')
}finally{
    $env:LOCALAPPDATA=$oldLocal;$env:SystemRoot=$oldSystemRoot
    if($temporary){Remove-Item -LiteralPath $TestHome -Recurse -Force}
}
