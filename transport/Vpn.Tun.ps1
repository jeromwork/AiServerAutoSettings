#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName='Status')]
param([Alias('Home')][string]$TransportHome=(Join-Path $env:LOCALAPPDATA 'RemoteAgents'),
    [Parameter(Mandatory=$true,ParameterSetName='InspectLegacy')][switch]$InspectLegacy,
    [Parameter(Mandatory=$true,ParameterSetName='Cleanup')][switch]$Cleanup)
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
$root=Get-TransportHome $TransportHome;$action=$PSCmdlet.ParameterSetName
$conflict=[pscustomobject]@{conflict=$false;items=@()}
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
    # The adapter and default routes are machine resources, independent of Home/product/user.
    $gate=New-Object Threading.Mutex($false,'Global\RemoteAgents-VpnHost');$held=$false
    try{
        try{$held=$gate.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){throw 'Сначала выключите VPN в другом экземпляре программы'}
        Remove-VpnRemnants $root
    }finally{if($held){$gate.ReleaseMutex()};$gate.Dispose()}
    return
}
if($action -eq 'Status'){
    $file=Join-Path $root 'status/vpn.json'
    if(-not (Test-Path -LiteralPath $file)){Write-VpnStatus $root $false $false 'off' $conflict 'VPN выключен'}
    ConvertTo-Json -InputObject (Read-TransportJson $file) -Depth 10;return
}
