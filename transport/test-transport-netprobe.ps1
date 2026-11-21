#requires -Version 5.1
# M0b: fake .NET/CIM/WinRT sources; manual events and clocks, no network or elapsed-time assertions.
param([switch]$CompileOnly)
$ErrorActionPreference='Stop'
$daemonAst=$null
foreach($name in @('Transport.Common.ps1','Transport.Daemon.ps1','test-transport-netprobe.ps1')){
    $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$null,[ref]$errors)
    if($errors.Count){throw ($errors|Out-String)}
    if($name -eq 'Transport.Daemon.ps1'){$daemonAst=$ast}
}
if($CompileOnly){'M0b syntax PASS';return}
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
function Assert($Value,[string]$Message){if(-not $Value){throw ('M0b: '+$Message)}}
$script:fakeNow=[long]1000000
function Get-DaemonTime {$script:fakeNow}
foreach($fn in $daemonAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Add-DaemonQueuedEvent','Start-DaemonReader')},$true)){
    . ([scriptblock]::Create($fn.Extent.Text))
}
$networkPass=$daemonAst.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$networkRefreshPending -or (-not $script:TransportBusConnected -and $now -ge $nextNetwork)'},$true)
Assert ($networkPass.Count -eq 1) 'daemon network pass not found'
$networkPass=[scriptblock]::Create($networkPass[0].Extent.Text)
function New-FakeNic([string]$Id,[string]$Name,[string]$Status,[string[]]$Addresses,[string[]]$Gateways,[Net.NetworkInformation.NetworkInterfaceType]$Type='Wireless80211'){
    $nic=[pscustomobject]@{Id=$Id;Name=$Name;OperationalStatus=$Status;NetworkInterfaceType=$Type;Properties=[pscustomobject]@{
        UnicastAddresses=@($Addresses|ForEach-Object {[pscustomobject]@{Address=$_}})
        GatewayAddresses=@($Gateways|ForEach-Object {[pscustomobject]@{Address=$_}})}}
    $nic|Add-Member ScriptMethod GetIPProperties {$this.Properties}
    $nic
}
$script:source=@{nicCalls=0;cimCalls=0;profileCalls=0;released=(New-Object 'Collections.Generic.List[string]');
    index=7;name='Wi-Fi';ip='192.0.2.20';gateway='192.0.2.1';throwCost=$false;throwInterfaces=$false;throwNetwork=$false;noProfile=$false}
