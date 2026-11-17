$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('netstate-'+[guid]::NewGuid().ToString('N'))
$script=Join-Path $PSScriptRoot 'Collect-NetState.ps1'
function Assert($ok,$message){if(!$ok){throw $message}}
# Exercise real BeginInvoke/WaitOne/BeginStop on Linux: only OS commands are stubbed.
try {
 $homeDir=Join-Path $root 'home';$null=New-Item -ItemType Directory -Path $homeDir -Force
 [IO.File]::WriteAllText((Join-Path $homeDir 'config.json'), "{`r`n`"lan`": [{`"ovpn`":`"DO-NOT-EXPORT`",`"testHost`":`"10.0.0.1`",`"testPort`":443,`"share`":{`"domains`":[`"example.org`",`"*.example.net`"],`"dnsServers`":[`"10.0.0.2`"]}}],`r`n`"vpn`":{`"enabled`":false}}`r`n")
 $overrides=@{}
 foreach($name in @('Get-NetAdapter','Get-NetIPAddress','Get-NetIPInterface','Get-NetRoute','Get-DnsClientServerAddress','Get-DnsClient','Get-DnsClientNrptRule','Get-DnsClientNrptPolicy','Get-DnsClientGlobalSetting','Get-Service','Get-NetFirewallProfile','Get-NetFirewallRule','Get-WinEvent','Find-NetRoute','ipconfig','route','netsh','ping','curl.exe','Get-ItemProperty')) {$overrides[$name]="'stub'"}
 $overrides['Get-CimInstance']='param($ClassName) if($ClassName -eq "Win32_Process") {[pscustomobject]@{Name="openvpn";ProcessId=123;ExecutablePath="openvpn.exe";CommandLine="openvpn --password abc token=xyz"}} else {[pscustomobject]@{Name="RemoteAgentsNet";State="Running";StartMode="Auto";PathName="service"}}'
 $overrides['Test-NetConnection']='$true';$overrides['Resolve-DnsName']="'resolved'"
 # Initialization exceeds PartTimeout, but must not consume a section's budget.
 $overrides['Import-Module']='param($Name) $global:imports++; Start-Sleep -Milliseconds 1200'
 $overrides['Get-NetAdapter']='[pscustomobject]@{Name="PID=$PID;Runspace=$([runspace]::DefaultRunspace.InstanceId);Imports=$global:imports"}'
 $overrides['Get-NetIPAddress']='[pscustomobject]@{Address="PID=$PID;Runspace=$([runspace]::DefaultRunspace.InstanceId);Imports=$global:imports"}'
 # Simulate a native call which ignores PowerShell cancellation. Cleanup must not wait.
 $overrides['Get-NetFirewallRule']='[Threading.Thread]::Sleep(20000); "LATE FIREWALL RESULT"'
 $overrides['Get-WinEvent']='[pscustomobject]@{Message="after firewall; PID=$PID; Imports=$global:imports"}'
 $overrides['Test-NetConnection']='param($ComputerName,$Port,$InformationLevel) if($Port -eq 53){$false}else{$true}'
 $overrides['Resolve-DnsName']='param($Name) if($Name -eq "example.org"){throw "probe error"}; "resolved $Name; PID=$PID; Imports=$global:imports"'
 $timer=[Diagnostics.Stopwatch]::StartNew()
 $a=& $script -Label A -Home $homeDir -Out $root -Executors $overrides -PartTimeout 1 -ProbeNames 'probe.example.net' -ProbeUrls 'https://example.org/health'
 Assert ($timer.Elapsed.TotalSeconds -lt 15) 'timed out runspace blocked collection/cleanup'
 $adapter=Get-Content (Join-Path $a 'adapters.txt') -Raw
 $ip=Get-Content (Join-Path $a 'ip.txt') -Raw
 Assert ($adapter -match "PID=$PID;Runspace=([^;]+);Imports=1") 'adapter did not run in-process after one warmup'
 $runspaceId=$Matches[1]
 Assert ($ip -match [regex]::Escape("PID=$PID;Runspace=$runspaceId;Imports=1")) 'sections did not reuse initialized runspace'
 Assert ((Get-Content (Join-Path $a 'events.txt') -Raw) -match "after firewall; PID=$PID; Imports=1") 'collection did not recover after timeout'
 $checks=Get-Content (Join-Path $a 'checks.txt') -Raw
 foreach($title in @('internet TCP','internet DNS','TCP 10.0.0.1 : 443','ping 10.0.0.1','route 10.0.0.1','DNS TCP 10.0.0.2','DNS example.org','DNS probe.example.net','HTTP https://example.org/health')) {
  Assert ($checks.Contains("--- $title ---")) "probe missing: $title"
 }
 Assert ($checks -match 'PASS' -and $checks -match 'FAIL' -and $checks -match 'не собрано: DNS example.org') 'probe success/failure/error handling missing'
 Assert ($checks -match "resolved probe.example.net; PID=$PID; Imports=1") 'probe parameters or warm runspace lost'
 Assert ($checks -notmatch 'TIMEOUT:') 'fast probes timed out'
 Assert ($ip -match 'stub' -and (Get-Content (Join-Path $a 'routes.txt') -Raw) -match 'stub') 'native command overrides lost'
 # Preserve Windows PS 5.1-compatible UTF-8 BOM and CRLF output.
 $bytes=[IO.File]::ReadAllBytes((Join-Path $a 'summary.txt'))
 Assert ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'UTF-8 BOM missing'
 Assert ([Text.Encoding]::UTF8.GetString($bytes) -notmatch '(?<!\r)\n') 'output is not CRLF'
 foreach($part in @('system','adapters','ip','routes','dns','proxy','vpn-processes','vpn-services','firewall','events','remoteagents','checks','summary')) {Assert (Test-Path (Join-Path $a ($part+'.txt'))) "missing $part"}
 $proc=Get-Content (Join-Path $a 'vpn-processes.txt') -Raw
 Assert ($proc -match '--password <скрыто>' -and $proc -match 'token=<скрыто>' -and $proc -notmatch '\babc\b|xyz') 'redaction failed'
 Assert ((Get-Content (Join-Path $a 'remoteagents.txt') -Raw) -notmatch 'DO-NOT-EXPORT|"ovpn"') 'config leaked'
 Assert ((Get-Content (Join-Path $a 'firewall.txt') -Raw).Trim() -eq 'TIMEOUT: firewall') 'firewall timeout detail missing'
 Assert ((Get-Content (Join-Path $a 'summary.txt') -Raw) -match '(?m)^TIMEOUT: firewall\r?$') 'timeout missing'
 Assert ((Get-Content (Join-Path $a 'firewall.txt') -Raw) -notmatch 'LATE FIREWALL RESULT') 'timed out pipeline leaked output'
 $b=Join-Path $root B;$null=New-Item -ItemType Directory $b
 Copy-Item (Join-Path $a '*.txt') $b
 Add-Content (Join-Path $b 'routes.txt') 'DestinationPrefix=10.42.0.0/16 NextHop=10.0.0.1'
 $diff=& $script -Compare $a,$b -Home $homeDir -Out $root
 $changes=@(Get-Content $diff | Where-Object {$_ -match '^[+-] '})
 Assert ($changes.Count -eq 1 -and $changes[0] -eq '+ DestinationPrefix=10.42.0.0/16 NextHop=10.0.0.1') 'diff contains unrelated changes'
 # No Windows commands, child PowerShell processes, or mocked scheduler in these runs.
 $probeOverrides=$overrides.Clone()
 $probeOverrides.Remove('Import-Module')
 $probeOverrides['Get-NetFirewallRule']="'stub'"
 $probeOverrides['Test-NetConnection']='param($ComputerName,$Port,$InformationLevel) if($Port -eq 443 -and $ComputerName -eq "1.1.1.1"){Start-Sleep -Seconds 30};$true'
 $timer.Restart()
 $probeSnapshot=& $script -Label probe-timeout -Home $homeDir -Out $root -Executors $probeOverrides
 Assert ($timer.Elapsed.TotalSeconds -lt 15) 'probe timeout blocked next probe'
 $probeText=Get-Content (Join-Path $probeSnapshot 'checks.txt') -Raw
 Assert ($probeText -match '(?m)^TIMEOUT: internet TCP\r?$' -and $probeText -match 'resolved probe.example.net|resolved example.com') 'probe deadline or continuation failed'
 Assert ($probeText -notmatch 'TIMEOUT: checks') 'probe timeout discarded the checks section'
 # Accelerate only the overall deadline literal; use the real coordinator/waits.
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile($script,[ref]$tokens,[ref]$errors)
 Assert ($errors.Count -eq 0) 'collector syntax errors'
 $jobs=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -match '^(Start|Wait|Receive|Remove)-Job$'},$true))
 Assert ($jobs.Count -eq 0) 'process job scheduler remains'
 $deadline=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$collectionDeadline'},$true))
 Assert ($deadline.Count -eq 1 -and $deadline[0].Right.Extent.Text -eq '85.0') 'overall collection budget changed'
 $source=[IO.File]::ReadAllText($script)
 $extent=$deadline[0].Right.Extent
 $shortScript=[scriptblock]::Create($source.Remove($extent.StartOffset,$extent.EndOffset-$extent.StartOffset).Insert($extent.StartOffset,'1.5'))
 $budgetOverrides=$probeOverrides.Clone()
 $budgetOverrides['Get-NetAdapter']='Start-Sleep -Seconds 30; "late adapter"'
 $budgetOverrides['Get-NetIPAddress']='throw "MUST NOT RUN AFTER DEADLINE"'
 $timer.Restart()
 $budgetSnapshot=& $shortScript -Label total-timeout -Home $homeDir -Out $root -Executors $budgetOverrides
 Assert ($timer.Elapsed.TotalSeconds -lt 6) 'overall deadline exceeded'
 foreach($part in @('adapters','ip','routes','dns','proxy','vpn-processes','vpn-services','firewall','events','remoteagents','checks')) {
  Assert ((Get-Content (Join-Path $budgetSnapshot ($part+'.txt')) -Raw).Trim() -eq "TIMEOUT: $part") "overall deadline missing: $part"
 }
 'OK: real runspaces, module warmup/reuse, same PID, recovery, probe/overall deadlines, redaction, CRLF, exact diff'
} finally {Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue}
