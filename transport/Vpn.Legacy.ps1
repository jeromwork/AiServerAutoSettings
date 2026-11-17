#requires -Version 5.1
# Read-only inventory is deliberately separate from the administrator-only rollback.
function Get-VpnLegacySnapshot {
    [pscustomobject]@{
        Adapters=@(Get-NetAdapter -IncludeHidden -ErrorAction Stop)
        Processes=@(Get-CimInstance Win32_Process -ErrorAction Stop)
        Tasks=@(Get-ScheduledTask -ErrorAction Stop | Where-Object {$_.TaskName -like 'RemoteAgents-TUN-*'})
    }
}
function Get-VpnLegacyInterfaces([string]$Root) {
    'RemoteAgents-TUN'
    try {
        $config=Read-TransportJson (Join-Path $Root 'config.json')
        $name=[string]$config.vpn.interfaceName
        # Keep the ownership contract of Get-VpnOptions; never accept Happ/OpenVPN names.
        if($name -match '^RemoteAgents-[a-zA-Z0-9_-]{1,32}$' -and $name -ne 'RemoteAgents-TUN'){$name}
    }catch{}
}
function Test-VpnLegacyProcess([string]$Root,$Process) {
    if(-not $Process.ExecutablePath -or -not $Process.CommandLine){return $false}
    try {
        $folder=[IO.Path]::GetFullPath($Root).TrimEnd('\','/').Replace('\','/')+'/'
        $exe=[IO.Path]::GetFullPath([string]$Process.ExecutablePath).Replace('\','/')
        if(-not $exe.StartsWith($folder,[StringComparison]::OrdinalIgnoreCase) -or
           [IO.Path]::GetFileName($exe) -ine 'sing-box.exe'){return $false}
        $config=(Join-Path $Root 'state/vpn-sing-box.json').Replace('\','/')
        $command=([string]$Process.CommandLine).Replace('\','/')
        return $command -match ('(?i)(?:^|\s)(?:-c|--config)\s+(?:"'+[regex]::Escape($config)+'"|'+[regex]::Escape($config)+')(?=\s|$)')
    }catch{return $false}
}
function Find-VpnRemnants([string]$Root,$Snapshot) {
    $names=@(Get-VpnLegacyInterfaces $Root)
    $adapters=@($Snapshot.Adapters | Where-Object {$_.Name -in $names})
    $processes=@($Snapshot.Processes | Where-Object {Test-VpnLegacyProcess $Root $_})
    $tasks=@($Snapshot.Tasks | Where-Object {$_.TaskName -like 'RemoteAgents-TUN-*'})
    @{found=($adapters.Count -gt 0 -or $processes.Count -gt 0 -or $tasks.Count -gt 0);adapters=$adapters;processes=$processes;tasks=$tasks}
}
function Remove-VpnLegacyAdapter($Adapter) {
    # Exact name/GUID is checked by the caller. PnP removal also removes a stale
    # Wintun device; removing routes alone leaves the next Enable blocked.
    if(-not $Adapter.PnPDeviceID){throw 'Не удалось определить устройство нашего адаптера'}
    $exe=Join-Path $env:SystemRoot 'System32/pnputil.exe'
    $p=Start-Process -FilePath $exe -ArgumentList ('/remove-device '+(Quote-Transport ([string]$Adapter.PnPDeviceID))) -PassThru -WindowStyle Hidden
    try{if(-not $p.WaitForExit(2000) -or $p.ExitCode -ne 0){throw 'Не удалось удалить наш старый адаптер'}}finally{if(-not $p.HasExited){$p.Kill()};$p.Dispose()}
}
function Open-VpnLegacyProcess([int]$Id) {
    $process=[Diagnostics.Process]::GetProcessById($Id)
    try{$null=$process.Handle;return $process}catch{$process.Dispose();throw}
}
function Stop-VpnLegacyProcess([string]$Root,$Process) {
    # Pin before the final inventory. Stop-Process -Id could kill a reused PID
    # between the CIM read and termination; a held process handle cannot be reused.
    $target=Open-VpnLegacyProcess ([int]$Process.ProcessId)
    try{
        $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$Process.ProcessId) -ErrorAction Stop
        if($current -and (Test-VpnLegacyProcess $Root $current)){
            $target.Kill()
            if(-not $target.WaitForExit(2000)){throw 'Не удалось остановить старый процесс VPN'}
        }
    }finally{$target.Dispose()}
}
function Remove-VpnRemnants([string]$Root) {
    # Caller elevates once. Stop workers before sing-box so a previous version cannot restart it.
    $found=Find-VpnRemnants $Root (Get-VpnLegacySnapshot)
    Write-TransportJson (Join-Path $Root 'state/vpn.stop') @{stop=$true}
    foreach($task in $found.tasks){Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop}
    foreach($proc in $found.processes){Stop-VpnLegacyProcess $Root $proc}
    # Equivalent to Clear-VpnRoutes, including installs whose session receipt was lost.
    # Every route is scoped to an exact adapter name in our reserved namespace, never the default route globally.
    foreach($adapter in @((Find-VpnRemnants $Root (Get-VpnLegacySnapshot)).adapters)){
        Get-NetRoute -InterfaceIndex $adapter.ifIndex -ErrorAction Stop | Remove-NetRoute -Confirm:$false -ErrorAction Stop
        if(@(Get-NetRoute -InterfaceIndex $adapter.ifIndex -ErrorAction Stop).Count){throw 'Не удалось убрать маршруты нашего VPN'}
        Remove-VpnLegacyAdapter $adapter
    }
    foreach($task in $found.tasks){Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop}
    $remaining=Find-VpnRemnants $Root (Get-VpnLegacySnapshot)
    if($remaining.processes.Count -or $remaining.tasks.Count -or $remaining.adapters.Count){throw 'Очистка VPN ещё не подтверждена'}
    if(Test-Path -LiteralPath (Join-Path $Root 'config.json')){Set-VpnEnabled $Root $false}
    foreach($name in @('vpn-session.json','vpn-owner.json','vpn-interface.json','vpn-sing-box.json','vpn-preflight.json','vpn-pending.json','vpn-generated.json')){
        Remove-Item -LiteralPath (Join-Path $Root ('state/'+$name)) -Force -ErrorAction SilentlyContinue
    }
    Write-VpnStatus $Root $false $false 'off' ([pscustomobject]@{conflict=$false;items=@()}) 'Системный VPN выключен; остатки прошлой версии убраны'
}
