#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName='Status')]
param([Alias('Home')][string]$TransportHome=(Join-Path $env:LOCALAPPDATA 'RemoteAgents'),
    [Parameter(Mandatory=$true,ParameterSetName='Enable')][switch]$Enable,
    [Parameter(Mandatory=$true,ParameterSetName='Disable')][switch]$Disable,
    [Parameter(Mandatory=$true,ParameterSetName='Generate')][switch]$Generate,
    [Parameter(Mandatory=$true,ParameterSetName='Worker')][switch]$Worker,
    [Parameter(Mandatory=$true,ParameterSetName='Rollback')][switch]$Rollback,
    [Parameter(Mandatory=$true,ParameterSetName='InspectLegacy')][switch]$InspectLegacy,
    [Parameter(Mandatory=$true,ParameterSetName='Cleanup')][switch]$Cleanup,
    [string]$Session='', [string]$OutputConfig='', [int]$ParentPid=0, [string]$HostExe='')
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
$root=Get-TransportHome $TransportHome;$action=$PSCmdlet.ParameterSetName
$conflict=[pscustomobject]@{conflict=$false;items=@()}
$stopFile=Join-Path $root 'state/vpn.stop';$sessionFile=Join-Path $root 'state/vpn-session.json'
if($action -in @('InspectLegacy','Cleanup')){
    . (Join-Path $PSScriptRoot 'Vpn.Legacy.ps1')
    if($action -eq 'InspectLegacy'){
        # A live current host is not a remnant. Check pinned identity, not a bare PID.
        if(Test-VpnHostAlive $root){ConvertTo-Json -Compress @{found=$false};return}
        $found=Find-VpnRemnants $root (Get-VpnLegacySnapshot)
        ConvertTo-Json -Compress @{found=$found.found};return
    }
    if($env:OS -ne 'Windows_NT' -or -not (Test-VpnAdministrator)){throw 'Очистка требует администратора Windows'}
    if(Test-VpnHostAlive $root){throw 'Сначала выключите VPN'}
    Remove-VpnRemnants $root;return
}
if($action -eq 'Status'){
    $file=Join-Path $root 'status/vpn.json'
    if(-not (Test-Path -LiteralPath $file)){Write-VpnStatus $root $false $false 'off' $conflict 'VPN выключен'}
    ConvertTo-Json -InputObject (Read-TransportJson $file) -Depth 10;return
}
if($action -eq 'Disable'){
    # The host sees this before a potentially busy configuration mutex.
    Write-TransportJson $stopFile @{stop=$true}
    $deadline=[DateTime]::UtcNow.AddSeconds(4)
    while((Test-VpnHostAlive $root) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
    if(Test-VpnHostAlive $root){throw 'Выключение VPN ещё не подтверждено'}
    Set-VpnEnabled $root $false
    Write-VpnStatus $root $false $false 'off' $conflict 'VPN выключен';return
}
if($action -eq 'Rollback'){
    if($env:OS -ne 'Windows_NT' -or -not (Test-VpnAdministrator)){throw 'Очистка требует администратора Windows'}
    if(-not $Session -or (Read-TransportJson $sessionFile).session -ne $Session){return}
    $receipt=Join-Path $root 'state/vpn-interface.json'
    if(Test-Path $receipt){
        $owned=Read-TransportJson $receipt
        if($owned.session -ne $Session){return}
        $adapter=Get-NetAdapter -IncludeHidden -ErrorAction Stop|Where-Object {[string]$_.InterfaceGuid -eq [string]$owned.guid -and $_.Name -eq $owned.name}|Select-Object -First 1
        Clear-VpnRoutes $root $Session
        if($adapter){
            . (Join-Path $PSScriptRoot 'Vpn.Legacy.ps1')
            Remove-VpnLegacyAdapter $adapter
        }
    }
    return
}
try{
    if($action -eq 'Enable'){
        if($env:OS -ne 'Windows_NT'){throw 'VPN поддержан только на Windows'}
        if($ParentPid -le 0 -or -not $HostExe){throw 'Включите VPN кнопкой в окне или меню программы'}
        if(Test-VpnHostAlive $root){return}
        $parent=[Diagnostics.Process]::GetProcessById($ParentPid)
        try{$parentStart=$parent.StartTime.ToUniversalTime().Ticks}finally{$parent.Dispose()}
        $settings=Read-TransportSettings $root
        try{$null=Get-VpnTransportState $root $settings}catch{
            Write-VpnStatus $root $false $false 'no-path' $conflict 'VPN не включён: нет живого пути к серверу';return
        }
        $snapshot=Get-VpnSnapshot;$conflict=Find-VpnConflicts $snapshot @(Get-VpnOwnedProcessIds $root $snapshot)
        if($conflict.conflict){Write-VpnStatus $root $false $false 'conflict' $conflict 'Отключите другой VPN перед включением VPN RemoteAgents';return}
        $Session=[guid]::NewGuid().ToString('N')
        Write-TransportJson $sessionFile @{session=$Session} -Private
        Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
        Write-VpnStatus $root $false $true 'awaiting-uac' $conflict 'Ожидается разрешение Windows на включение'
        $args=@('--vpn-host','--home',$root,'--vpn-script',$PSCommandPath,'--vpn-session',$Session,'--vpn-parent',[string]$ParentPid,'--vpn-parent-start',[string]$parentStart)
        $hostProcess=Start-Process -FilePath $HostExe -ArgumentList (($args|ForEach-Object {Quote-Transport $_}) -join ' ') -Verb RunAs -WindowStyle Hidden -PassThru
        try{
            $deadline=[DateTime]::UtcNow.AddSeconds(35)
            while([DateTime]::UtcNow -lt $deadline){
                $status=Read-TransportJson (Join-Path $root 'status/vpn.json')
                if($status.state -eq 'on'){Set-VpnEnabled $root $true;return}
                if($hostProcess.HasExited){return}
                Start-Sleep -Milliseconds 100
            }
            Write-TransportJson $stopFile @{stop=$true};throw 'Включение не подтверждено'
        }finally{$hostProcess.Dispose()}
    }
    # Worker prepares a plan only: the native elevated host alone starts the core.
    if($action -eq 'Worker'){
        if(-not (Test-VpnAdministrator)){throw 'Нужны права администратора'}
        if(-not $Session -or (Read-TransportJson $sessionFile).session -ne $Session -or (Test-Path $stopFile)){throw 'Включение отменено'}
    }
    $settings=Read-TransportSettings $root;$v=Get-VpnOptions $settings
    $snapshot=Get-VpnSnapshot;$own=@(Get-VpnOwnedProcessIds $root $snapshot)
    $conflict=Find-VpnConflicts $snapshot $own
    if($conflict.conflict){Write-VpnStatus $root $false $false 'conflict' $conflict 'Отключите другой VPN перед включением VPN RemoteAgents';exit 1}
    if(@($snapshot.Adapters|Where-Object {$_.Name -eq $v.interfaceName}).Count){throw 'Остался адаптер прошлой версии. Выполните предложенную очистку'}
    try{$status=Get-VpnTransportState $root $settings}catch{
        Write-VpnStatus $root $false $false 'no-path' $conflict 'VPN не включён: нет живого пути к серверу';exit 1
    }
    $paths=Get-TransportCandidates $settings $root;$net=Get-TransportNetwork
    $exclude=Get-VpnExclusions $settings $paths $snapshot -Root $root
    $cfg=New-VpnTunConfig $settings $paths $status.active $exclude $net.interface
    $file=Join-Path $root 'state/vpn-sing-box.json'
    if($action -eq 'Generate'){$file=$OutputConfig;if(-not $file){$file=Join-Path $root 'state/vpn-generated.json'}}
    Write-TransportJson $file $cfg -Private;Test-TransportConfigFile $settings.Options.singBoxPath $file
    if($action -eq 'Generate'){Write-Output 'VPN-конфиг создан и проверен; VPN не запускался';return}
    # The probe targets a synthetic IPv4 routed through TUN. sing-box rewrites it
    # to checkUrl's host, preserving the probe's real TLS SNI/HTTP Host. No system
    # DNS lookup or uncontrollable DNS timeout runs on the host watchdog thread.
    Write-TransportJson (Join-Path $root 'state/vpn-plan.json') @{session=$Session;tag=$status.active;network=$status.network;revision=$status.configRevision;physical=$net.interface;interfaceName=$v.interfaceName;exe=[IO.Path]::GetFullPath($settings.Options.singBoxPath);checkUrl=$v.checkUrl;checkAddress=$v.probeAddress} -Private
}catch{
    # Never publish raw exceptions: they may contain secrets from configs or URIs.
    Write-VpnStatus $root $false $false 'error' $conflict 'VPN не включён: проверьте настройки и разрешение Windows'
    exit 1
}
