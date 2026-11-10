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
        $events=@(Get-Content -LiteralPath (Join-Path $base 'logs/control.log') -Encoding UTF8 -Tail 200|Where-Object {$_ -match 'bridge\.(connected|disconnected)|bridge returned|^.{19} (start pid=|error |prepare server)'})
        $last=$events|Select-Object -Last 1
        if($last -notmatch '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) bridge\.connected'){return $result}
        $contact=[DateTime]::ParseExact($Matches[1],'yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)
        $result.lastContact=$contact.ToUniversalTime().ToString('o')
        if($contact -lt ([DateTime]$p.CreationDate).AddSeconds(-2)){return $result}
        # A historic connected log alone is insufficient: require its live SSH child and socket.
        $children=@(Get-CimInstance Win32_Process -Filter "ParentProcessId=$id"|Where-Object {$_.ParentProcessId -eq $id -and $_.Name -match '^ssh(?:\.exe)?$' -and $_.CommandLine -match '(?:^|\s)"?-R'})
        foreach($child in $children){
            if(@(Get-NetTCPConnection -OwningProcess $child.ProcessId -State Established -ErrorAction SilentlyContinue).Count){$result.ok=$true;$result.summary='Управление включено';break}
        }
    }catch{$result.ok=$false;$result.summary='Управление: нет данных'}
    $result
}
if($LibraryOnly){return}
$parent=$null;if($ParentPid -gt 0){$parent=[Diagnostics.Process]::GetProcessById($ParentPid);[void]$parent.Handle}
do {
    Write-TransportJson (Join-Path $LauncherHome 'status/control.json') (Get-ControlMonitorStatus $LauncherHome)
    if($Once){break}
    for($i=0;$i -lt 10;$i++){if(($parent -and $parent.HasExited) -or (Test-Path -LiteralPath (Join-Path $LauncherHome 'stop'))){return};Start-Sleep -Seconds 1}
}while($true)
