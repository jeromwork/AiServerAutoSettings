#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$env:LOCALAPPDATA=$TestHome
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Wizard.Common.ps1')
. (Join-Path $repo 'transport/Vpn.Legacy.ps1')
$root=Join-Path $TestHome 'RemoteAgents'
[void][IO.Directory]::CreateDirectory($root)
$script:checks=0
function Assert($ok,$why){if(-not $ok){throw $why};$script:checks++}
Assert (-not (Test-ProductVpnEnabled)) 'VPN capability is false'
Write-TransportJson (Join-Path $root 'config.json') @{vpn=@{enabled=$true;interfaceName='RemoteAgents-Custom'};components=@{vpn=@{enabled=$true}};transport=@{keep='unchanged'};profile=@{vpn=@{enabled=$true}}}
Assert (-not (Get-VpnOptions ([pscustomobject]@{Vpn=[pscustomobject]@{enabled=$true}})).enabled) 'saved vpn.enabled is ignored'
function Invoke-InstallChild {throw 'Must not launch Enable'}
function Start-Process {throw 'Must not request UAC during Enable'}
function Register-ScheduledTask {throw 'Must not register TUN tasks'}
$r=Invoke-WizardStep $root $repo Vpn ([pscustomobject]@{enabled=$true})
Assert ($r.ok -and -not $r.enabled -and $r.summary -match 'отключено') 'wizard VPN is disabled, not an error'
$p=@(Get-WizardPlan ([pscustomobject]@{}) ([pscustomobject]@{vpnEnabled=$true;vpn=$false}))
Assert ($p[5].ready -and $p[5].summary -match 'Отключено') 'inspection never reports disabled VPN as an error'
foreach($mode in @('Enable','Broker','Worker')){
    $arguments=@{TransportHome=$root};$arguments[$mode]=$true
    $r=& (Join-Path $repo 'transport/Vpn.Tun.ps1') @arguments
    Assert ($r -match 'отключено') ($mode+' blocked before settings, UAC or registration')
}
$empty=[pscustomobject]@{Adapters=@();Processes=@();Tasks=@()}
Assert (-not (Find-VpnRemnants $root $empty).found) 'empty snapshot: no cleanup prompt'
foreach($name in @('RemoteAgents-TUN','RemoteAgents-Custom')){
    $s=[pscustomobject]@{Adapters=@([pscustomobject]@{Name=$name;ifIndex=42});Processes=@();Tasks=@()}
    Assert ((Find-VpnRemnants $root $s).found) ('adapter alone offers cleanup: '+$name)
}
$exe=Join-Path $root 'bundle/transport/sing-box.exe';$cfg=Join-Path $root 'state/vpn-sing-box.json'
$ours=[pscustomobject]@{ProcessId=123;ExecutablePath=$exe;CommandLine=('"'+$exe+'" run -c "'+$cfg+'"')}
$s=[pscustomobject]@{Adapters=@();Processes=@($ours);Tasks=@()}
Assert ((Find-VpnRemnants $root $s).found) 'our sing-box + exact VPN config, without owner receipt, offers cleanup'
$foreign=@(
    [pscustomobject]@{ProcessId=1;ExecutablePath=(Join-Path $TestHome 'Happ/sing-box.exe');CommandLine=$ours.CommandLine},
    [pscustomobject]@{ProcessId=2;ExecutablePath=$exe;CommandLine=('run -c "'+$cfg+'.foreign"')},
    [pscustomobject]@{ProcessId=3;ExecutablePath=$exe;CommandLine=('run -c "'+(Join-Path $root 'state/sing-box.json')+'"')},
    [pscustomobject]@{ProcessId=4;ExecutablePath=$exe;CommandLine=('run --log "'+$cfg+'"')},
    [pscustomobject]@{ProcessId=5;ExecutablePath=(Join-Path ($root+'-foreign') 'sing-box.exe');CommandLine=$ours.CommandLine}
)
$s=[pscustomobject]@{Adapters=@([pscustomobject]@{Name='Happ'},[pscustomobject]@{Name='OpenVPN'},[pscustomobject]@{Name='Tailscale'});Processes=$foreign;Tasks=@([pscustomobject]@{TaskName='Other-TUN-task'})}
Assert (-not (Find-VpnRemnants $root $s).found) 'foreign VPNs, channel process, config prefix and path prefix never offer cleanup'
$tasks=@([pscustomobject]@{TaskName='RemoteAgents-TUN-fixture';TaskPath='\'},[pscustomobject]@{TaskName='RemoteAgents-TUN-Rollback-fixture';TaskPath='\'})
Assert ((Find-VpnRemnants $root ([pscustomobject]@{Adapters=@();Processes=@();Tasks=$tasks})).found) 'tasks alone offer cleanup'
# All mutations below are mocks, including routes/tasks/processes. No live Windows or network operation.
$script:snapshot=[pscustomobject]@{Adapters=@([pscustomobject]@{Name='RemoteAgents-Custom';ifIndex=42},[pscustomobject]@{Name='Happ';ifIndex=10});Processes=@($ours)+$foreign;Tasks=$tasks+@([pscustomobject]@{TaskName='Happ';TaskPath='\'})}
$script:removedRoutes=@();$script:stopped=@();$script:deleted=@();$script:routePresent=$true
function Get-VpnLegacySnapshot {$script:snapshot}
function Stop-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction) Assert ($TaskName -like 'RemoteAgents-TUN-*') 'stop only our task'}
function Get-CimInstance {param($ClassName,$Filter,$ErrorAction) $script:snapshot.Processes | Where-Object {('ProcessId='+$_.ProcessId) -eq $Filter}}
function Stop-Process {param($Id,[switch]$Force,$ErrorAction) $script:stopped+=@($Id);$script:snapshot.Processes=@($script:snapshot.Processes|Where-Object {$_.ProcessId -ne $Id})}
function Wait-Process {param($Id,$Timeout,$ErrorAction)}
function Get-NetRoute {param($InterfaceIndex,$ErrorAction) Assert ($InterfaceIndex -eq 42) 'query only our routes';if($script:routePresent){[pscustomobject]@{InterfaceIndex=$InterfaceIndex}}}
function Remove-NetRoute {param([Parameter(ValueFromPipeline=$true)]$InputObject,[switch]$Confirm) process{$script:removedRoutes+=@($InputObject.InterfaceIndex);$script:routePresent=$false}}
function Unregister-ScheduledTask {param($TaskName,$TaskPath,[switch]$Confirm,$ErrorAction) $script:deleted+=@($TaskName);$script:snapshot.Tasks=@($script:snapshot.Tasks|Where-Object {$_.TaskName -ne $TaskName})}
Write-TransportJson (Join-Path $root 'state/vpn-owner.json') @{pid=1;exe='foreign'}
Write-TransportJson (Join-Path $root 'state/vpn-session.json') @{session='old'}
Remove-VpnRemnants $root
Assert ($script:stopped.Count -eq 1 -and $script:stopped[0] -eq 123) 'only our VPN process stopped, foreign and transport left running'
Assert ($script:removedRoutes.Count -eq 1 -and $script:removedRoutes[0] -eq 42) 'only routes of our adapter removed'
Assert ($script:deleted.Count -eq 2 -and $script:snapshot.Tasks[0].TaskName -eq 'Happ') 'only TUN tasks deleted'
$c=Read-TransportJson (Join-Path $root 'config.json');$status=Read-TransportJson (Join-Path $root 'status/vpn.json')
Assert (-not $c.vpn.enabled -and -not $c.components.vpn.enabled -and $status.state -eq 'off' -and -not $status.enabled) 'config and live status off after successful cleanup'
Assert ($c.transport.keep -eq 'unchanged' -and $c.profile.vpn.enabled) 'transport and desired profile preserved'
Assert (-not (Test-Path (Join-Path $root 'state/vpn-owner.json')) -and -not (Test-Path (Join-Path $root 'state/vpn-session.json'))) 'old owner and session receipts cleared'
Remove-VpnRemnants $root
Assert ($script:stopped.Count -eq 1 -and $script:deleted.Count -eq 2) 'repeat cleanup does not touch foreign resources'
# Failure must not claim off or discard ownership receipts needed for a later retry.
Write-TransportJson (Join-Path $root 'state/vpn-owner.json') @{pid=123}
Write-VpnStatus $root $true $true 'on' @{} 'old status'
$script:routePresent=$true
function Remove-NetRoute {param([Parameter(ValueFromPipeline=$true)]$InputObject,[switch]$Confirm) process{throw 'fixture: route removal failed'}}
$failed=$false;try{Remove-VpnRemnants $root}catch{$failed=$true}
Assert ($failed -and (Test-Path (Join-Path $root 'state/vpn-owner.json')) -and (Read-TransportJson (Join-Path $root 'status/vpn.json')).state -eq 'on') 'failed cleanup preserves receipts and does not publish off'
Write-Output ('PASS: '+$script:checks+' disabled VPN and legacy cleanup checks')
