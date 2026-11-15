#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
$work=Join-Path ([IO.Path]::GetTempPath()) ('vpn-lifecycle-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$count=0
function Assert($ok,$why){if(-not $ok){throw $why};$script:count++}
$global:vpnFixture=@{calls=@();mode='empty';enabled=$true}
$originalOs=$env:OS;$env:OS='Windows_NT'
try{
    Copy-Item (Join-Path $PSScriptRoot 'Vpn.Legacy.ps1') (Join-Path $work 'Vpn.Legacy.ps1')
    Copy-Item (Join-Path $PSScriptRoot 'Vpn.Tun.ps1') (Join-Path $work 'Vpn.Tun.ps1')
    $common=". '"+(Join-Path $PSScriptRoot 'Transport.Common.ps1').Replace("'","''")+"'`n"+@'
function Test-VpnAdministrator {$true}
function Protect-TransportPath($Path) {}
function Test-VpnHostAlive($Root) {$false}
function Set-VpnEnabled($Root,$Enabled){
    if(-not (Test-Path (Join-Path $Root 'state/vpn.stop'))){throw 'stop must precede config mutex'}
    $global:vpnFixture.enabled=$Enabled;$global:vpnFixture.calls+=@('config')
}
function Read-TransportSettings($Root){
    [pscustomobject]@{Options=[pscustomobject]@{singBoxPath=(Join-Path $Root 'fixture.exe')};Transport=[pscustomobject]@{bootstrap=$true};Vpn=[pscustomobject]@{checkUrl='https://check.example/'};Profile=@{}}
}
function Get-VpnSnapshot {
    $adapters=@();$routes=@()
    if($global:vpnFixture.mode -eq 'foreign'){
        $adapters=@([pscustomobject]@{ifIndex=7;Name='OpenVPN';Status='Up';HardwareInterface=$false;InterfaceDescription='OpenVPN'})
        $routes=@([pscustomobject]@{InterfaceIndex=7;DestinationPrefix='0.0.0.0/0';NextHop='0.0.0.0'})
    }
    if($global:vpnFixture.mode -eq 'own'){$adapters=@([pscustomobject]@{Name='RemoteAgents-TUN';ifIndex=4})}
    [pscustomobject]@{Processes=@();Adapters=$adapters;Routes=$routes}
}
function Get-TransportCandidates($Settings,$Root){$global:vpnFixture.calls+=@('candidates');@{}}
function Get-TransportNetwork {@{interface='fixture-physical'}}
function Get-VpnExclusions($Settings,$Paths,$Snapshot,$Root) {@('10.0.0.0/8')}
function New-VpnTunConfig($Settings,$Paths,$SelectedTag,$ExcludeCidrs,$Interface){$global:vpnFixture.calls+=@('generate');@{fixture=$true}}
function Test-TransportConfigFile($Exe,$File){$global:vpnFixture.calls+=@('check')}
function Register-ScheduledTask {throw 'no task creation permitted'}
function Start-ScheduledTask {throw 'no task start permitted'}
function Start-TransportProcess {throw 'preparation must never start a TUN'}
function Start-Process {throw 'no process or UAC expected'}
'@
    [IO.File]::WriteAllText((Join-Path $work 'Transport.Common.ps1'),$common,(New-Object Text.UTF8Encoding($true)))
    $root=Join-Path $work 'home';$script=Join-Path $work 'Vpn.Tun.ps1'
    & $script -Home $root -Disable
    Assert (-not $global:vpnFixture.enabled -and (Read-TransportJson (Join-Path $root 'status/vpn.json')).state -eq 'off') 'Disable signals host before config, returns off with no tasks or process launch'
    Write-VpnStatus $root $false $false 'rollback-error' @{} 'fixture cleanup failure'
    $failed=$false;try{& $script -Home $root -Disable}catch{$failed=$true}
    Assert ($failed -and (Read-TransportJson (Join-Path $root 'status/vpn.json')).state -eq 'rollback-error') 'Disable preserves host cleanup failure instead of claiming off'
    Write-VpnStatus $root $false $false 'off' @{} 'fixture'
    $global:vpnFixture.mode='own';$failed=$false
    try{& $script -Home $root -Disable}catch{$failed=$true}
    Assert ($failed -and (Read-TransportJson (Join-Path $root 'status/vpn.json')).state -eq 'rollback-error') 'Disable cannot claim off while our adapter remains'
    $global:vpnFixture.mode='empty'
    Remove-Item (Join-Path $root 'state/vpn.stop')
    Write-TransportJson (Join-Path $root 'state/vpn-session.json') @{session='fixture'}
    $global:vpnFixture.mode='foreign';$global:vpnFixture.calls=@()
    & $script -Home $root -Worker -Session fixture
    Assert ((Read-TransportJson (Join-Path $root 'status/vpn.json')).state -eq 'conflict' -and $global:vpnFixture.calls.Count -eq 0) 'full OpenVPN refuses before generation or process start'
    $global:vpnFixture.mode='empty'
    & $script -Home $root -Worker -Session fixture
    Assert ((Read-TransportJson (Join-Path $root 'status/vpn.json')).state -eq 'no-path' -and $global:vpnFixture.calls.Count -eq 0) 'bootstrapTag is no substitute for running transport proof'
    $proof=@{ok=$true;updatedAt=[DateTime]::UtcNow.ToString('o');active='fixture';network='net';configRevision='revision';candidates=@(@{tag='fixture';state='ok';enabled=$true})}
    # Feed CRLF JSON deliberately: Windows 5.1/7 must agree on evidence.
    Write-TransportJson (Join-Path $root 'status/transport.json') $proof
    $file=Join-Path $root 'status/transport.json';[IO.File]::WriteAllText($file,([IO.File]::ReadAllText($file).Replace("`r",'').Replace("`n","`r`n")))
    & $script -Home $root -Worker -Session fixture
    $plan=Read-TransportJson (Join-Path $root 'state/vpn-plan.json')
    Assert ($plan.session -eq 'fixture' -and $plan.tag -eq 'fixture' -and $plan.checkAddress -eq '198.18.0.1') 'prepared plan pins original proof and synthetic TUN-only HTTPS target'
    Assert (($global:vpnFixture.calls -join ',') -eq 'candidates,generate,check') 'Worker only prepares and validates; no live TUN, process, task or probe'
    $proof.updatedAt=[DateTime]::UtcNow.AddSeconds(20).ToString('o');Write-TransportJson $file $proof
    & $script -Home $root -Worker -Session fixture
    Assert ((Read-TransportJson (Join-Path $root 'status/vpn.json')).state -eq 'no-path') 'future transport proof is refused'
    $proof.updatedAt=[DateTime]::UtcNow.AddSeconds(-4).ToString('o');Write-TransportJson $file $proof
    & $script -Home $root -Worker -Session fixture
    Assert ((Read-TransportJson (Join-Path $root 'status/vpn.json')).state -eq 'no-path') 'stale transport proof is refused'
    Write-Output ('PASS: '+$count+' VPN lifecycle mock checks; no network mutation')
}finally{$env:OS=$originalOs;Remove-Variable vpnFixture -Scope Global;Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue}
