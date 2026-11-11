#requires -Version 5.1
[CmdletBinding()]
param([Alias('Home')][string]$LauncherHome=(Join-Path $env:LOCALAPPDATA 'RemoteAgents'),[int]$ParentPid=0,[switch]$Once,[switch]$LibraryOnly)
# Repository and packaged paths are the same (control/ is packaged at bundle root).
$bundle=Split-Path $PSScriptRoot -Parent
if(-not (Test-Path (Join-Path $bundle 'transport/Transport.Common.ps1'))){$bundle=Split-Path (Split-Path $bundle -Parent) -Parent}
. (Join-Path $bundle 'transport/Transport.Common.ps1')
function Get-ControlMonitorStatus([string]$Root) {
    $result=@{ok=$false;summary='Управление выключено';processAlive=$false;lastContact=$null;updatedAt=[DateTime]::UtcNow.ToString('o')}
    $base=Join-Path $env:LOCALAPPDATA 'RemoteAgents/control'
    if(Test-Path -LiteralPath (Join-Path $Root 'managed-control/control.pid')){$base=Join-Path $Root 'managed-control'}
    try {
        $pidFile=Join-Path $base 'control.pid';if(-not (Test-Path -LiteralPath $pidFile)){return $result}
        $id=0;if(-not [int]::TryParse([IO.File]::ReadAllText($pidFile).Trim(),[ref]$id)){return $result}
        $p=Get-CimInstance Win32_Process -Filter "ProcessId=$id"|Where-Object {$_.ProcessId -eq $id -and $_.CommandLine -match 'Start-WindowsControl\.ps1'}|Select-Object -First 1
        if(-not $p){return $result}
        $result.processAlive=$true;$result.summary='Управление: нет связи'
        $heartbeat=Read-TransportJson (Join-Path $base 'heartbeat.json')
        $contact=Convert-TransportUtc $heartbeat.updatedAt
        $result.lastContact=$contact.ToString('o')
        $age=([DateTime]::UtcNow-$contact).TotalSeconds
        # The broker has authenticated status through server -> reverse SSH -> executor.
        # Match the current root process: a prior session cannot renew this one.
        if($heartbeat.ok -and [int]$heartbeat.pid -eq $id -and $age -ge -5 -and $age -le 40 -and $contact -ge ([DateTime]$p.CreationDate).ToUniversalTime().AddSeconds(-2)){
            $result.ok=$true;$result.summary='Управление включено'
        }
    }catch{$result.ok=$false;$result.summary='Управление: нет данных'}
    $result
}
function Restart-ManagedControl([string]$Root){
    & (Join-Path $bundle 'Start-WindowsControl.ps1') -Install -LauncherHome $Root *> $null
}
function Update-ControlSupervision([string]$Root,$Status,$State,[DateTime]$Now){
    if($Status.ok){$State.failures=0}else{$State.failures++}
    if($State.failures -lt 3 -or $Now -lt $State.nextRestart){return}
    # Only the managed bridge belongs to this launcher. No action on a foreign PID.
    if(Test-Path (Join-Path $Root 'managed-control/control.pid')){
        try{Restart-ManagedControl $Root}catch{}
    }
    $State.failures=0;$State.nextRestart=$Now.AddSeconds(120)
}
if($LibraryOnly){return}
$parent=$null;if($ParentPid -gt 0){$parent=[Diagnostics.Process]::GetProcessById($ParentPid);[void]$parent.Handle}
$supervision=@{failures=0;nextRestart=[DateTime]::UtcNow.AddSeconds(90)}
do {
    $status=Get-ControlMonitorStatus $LauncherHome
    Update-ControlSupervision $LauncherHome $status $supervision ([DateTime]::UtcNow)
    Write-TransportJson (Join-Path $LauncherHome 'status/control.json') $status
    if($Once){break}
    for($i=0;$i -lt 10;$i++){if(($parent -and $parent.HasExited) -or (Test-Path -LiteralPath (Join-Path $LauncherHome 'stop'))){return};Start-Sleep -Seconds 1}
}while($true)