$script:cost=[pscustomobject]@{kind='cost';NetworkCostType='Fixed';Roaming=$false;OverDataLimit=$false;ApproachingDataLimit=$false}
$script:profile=[pscustomobject]@{kind='profile'}
$profile|Add-Member ScriptMethod GetConnectionCost {if($script:source.throwCost){throw 'fake cost failure'};$script:cost}
$wifi=New-FakeNic 'wifi-id' 'Wi-Fi' 'Up' @('192.0.2.20','2001:db8::1') @('192.0.2.1','2001:db8::2')
$loopback=New-FakeNic 'lo-id' 'Loopback' 'Up' @('127.0.0.1') @() -Type Loopback
$tunnel=New-FakeNic 'tun-id' 'Wintun' 'Up' @('198.18.0.1') @() -Type Tunnel
$script:source.nics=@($wifi,$loopback)
function Get-TransportNetworkInterfaces {$script:source.nicCalls++;if($source.throwInterfaces){throw 'fake interfaces failure'};$script:source.nics}
function Get-NetAdapter {param([switch]$Physical,$ErrorAction)
    Assert ([bool]$Physical) 'physical adapter filter lost';$script:source.cimCalls++
    if($source.throwNetwork){throw 'fake CIM not ready'}
    [pscustomobject]@{ifIndex=$source.index;Name=$source.name;InterfaceDescription='Physical NIC';Status='Up';HardwareInterface=$true}
    [pscustomobject]@{ifIndex=99;Name='Tailscale';InterfaceDescription='Tailscale';Status='Up';HardwareInterface=$true}
}
function Get-NetRoute {param($DestinationPrefix,$ErrorAction)
    $script:source.cimCalls++;[pscustomobject]@{InterfaceIndex=$source.index;NextHop=$source.gateway;RouteMetric=5}
}
function Get-NetIPInterface {param($InterfaceIndex,$AddressFamily,$ErrorAction)
    $script:source.cimCalls++;[pscustomobject]@{InterfaceMetric=10}
}
function Get-NetConnectionProfile {param($InterfaceIndex,$ErrorAction)
    $script:source.cimCalls++;[pscustomobject]@{Name='Office'}
}
function Get-NetNeighbor {param($InterfaceIndex,$IPAddress,$ErrorAction)
    $script:source.cimCalls++;[pscustomobject]@{State='Reachable';LinkLayerAddress='AA:BB:CC:DD:EE:FF'}
}
function Get-NetIPAddress {param($InterfaceIndex,$AddressFamily,$ErrorAction)
    $script:source.cimCalls++;[pscustomobject]@{AddressState='Preferred';IPAddress=$source.ip}
}
function Get-TransportInternetConnectionProfile {$script:source.profileCalls++;if(-not $source.noProfile){$script:profile}}
function Release-TransportComObject($Value){if($null -ne $Value){$script:source.released.Add([string]$Value.kind)}}
function Reset-Counters {
    $script:TransportNetProbes=[long]0;$script:TransportNetFingerprintChecks=[long]0;$script:TransportMeteredCalls=[long]0
    $script:source.nicCalls=0;$script:source.cimCalls=0;$script:source.profileCalls=0;$script:source.released.Clear()
}
$auto=[pscustomobject]@{metered='auto'}
# Stable signature under reordering of adapters, addresses and gateways.
$sig=Get-TransportNetworkSignature
$script:source.nics=@($loopback,$wifi)
[Array]::Reverse($wifi.Properties.UnicastAddresses);[Array]::Reverse($wifi.Properties.GatewayAddresses)
Assert ((Get-TransportNetworkSignature) -ceq $sig) 'enumeration order changes signature'
foreach($field in @('Id','Name','OperationalStatus')){
    $old=$wifi.$field;$wifi.$field=$old+'changed'
    Assert ((Get-TransportNetworkSignature) -cne $sig) ('signature ignores '+$field)
    $wifi.$field=$old
}
$old=$wifi.Properties.GatewayAddresses[0].Address;$wifi.Properties.GatewayAddresses[0].Address='203.0.113.1'
Assert ((Get-TransportNetworkSignature) -cne $sig) 'signature ignores gateway'
$wifi.Properties.GatewayAddresses[0].Address=$old
# Recreating tunnel/loopback interfaces must not invalidate a physical signature.
$script:source.nics=@($wifi,$loopback,$tunnel)
Assert ((Get-TransportNetworkSignature) -ceq $sig) 'tunnel addition changes signature'
$loopback.Id='new-loopback';$loopback.Properties.UnicastAddresses[0].Address='127.0.0.2'
$tunnel.Id='new-tunnel';$tunnel.Name='Recreated TUN';$tunnel.OperationalStatus='Down'
$tunnel.Properties.UnicastAddresses[0].Address='198.18.0.2'
Assert ((Get-TransportNetworkSignature) -ceq $sig) 'virtual adapter churn changes signature'
$script:source.nics=@($wifi)
Assert ((Get-TransportNetworkSignature) -ceq $sig) 'virtual adapter removal changes signature'
Reset-Counters
$first=Get-TransportNetworkSnapshot $auto
Assert ($first.network.available -and $first.network.ip -eq '192.0.2.20' -and $first.network.ifIndex -eq 7 -and $first.metered -eq $true) 'initial heavy result/fields lost'
for($i=0;$i -lt 1000;$i++){
    $cached=Get-TransportNetworkSnapshot $auto
    Assert ([object]::ReferenceEquals($first,$cached)) 'snapshot not returned from cache'
}
Assert ($TransportNetProbes -eq 1 -and $TransportMeteredCalls -eq 1 -and $TransportNetFingerprintChecks -eq 1001) 'stable pass counters'
Assert ($source.cimCalls -eq 6 -and $source.profileCalls -eq 1 -and $source.nicCalls -eq 1001) 'stable passes call CIM/WinRT'
Assert (($source.released -join ',') -eq 'cost,profile') 'successful WinRT call did not release both objects'
'N=1000 unchanged: additional netProbes=0 meteredCalls=0 PASS'
# Run the actual daemon branch with a manual clock; preserve network-change handling.
$network=$first.network;$metered=$first.metered;$engine=$null;$decision=$null
$settings=[pscustomobject]@{Options=[pscustomobject]@{metered='auto';bindPhysical=$false}}
$now=[DateTime]'2000-01-01T00:00:00Z';$nextNetwork=$now;$networkRefreshPending=$false
$script:networkStops=0;$script:networkUpdates=0;$script:observationStops=0
function Stop-TransportProbes {$script:networkStops++}
function Stop-DaemonObservation {$script:observationStops++}
function Update-DaemonNetworkRows($PreviousPaths){$script:networkUpdates++}
$source.ip='192.0.2.21';$wifi.Properties.UnicastAddresses[0].Address=$source.ip
. $networkPass
Assert ($TransportNetProbes -eq 2 -and $TransportMeteredCalls -eq 2 -and $TransportNetFingerprintChecks -eq 1002) 'signature change must refresh exactly once'
Assert ($network.ip -eq $source.ip -and (Test-TransportNetworkChanged $first.network $network)) 'daemon did not apply changed network'
Assert ($networkStops -eq 1 -and $observationStops -eq 1 -and $networkUpdates -eq 1) 'network-change handling changed'
$changed=Get-TransportNetworkSnapshot $auto
Assert ($TransportNetProbes -eq 2 -and $changed.network.ip -eq $source.ip) 'changed snapshot not cached'
# Invalidation survives reducer drain/queue loss and bypasses the existing next-network tick.
$eventQueue=@();$DaemonEventLimit=512;$script:daemonEventsQueued=[long]0;$script:daemonEventsDropped=[long]0
Add-DaemonQueuedEvent @{kind='net-change'}
$script:eventQueue=@()
Assert $networkRefreshPending 'net-change invalidation lost on queue drain'
. $networkPass
Assert (-not $networkRefreshPending -and $TransportNetProbes -eq 3 -and $TransportMeteredCalls -eq 3) 'queued net-change did not force one refresh'
. $networkPass
Assert ($TransportNetProbes -eq 3 -and $networkUpdates -eq 1) 'forced refresh repeats or invents a network change'
Assert ((Get-TransportNetworkSnapshot ([pscustomobject]@{metered='false'})).metered -eq $false) 'explicit false ignored'
Assert ((Get-TransportNetworkSnapshot ([pscustomobject]@{metered='true'})).metered -eq $true) 'explicit true ignored'
Assert ((Get-TransportNetworkSnapshot $auto).metered -eq $true -and $TransportMeteredCalls -eq 3) 'config override triggers WinRT or destroys cached auto cost'
'signature change / queued net-change / cached overrides PASS'
# Source failure is a stable signature too, not a new heavy poll on each pass.
$source.throwInterfaces=$true
[void](Get-TransportNetworkSnapshot $auto);[void](Get-TransportNetworkSnapshot $auto)
Assert ($TransportNetProbes -eq 4) 'unavailable fingerprint retriggers heavy calls'
$source.throwInterfaces=$false
[void](Get-TransportNetworkSnapshot $auto)
Assert ($TransportNetProbes -eq 5) 'fingerprint recovery not detected'
# A real probe exception (fake CIM) is cached briefly, then Force can recover with the same signature.
$script:TransportNetworkSnapshot=$null;Reset-Counters
$source.throwNetwork=$true
$failed=Get-TransportNetworkSnapshot $auto
Assert (-not $failed.network.available -and $failed.at -eq $fakeNow -and $TransportNetProbes -eq 1) 'probe exception not captured'
$source.throwNetwork=$false
$cached=Get-TransportNetworkSnapshot $auto
Assert ([object]::ReferenceEquals($failed,$cached) -and $TransportNetProbes -eq 1) 'failed snapshot not cached'
$recovered=Get-TransportNetworkSnapshot $auto -Force
Assert ($recovered.network.available -and $recovered.signature -ceq $failed.signature -and $TransportNetProbes -eq 2) 'Force did not recover with unchanged signature'
# Once a bus event has been accepted, only explicit invalidation refreshes even a failed generation.
$script:TransportBusConnected=$true
$source.throwNetwork=$true
$failed=Get-TransportNetworkSnapshot $auto -Force
$source.throwNetwork=$false;$before=$TransportNetProbes
$cached=Get-TransportNetworkSnapshot $auto
Assert ([object]::ReferenceEquals($failed,$cached) -and $TransportNetProbes -eq $before) 'connected failed snapshot retried without event'
Add-DaemonQueuedEvent @{kind='win.route.changed'}
. $networkPass
Assert ($network.available -and $TransportNetProbes -eq ($before+1)) 'route notification did not recover failed snapshot'
# Cost changes invisible to the signature are picked up by net.change, without periodic probing.
$cost.NetworkCostType='Unrestricted'
$unmetered=Get-TransportNetworkSnapshot $auto -Force
Assert ($unmetered.network.available -and $unmetered.metered -eq $false) 'initial unmetered snapshot lost'
$cost.NetworkCostType='Fixed';$before=$TransportNetProbes;$meteredBefore=$TransportMeteredCalls;$fingerprintsBefore=$TransportNetFingerprintChecks
for($i=0;$i -lt 10;$i++){. $networkPass;[void](Get-TransportNetworkSnapshot $auto)}
Assert ($TransportNetProbes -eq $before -and $TransportMeteredCalls -eq $meteredBefore -and $TransportNetFingerprintChecks -eq $fingerprintsBefore) 'connected cache still polls network/cost/signature'
Add-DaemonQueuedEvent @{kind='net-change'}
. $networkPass
Assert ($metered -eq $true -and $TransportNetProbes -eq ($before+1) -and $TransportMeteredCalls -eq ($meteredBefore+1)) 'network event did not refresh cost exactly once'
. $networkPass
Assert ($TransportNetProbes -eq ($before+1)) 'network event refreshed more than once'
'connected snapshot / route event recovery / net.change cost refresh PASS'
# Both existing daemon recovery paths must force a fresh probe.
$recoveryTests=@{
    bind='$engine -and $bindState.none -and $now -ge $nextBindRetry -and -not $directCheck -and -not $pathChecks.Count -and -not $eventQueue.Count'
    start='$startFailures -gt 0 -and $settings.Options.bindPhysical'
}
foreach($condition in $recoveryTests.Values){
    $branch=@($daemonAst.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq $condition},$true))
    Assert ($branch.Count -eq 1) ('daemon recovery branch not found: '+$condition)
    $calls=@($branch[0].FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-TransportNetworkSnapshot'},$true))
    Assert ($calls.Count -eq 1 -and @($calls[0].CommandElements|Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Force'}).Count -eq 1) 'daemon recovery uses stale cache'
}
'daemon recovery Force paths PASS'
# Diagnostic flags suppress their source, including startup and explicit invalidation.
$script:TransportDiag=Get-TransportDiagFlags 'no-network,no-metered';$script:TransportNetworkSnapshot=$null;$script:TransportNetworkStub=$null
Reset-Counters
$disabled=Get-TransportNetworkSnapshot $auto
[void](Get-TransportNetworkSnapshot $auto -Force)
Assert (-not $disabled.network.available -and $null -eq $disabled.metered) 'disabled sources need empty/unknown result'
Assert ($TransportNetProbes -eq 0 -and $TransportNetFingerprintChecks -eq 0 -and $TransportMeteredCalls -eq 0 -and $source.nicCalls -eq 0 -and $source.cimCalls -eq 0 -and $source.profileCalls -eq 0) 'no-network/no-metered still poll'
$script:TransportDiag=Get-TransportDiagFlags 'no-network';$script:TransportNetworkSnapshot=$null
[void](Get-TransportNetworkSnapshot $auto)
Assert ($TransportNetProbes -eq 0 -and $source.nicCalls -eq 0 -and $TransportMeteredCalls -eq 1) 'no-network affects wrong source'
$script:TransportDiag=Get-TransportDiagFlags 'no-metered';$script:TransportNetworkSnapshot=$null
Reset-Counters
[void](Get-TransportNetworkSnapshot $auto)
Assert ($TransportNetProbes -eq 1 -and $TransportMeteredCalls -eq 0 -and $source.profileCalls -eq 0) 'no-metered affects wrong source'
$paths=[pscustomobject]@{Candidates=@([pscustomobject]@{tag='a'})};$pin=[pscustomobject]@{mode='auto'};$secret='fake';$reader=$null
$script:readerStarts=0
function Stop-TransportEvents($Reader){}
function Start-TransportEvents {param($ApiPort,$Secret,$Tags,$StallSeconds,$StallConns) $script:readerStarts++;[pscustomobject]@{fake=$true}}
$script:TransportDiag=Get-TransportDiagFlags 'no-connections'
Start-DaemonReader
Assert ($readerStarts -eq 0 -and $null -eq $reader) 'no-connections starts reader'
$script:TransportDiag=@{}
Start-DaemonReader
Assert ($readerStarts -eq 1 -and $null -ne $reader) 'reader not started without no-connections'
'no-network / no-metered / no-connections PASS'
# WinRT cleanup on null profile, GetConnectionCost failure and normal cost mappings.
$source.throwCost=$true;$source.released.Clear()
Assert ($null -eq (Get-TransportMetered $auto)) 'WinRT failure should be unknown'
Assert (($source.released -join ',') -eq 'profile') 'WinRT exception leaked profile'
$source.throwCost=$false;$source.noProfile=$true;$source.released.Clear()
Assert ($null -eq (Get-TransportMetered $auto) -and $source.released.Count -eq 0) 'null profile not handled'
$source.noProfile=$false
foreach($type in @('Variable','Fixed','Unrestricted','Unknown')){
    $cost.NetworkCostType=$type;$source.released.Clear();$value=Get-TransportMetered $auto
    if($type -in @('Variable','Fixed')){Assert ($value -eq $true) 'metered cost mapping'}
    elseif($type -eq 'Unrestricted'){Assert ($value -eq $false) 'unrestricted cost mapping'}
    else{Assert ($null -eq $value) 'unknown cost mapping'}
    Assert (($source.released -join ',') -eq 'cost,profile') 'cost mapping bypassed cleanup'
}
# Only gc-collect adds the post-collection heap field; counters go into transport.mem.
$sample=Get-TransportMemSample;$fields=Get-TransportMemFields $sample 400
foreach($key in @('gen0','gen1','gen2','netProbes','netFingerprintChecks','meteredCalls')){Assert ($fields.Contains($key) -and $fields[$key] -ge 0) ('missing memory counter '+$key)}
Assert ($fields.netProbes -eq $TransportNetProbes -and $fields.netFingerprintChecks -eq $TransportNetFingerprintChecks -and $fields.meteredCalls -eq $TransportMeteredCalls) 'memory counters disagree'
Assert (-not $sample.Contains('gcHeapAfterCollect') -and -not $fields.Contains('gcHeapAfterCollect')) 'post-GC heap exposed without flag'
$script:TransportDiag=Get-TransportDiagFlags 'gc-collect'
$sample=Get-TransportMemSample;$fields=Get-TransportMemFields $sample 400
Assert ($sample.gcHeapAfterCollect -gt 0 -and $fields.Contains('gcHeapAfterCollect')) 'gc-collect missing post-GC heap'
foreach($flag in @('no-revision','status-30s','decide-on-event','no-connections','no-metered','no-network','gc-collect','decide-every-tick','status-always')){
    Assert ((Get-TransportDiagFlags $flag).ContainsKey($flag)) ('old flag lost: '+$flag)
}
'WinRT cleanup / memory diagnostics / existing flags PASS'
'M0b netprobe PASS'
