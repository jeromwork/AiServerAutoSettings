$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('netstate-'+[guid]::NewGuid().ToString('N'))
$script=Join-Path $PSScriptRoot 'Collect-NetState.ps1'
function Assert($ok,$message){if(!$ok){throw $message}}
# Deterministic scheduler: execute the actual worker with injected commands in this
# session; the firewall job models a worker which never completes.
$netstateScheduler=@{HangFirewall=$true;HungParts=@();RemovedJobs=@()}
function Start-Job {param($ScriptBlock,$ArgumentList)
 # Use inherited state: $script: inside this mock would refer to Collect-NetState.ps1.
 if($ArgumentList[0] -eq 'firewall' -and $netstateScheduler.HangFirewall){
  $netstateScheduler.HungParts+=@('firewall')
  return [pscustomobject]@{State='Running';Lines=@();Part='firewall'}
 }
 $data=@(& $ScriptBlock @ArgumentList)
 [pscustomobject]@{State='Completed';Lines=$data}
}
function Wait-Job {param($Job,$Timeout) if($Job.State -eq 'Completed'){$Job}}
function Receive-Job {param($Job) $Job.Lines}
function Remove-Job {param($Job,[switch]$Force) $netstateScheduler.RemovedJobs+=@($Job)}
try {
 $homeDir=Join-Path $root 'home';$null=New-Item -ItemType Directory -Path $homeDir -Force
 [IO.File]::WriteAllText((Join-Path $homeDir 'config.json'), "{`r`n`"lan`": [{`"ovpn`":`"DO-NOT-EXPORT`",`"testHost`":`"10.0.0.1`",`"testPort`":443,`"share`":{`"domains`":[`"example.org`",`"*.example.net`"],`"dnsServers`":[`"10.0.0.2`"]}}],`r`n`"vpn`":{`"enabled`":false}}`r`n")
 $overrides=@{}
 foreach($name in @('Get-NetAdapter','Get-NetIPAddress','Get-NetIPInterface','Get-NetRoute','Get-DnsClientServerAddress','Get-DnsClient','Get-DnsClientNrptRule','Get-DnsClientNrptPolicy','Get-DnsClientGlobalSetting','Get-Service','Get-NetFirewallProfile','Get-NetFirewallRule','Get-WinEvent','Find-NetRoute','ipconfig','route','netsh','ping','curl.exe','Get-ItemProperty')) {$overrides[$name]="'stub'"}
 $overrides['Get-CimInstance']='param($ClassName) if($ClassName -eq "Win32_Process") {[pscustomobject]@{Name="openvpn";ProcessId=123;ExecutablePath="openvpn.exe";CommandLine="openvpn --password abc token=xyz"}} else {[pscustomobject]@{Name="RemoteAgentsNet";State="Running";StartMode="Auto";PathName="service"}}'
 $overrides['Test-NetConnection']='$true';$overrides['Resolve-DnsName']="'resolved'"
 $a=& $script -Label A -Home $homeDir -Out $root -Executors $overrides -PartTimeout 1 -ProbeNames 'probe.example.net'
 foreach($part in @('system','adapters','ip','routes','dns','proxy','vpn-processes','vpn-services','firewall','events','remoteagents','checks','summary')) {Assert (Test-Path (Join-Path $a ($part+'.txt'))) "missing $part"}
 $proc=Get-Content (Join-Path $a 'vpn-processes.txt') -Raw
 Assert ($proc -match '--password <скрыто>' -and $proc -match 'token=<скрыто>' -and $proc -notmatch '\babc\b|xyz') 'redaction failed'
 Assert ((Get-Content (Join-Path $a 'remoteagents.txt') -Raw) -notmatch 'DO-NOT-EXPORT|"ovpn"') 'config leaked'
 Assert (($netstateScheduler.HungParts -join ',') -eq 'firewall') 'firewall hang was not injected'
 Assert ((Get-Content (Join-Path $a 'firewall.txt') -Raw).Trim() -eq 'TIMEOUT: firewall') 'firewall timeout detail missing'
 Assert ((Get-Content (Join-Path $a 'summary.txt') -Raw) -match '(?m)^TIMEOUT: firewall\r?$') 'timeout missing'
 Assert (@($netstateScheduler.RemovedJobs|Where-Object {$_.Part -eq 'firewall' -and $_.State -eq 'Running'}).Count -eq 1) 'timed out firewall job not cleaned up'
 $b=Join-Path $root B;$null=New-Item -ItemType Directory $b
 Copy-Item (Join-Path $a '*.txt') $b
 Add-Content (Join-Path $b 'routes.txt') 'DestinationPrefix=10.42.0.0/16 NextHop=10.0.0.1'
 $diff=& $script -Compare $a,$b -Home $homeDir -Out $root
 $changes=@(Get-Content $diff | Where-Object {$_ -match '^[+-] '})
 Assert ($changes.Count -eq 1 -and $changes[0] -eq '+ DestinationPrefix=10.42.0.0/16 NextHop=10.0.0.1') 'diff contains unrelated changes'
 'OK: collectors, redaction, CRLF config, timeout, exact route diff'
} finally {Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue}
