#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
$count=0
function Assert($ok,$why){if(-not $ok){throw $why};$script:count++}
function Adapter($Name,$Index,$Description=$Name,$Status='Up',$Hardware=$false){
    [pscustomobject]@{Name=$Name;ifIndex=$Index;InterfaceDescription=$Description;Status=$Status;HardwareInterface=$Hardware}
}
$physical=Adapter 'Ethernet' 1 'Ethernet' 'Up' $true
$split=Adapter 'Office' 7 'OpenVPN TAP-Windows'
$tailscale=Adapter 'Tailscale' 8 'Tailscale Tunnel'
$own=Adapter 'RemoteAgents-TUN' 9 'Wintun'
$script:fixture=[pscustomobject]@{Processes=@();Routes=@();Adapters=@($physical);DnsServers=@([pscustomobject]@{InterfaceIndex=1;ServerAddresses=@('192.0.2.53')});DnsClients=@([pscustomobject]@{InterfaceIndex=1;ConnectionSpecificSuffix='isp.example'});Nrpt=@()}
function Policy {Find-VpnDnsPolicy $script:fixture 'Ethernet' 'RemoteAgents-TUN'}
Assert ((Policy).strictRoute) 'physical resolver/suffix does not disable strict DNS'
$fixture.Adapters+=@($split,$tailscale)
Assert ((Policy).strictRoute) 'active partial adapters without DNS do not disable strict DNS'
$fixture.DnsServers+=@([pscustomobject]@{InterfaceIndex=7;ServerAddresses=@('10.9.0.53','fd00::53')})
$policy=Policy
Assert (-not $policy.strictRoute -and $policy.networks.Count -eq 1 -and $policy.networks[0].name -eq 'Office' -and $policy.networks[0].servers.Count -eq 2) 'renamed OpenVPN detected by description; IPv4 and IPv6 DNS retained'
$split.Status='Disconnected'
Assert ((Policy).strictRoute) 'inactive split DNS ignored'
$split.Status='Up';$fixture.DnsServers=@()
$fixture.DnsClients=@([pscustomobject]@{InterfaceIndex=8;ConnectionSpecificSuffix='tail123.ts.net'})
Assert (-not (Policy).strictRoute -and (Policy).networks[0].suffixes[0] -eq 'tail123.ts.net') 'MagicDNS suffix without adapter DNS still preserves partial DNS'
$fixture.DnsClients=@([pscustomobject]@{InterfaceIndex=8;ConnectionSpecificSuffixSearchList=@('corp.example','tail123.ts.net')})
Assert ((Policy).networks[0].suffixes.Count -eq 2) 'connection-specific suffix search list preserved'
$fixture.DnsClients=@()
$fixture.Nrpt=@([pscustomobject]@{Namespace=@('.tail123.ts.net','.corp.example');NameServers=@('100.100.100.100')})
$policy=Policy
Assert (-not $policy.strictRoute -and $policy.networks.Count -eq 2 -and $policy.networks[1].nrpt[0].namespaces.Count -eq 2) 'effective NRPT-only MagicDNS preserved even without per-adapter DNS; ownership not guessed'
$fixture.Adapters=@($physical,$own)
$fixture.DnsServers=@([pscustomobject]@{InterfaceIndex=9;ServerAddresses=@('172.31.255.2')})
Assert ((Policy).strictRoute) 'own TUN DNS and stale NRPT without active partial adapter ignored'
$fixture.Adapters=@($physical,(Adapter 'Lab' 11 'Hyper-V Virtual Ethernet'))
$fixture.Nrpt=@();$fixture.DnsServers=@([pscustomobject]@{InterfaceIndex=11;ServerAddresses=@('172.20.0.53')})
Assert (-not (Find-VpnConflicts $fixture).conflict -and -not (Policy).strictRoute) 'other allowed virtual partial network with own DNS preserved'
$fixture.Adapters=@($physical,$split,$tailscale);$fixture.DnsServers=@(
    [pscustomobject]@{InterfaceIndex=7;ServerAddresses=@('10.9.0.53')},
    [pscustomobject]@{InterfaceIndex=8;ServerAddresses=@('100.100.100.100')})
Assert ((Policy).networks.Count -eq 2) 'all responsible networks retained in diagnostics'
$fixture.Adapters=@($physical)
Assert ((Policy).strictRoute) 'next enable recalculates strict protection after split network disappears'
$missing=[pscustomobject]@{Adapters=@();DnsServers=@();DnsClients=@()}
$failed=$false;try{Find-VpnDnsPolicy $missing 'Ethernet' 'RemoteAgents-TUN'|Out-Null}catch{$failed=$true}
Assert $failed 'missing DNS/NRPT inventory refuses decision'

# Exercise the actual inventory entry point with cmdlet mocks: no Windows/network access.
function Get-CimInstance {param($Class,$ErrorAction) @()}
function Get-NetAdapter {param([switch]$IncludeHidden,$ErrorAction) $fixture.Adapters}
function Get-NetRoute {param($ErrorAction) @()}
function Get-DnsClientServerAddress {param($ErrorAction) if($script:failRead -eq 'servers'){throw 'fixture'};$fixture.DnsServers}
function Get-DnsClient {param($ErrorAction) if($script:failRead -eq 'clients'){throw 'fixture'};$fixture.DnsClients}
function Get-DnsClientNrptPolicy {param([switch]$Effective,$ErrorAction) Assert $Effective 'inventory requests effective NRPT';if($script:failRead -eq 'nrpt'){throw 'fixture'};$fixture.Nrpt}
$script:failRead=''
$snapshot=Get-VpnSnapshot -IncludeDns
Assert ((Find-VpnDnsPolicy $snapshot 'Ethernet' 'RemoteAgents-TUN').strictRoute) 'empty successful DNS inventory is valid'
foreach($part in @('servers','clients','nrpt')){
    $script:failRead=$part;$failed=$false
    try{Get-VpnSnapshot -IncludeDns|Out-Null}catch{$failed=$true}
    Assert $failed ('failed '+$part+' inventory cannot silently enable strict mode')
}
Write-Output ('PASS: '+$count+' DNS policy checks; mocked inventory only')
