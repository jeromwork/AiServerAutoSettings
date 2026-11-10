#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName='Auto')]
param([Alias('Home')][string]$TransportHome=(Join-Path $env:LOCALAPPDATA 'RemoteAgents'),
    [Parameter(Mandatory=$true,ParameterSetName='Auto')][switch]$Auto,
    [Parameter(Mandatory=$true,ParameterSetName='Tag')][string]$Tag)
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
$pin=@{mode='auto';tag=$null};if($PSCmdlet.ParameterSetName -eq 'Tag'){Assert-TransportTag $Tag;$pin=@{mode='pinned';tag=$Tag}}
Write-TransportJson (Join-Path $TransportHome 'state/transport-pin.json') $pin
ConvertTo-Json -InputObject $pin -Compress
