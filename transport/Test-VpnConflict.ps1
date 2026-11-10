#requires -Version 5.1
[CmdletBinding()]
param([Alias('Home')][string]$TransportHome=(Join-Path $env:LOCALAPPDATA 'RemoteAgents'))
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
try{
    $snapshot=Get-VpnSnapshot;$own=@(Get-VpnOwnedProcessIds $TransportHome $snapshot)
    # Имя интерфейса исключается только пока подтверждён наш живой sing-box.
    $nic='';if($own.Count -gt 0 -and (Test-Path -LiteralPath (Join-Path $TransportHome 'state/vpn-owner.json'))){$owner=Read-TransportJson (Join-Path $TransportHome 'state/vpn-owner.json');if([int]$owner.pid -in $own){$settings=Read-TransportSettings $TransportHome;$nic=(Get-VpnOptions $settings).interfaceName}}
    Find-VpnConflicts $snapshot $own $nic|ConvertTo-Json -Depth 10
}catch{
    # Fail closed: инвентаризация недоступна — это не разрешение запускать TUN.
    [pscustomobject]@{conflict=$true;items=@([pscustomobject]@{kind='adapter';name='inventory';path='';detail='Не удалось проверить процессы, адаптеры или маршруты'})}|ConvertTo-Json -Depth 10
    exit 1
}
