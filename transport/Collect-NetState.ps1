[CmdletBinding(DefaultParameterSetName='Snapshot')]
param(
 [Parameter(ParameterSetName='Snapshot')][string]$Label='снимок',
 [Alias('Home')][string]$NetHome=([IO.Path]::Combine([string]$env:LOCALAPPDATA, 'RemoteAgents')),
 [string]$Out=([IO.Path]::Combine([string]$env:USERPROFILE, 'Desktop/RemoteAgents-проверка-сети')),
 [Parameter(Mandatory=$true,ParameterSetName='Compare')][string[]]$Compare,
 [ValidateRange(1,168)][int]$EventHours=2,
 [string[]]$ProbeNames=@(), [string[]]$ProbeUrls=@(),
 # Injection seam: command name -> script text; installed in each in-process runspace.
 [hashtable]$Executors=@{},
 [ValidateRange(1,10)][int]$PartTimeout=10
)
$ErrorActionPreference='Stop'
function Write-Text($Path,$Text) {
 [IO.File]::WriteAllText($Path, (($Text -join "`n") -replace "`r?`n","`r`n"), (New-Object Text.UTF8Encoding($true)))
}
function Normalize($Path) {
 @(Get-Content -LiteralPath $Path | ForEach-Object {
  $v=$_ -replace '\r',''
  $v=$v -replace '\b\d{4}-\d\d-\d\d[T ][\d:.+Z-]+','<время>'
  $v=$v -replace '(?i)(ProcessId|PID|uptime|WorkingSet|bytes|байт|время работы|Timestamp|TimeCreated)\s*[:=]\s*[^;|]*','$1=<переменное>'
  $v.TrimEnd()
 } | Where-Object {$_ -and $_ -notmatch '^(Время снимка|Snapshot directory):'} | Sort-Object)
}
if ($PSCmdlet.ParameterSetName -eq 'Compare') {
 if ($Compare.Count -ne 2) {throw 'Нужны две папки снимков'}
 $a=(Resolve-Path -LiteralPath $Compare[0]).Path; $b=(Resolve-Path -LiteralPath $Compare[1]).Path
 $result=New-Object Collections.Generic.List[string]
 $names=@(@(Get-ChildItem -LiteralPath $a -Filter '*.txt')+@(Get-ChildItem -LiteralPath $b -Filter '*.txt') | Where-Object {$_.Name -notlike 'diff-*'} | Select-Object -ExpandProperty Name -Unique | Sort-Object)
 foreach($n in $names) {
  $left=@();$right=@()
  if(Test-Path -LiteralPath (Join-Path $a $n)) {$left=@(Normalize (Join-Path $a $n))}
  if(Test-Path -LiteralPath (Join-Path $b $n)) {$right=@(Normalize (Join-Path $b $n))}
  $result.Add("=== $n ===")
  foreach($d in @(Compare-Object -ReferenceObject $left -DifferenceObject $right)) {
   $sign='+';if($d.SideIndicator -eq '<=') {$sign='-'}
   $result.Add("$sign $($d.InputObject)")
  }
 }
 $path=Join-Path $b ('diff-от-'+(Split-Path $a -Leaf)+'.txt'); Write-Text $path $result; $path; return
}
if ($Label -match '[<>:"/\\|?*\x00-\x1f]' -or $Label -in @('.','..')) {throw 'Недопустимая метка'}
$directory=Join-Path $Out ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+$Label)
if(Test-Path -LiteralPath $directory) {throw 'Папка снимка уже существует'}
$null=New-Item -ItemType Directory -Path $directory
# Collectors reuse one in-process runspace sequentially. No settings are changed.
$worker={param($Part,$NetHome,$Hours,$Names,$Urls,$Probe)
 $ErrorActionPreference='Stop'
 $pattern='openvpn|wireguard|happ|xray|v2ray|sing-box|clash|nekoray|hiddify|amnezia|outline|wintun|RemoteAgents'
 function Safe($s) {
  $s=[string]$s
  $s=$s -replace '(?i)((?:--(?:password|auth)\b|\b(?:token|key|secret|uuid)\b)\s*(?:[:=]\s*|\s+))(?:"[^"]*"|''[^'']*''|[^\s;,]+)','$1<скрыто>'
  $s -replace '(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{33,}={0,2}(?![A-Za-z0-9+/])','<скрыто>'
 }
 function Read-Config { $p=Join-Path $NetHome 'config.json'; if(Test-Path -LiteralPath $p) {if((Get-Item -LiteralPath $p).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Config is a link'}; Get-Content -LiteralPath $p -Raw | ConvertFrom-Json} }
 function Sanitize-Config($o) {
  if($null -eq $o){return $null}
  if($o -is [string]) {return (Safe $o)}
  if($o -is [System.Collections.IEnumerable] -and $o -isnot [string] -and $o -isnot [System.Collections.IDictionary]) {return ,@($o | ForEach-Object {Sanitize-Config $_})}
  if($o -is [pscustomobject] -or $o -is [System.Collections.IDictionary]) {
   $r=[ordered]@{}; foreach($p in $o.PSObject.Properties) {if($p.Name -notmatch '(?i)ovpn|auth|password|secret|token|key|uuid') {$r[$p.Name]=Sanitize-Config $p.Value}};return $r
  };return $o
 }
 function Show($title,[scriptblock]$action) {
  "--- $title ---"
  try { & $action | Format-List * | Out-String -Width 4096 | ForEach-Object {Safe $_} }
  catch {if($_.Exception -is [UnauthorizedAccessException] -or $_ -match 'access.*denied|отказано|unauthorized') {"нет прав: $title"} else {"не собрано: $title ($($_.Exception.GetType().Name))"}}
 }
 switch($Part) {
 'system' { Show 'system' {
  $admin=$false
  try {$id=[Security.Principal.WindowsIdentity]::GetCurrent();$admin=(New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)} catch {}
  [pscustomobject]@{Windows=[Environment]::OSVersion.VersionString;Computer=$env:COMPUTERNAME;User=[Environment]::UserName;Admin=$admin;Timestamp=(Get-Date -Format o)}
 }}
 'adapters' {Show 'adapters' {Get-NetAdapter -IncludeHidden | Select-Object Name,InterfaceDescription,Status,ifIndex,MacAddress,Virtual,HardwareInterface}}
 'ip' {Show 'addresses' {Get-NetIPAddress};Show 'metrics' {Get-NetIPInterface};Show 'ipconfig' {ipconfig /all}}
 'routes' {Show 'IPv4' {Get-NetRoute -AddressFamily IPv4 | Select-Object DestinationPrefix,NextHop,ifIndex,InterfaceAlias,RouteMetric};Show 'IPv6' {Get-NetRoute -AddressFamily IPv6 | Select-Object DestinationPrefix,NextHop,ifIndex,InterfaceAlias,RouteMetric};Show 'route' {route print}}
 'dns' {
  Show 'servers' {Get-DnsClientServerAddress};Show 'client' {Get-DnsClient};Show 'NRPT rules' {Get-DnsClientNrptRule};Show 'NRPT effective' {Get-DnsClientNrptPolicy -Effective};Show 'global' {Get-DnsClientGlobalSetting}
 }
 'proxy' {Show 'WinHTTP' {netsh winhttp show proxy};Show 'HKCU' {Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' | Select-Object ProxyEnable,ProxyServer,AutoConfigURL,ProxyOverride}}
 'vpn-processes' {Show 'processes' {Get-CimInstance Win32_Process | Where-Object {($_.Name+' '+$_.ExecutablePath) -match $pattern} | Select-Object Name,ProcessId,ExecutablePath,CommandLine}}
 'vpn-services' {Show 'services' {Get-Service | Where-Object {($_.Name+' '+$_.DisplayName) -match $pattern}};Show 'service paths' {Get-CimInstance Win32_Service | Where-Object {($_.Name+' '+$_.PathName) -match $pattern} | Select-Object Name,State,StartMode,PathName}}
 'firewall' {Show 'profiles' {Get-NetFirewallProfile};Show 'rules' {$rules=@(Get-NetFirewallRule);"TotalRules: $($rules.Count)";$rules | Where-Object {($_.DisplayName+' '+$_.Group) -match $pattern} | Select-Object Name,DisplayName,Group,Enabled,Direction,Action,Profile}}
 'events' {Show 'events' {Get-WinEvent -FilterHashtable @{LogName='System';StartTime=(Get-Date).AddHours(-$Hours);ProviderName=@('Wintun','Microsoft-Windows-Tcpip','Microsoft-Windows-DNS-Client','Microsoft-Windows-NetworkProfile','Service Control Manager')} -MaxEvents 300 | Where-Object {$_.ProviderName -ne 'Service Control Manager' -or $_.Message -match $pattern} | Select-Object TimeCreated,ProviderName,Id,LevelDisplayName,Message}}
 'remoteagents' {
  foreach($spec in @('status/*.json','logs/*.log','state/transport-ports.json','state/vpn-plan.json','state/vpn-interface.json')) {
   foreach($f in @(Get-ChildItem -Path (Join-Path $NetHome $spec) -File -ErrorAction SilentlyContinue)) {
    if($f.Name -match 'secret|key|token' -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)) {continue}
    Show $f.Name {if($f.Extension -eq '.log') {Get-Content -LiteralPath $f.FullName -Tail 200} else {Get-Content -LiteralPath $f.FullName -Raw}}
   }
  }
  Show 'state names' {Get-ChildItem -LiteralPath (Join-Path $NetHome 'state') -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name}
  Show 'config lan/vpn' {$c=Read-Config; Sanitize-Config ([pscustomobject]@{lan=$c.lan;vpn=$c.vpn}) | ConvertTo-Json -Depth 50}
 }
 'checks' {
  # Return probe specifications; the coordinator runs them in the same warm runspace.
  $tasks=New-Object Collections.Generic.List[object]
  function Probe($title,$code,$values) {$tasks.Add(@($title,$code,$values))}
  Probe 'internet TCP' 'Test-NetConnection 1.1.1.1 -Port 443 -InformationLevel Quiet' @()
  Probe 'internet DNS' 'Resolve-DnsName example.com' @()
  $c=Read-Config
  foreach($lan in @($c.lan)) {if(!$lan.share){continue};$sh=$lan.share
   $hostName=$lan.testHost;$port=$lan.testPort
   if(!$hostName){$hostName=$sh.testHost;$port=$sh.testPort}
   if(!$hostName){$hostName=$lan.host;$port=$lan.port}
   if(!$hostName -and @($sh.forwards).Count){$hostName=$sh.forwards[0].host;$port=$sh.forwards[0].port}
   if($hostName) {
    Probe "TCP $hostName : $port" 'param($h,$p) Test-NetConnection $h -Port $p -InformationLevel Quiet' @($hostName,$port)
    Probe "ping $hostName" 'param($h) ping -n 2 -w 1000 $h' @($hostName)
    Probe "route $hostName" 'param($h) Find-NetRoute -RemoteIPAddress $h' @($hostName)
   }
   foreach($dns in @($sh.dnsServers)){if($dns){Probe "DNS TCP $dns" 'param($h) Test-NetConnection $h -Port 53 -InformationLevel Quiet' @($dns)}}
   foreach($domain in @($sh.domains)) {
    if(!$domain){continue}
    if($domain.StartsWith('*.')) {foreach($n in $Names){if($n.EndsWith($domain.Substring(1))){Probe "DNS $n" 'param($h) Resolve-DnsName $h' @($n)}}}
    else {Probe "DNS $domain" 'param($h) Resolve-DnsName $h' @($domain)}
   }
  }
  foreach($url in $Urls){Probe "HTTP $(Safe $url)" 'param($u) curl.exe -sS -o NUL -w "%{http_code} %{time_total}" --max-time 5 $u' @($url)}
  $tasks.ToArray()
 }
 'probe' {
  Show $Probe[0] {
   $global:LASTEXITCODE=0
   $values=$Probe[2]
   $r=@(& ([scriptblock]::Create([string]$Probe[1])) @values)
   if($LASTEXITCODE -ne 0){throw 'Probe command failed'}
   if($r.Count -eq 1 -and $r[0] -is [bool]) {if($r[0]){'PASS'}else{'FAIL'}}
   else {'PASS (команда завершена; результат ниже)';$r}
  }
 }
 }
}
$parts=@('system','adapters','ip','routes','dns','proxy','vpn-processes','vpn-services','firewall','events','remoteagents','checks')
$summary=New-Object Collections.Generic.List[string]
$clock=[Diagnostics.Stopwatch]::StartNew()
# Reserve five seconds for writing the final files. All waits share this deadline.
$collectionDeadline=85.0
$pool=$null
$retired=New-Object Collections.Generic.List[object]
function Wait-Until($Async,[double]$Deadline) {
 $milliseconds=[Math]::Max(0,[Math]::Floor(($Deadline-$clock.Elapsed.TotalSeconds)*1000))
 $Async.IsCompleted -or $Async.AsyncWaitHandle.WaitOne([int]$milliseconds)
}
function Close-CollectorPool {
 if($null -ne $script:pool) {
  $old=$script:pool;$script:pool=$null
  # Close/Stop/Dispose may block on a native cmdlet. Never wait synchronously here.
  $item=@{Pool=$old;Closing=$null}
  $retired.Add($item)
  try {$item.Closing=$old.BeginClose($null,$null)} catch {
   # Keep the detached pool alive; a failed close request must not block collection.
  }
 }
}
function Invoke-CollectorPipeline($Code,$Values,[double]$Deadline) {
 $ps=[Management.Automation.PowerShell]::Create()
 $ps.RunspacePool=$script:pool
 $null=$ps.AddScript([string]$Code)
 foreach($value in $Values){$null=$ps.AddArgument($value)}
 $async=$null
 try {
  $async=$ps.BeginInvoke()
  if(!(Wait-Until $async $Deadline)) {
   # Detach BEFORE requesting cancellation: if BeginStop throws, finally must
   # still avoid synchronous Dispose on a pipeline stuck in a native call.
   $item=@{PowerShell=$ps;Invocation=$async;Stopping=$null}
   $retired.Add($item)
   $ps=$null
   try {$item.Stopping=$item.PowerShell.BeginStop($null,$null)} catch {
    # Best effort only; the timeout and the next section must still be reported.
   }
   Close-CollectorPool
   return @{TimedOut=$true;Lines=@()}
  }
  $lines=@($ps.EndInvoke($async))
  return @{TimedOut=$false;Lines=$lines}
 } finally {if($null -ne $ps){$ps.Dispose()}}
}
function Open-CollectorPool([double]$Deadline) {
 if($null -ne $script:pool){return $true}
 if($clock.Elapsed.TotalSeconds -ge $Deadline){return $false}
 $state=[Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
 foreach($key in $Executors.Keys) {
  $entry=New-Object Management.Automation.Runspaces.SessionStateFunctionEntry($key,[string]$Executors[$key])
  $state.Commands.Add($entry)
 }
 $script:pool=[Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1,1,$state,$Host)
 $opening=$script:pool.BeginOpen($null,$null)
 if(!(Wait-Until $opening $Deadline)){Close-CollectorPool;return $false}
 $script:pool.EndOpen($opening)
 # Import once before timing individual sections, not once per command/job.
 # A timed-out runspace is replaced; its replacement must also be initialized.
 if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -or $Executors.ContainsKey('Import-Module')) {
  $init=Invoke-CollectorPipeline {
   Import-Module NetAdapter,NetTCPIP,DnsClient,NetSecurity,CimCmdlets,Microsoft.PowerShell.Diagnostics -ErrorAction SilentlyContinue
  } @() $Deadline
  return (!$init.TimedOut)
 }
 return $true
}
try {
 $ready=Open-CollectorPool $collectionDeadline
 foreach($part in $parts) {
  $lines=@();$timedOut=$true
  if($ready -and $clock.Elapsed.TotalSeconds -lt $collectionDeadline) {
   $deadline=[Math]::Min($clock.Elapsed.TotalSeconds+$PartTimeout,$collectionDeadline)
   try {
    $result=Invoke-CollectorPipeline $worker @($part,$NetHome,$EventHours,$ProbeNames,$ProbeUrls,$null) $deadline
    $timedOut=$result.TimedOut
    if(!$timedOut -and $part -eq 'checks') {
     foreach($probe in $result.Lines) {
      if($clock.Elapsed.TotalSeconds -ge $deadline){$timedOut=$true;break}
      $probeDeadline=[Math]::Min($clock.Elapsed.TotalSeconds+5,$deadline)
      $resultProbe=Invoke-CollectorPipeline $worker @('probe',$NetHome,$EventHours,$ProbeNames,$ProbeUrls,$probe) $probeDeadline
      if($resultProbe.TimedOut) {
       $lines+=('TIMEOUT: '+$probe[0])
       # Only a probe hit its own deadline: continue with a fresh runspace.
       if($clock.Elapsed.TotalSeconds -ge $deadline -or !(Open-CollectorPool $deadline)){$timedOut=$true;break}
      } else {$lines+=@($resultProbe.Lines | ForEach-Object {[string]$_})}
     }
    } elseif(!$timedOut) {$lines=@($result.Lines | ForEach-Object {[string]$_})}
   } catch {$timedOut=$false;$lines=@('не собрано: '+$part+' ('+$_.Exception.GetType().Name+')')}
  }
  if($timedOut) {$lines=@('TIMEOUT: '+$part);$summary.Add('TIMEOUT: '+$part)}
  else {
   $summary.Add($part+': собрано')
   foreach($line in $lines){foreach($entry in ($line -split "`r?`n")){if($entry -match 'нет прав:|не собрано:|TIMEOUT|PASS|FAIL'){$summary.Add($part+': '+$entry)}}}
  }
  Write-Text (Join-Path $directory ($part+'.txt')) $lines
  # Replacement startup is outside the next section's individual time budget.
  if($part -ne 'checks'){$ready=Open-CollectorPool $collectionDeadline}
 }
} finally {
 Close-CollectorPool
 # Give asynchronous cleanup a small shared grace period, within the 90s budget.
 $cleanupDeadline=[Math]::Min($clock.Elapsed.TotalSeconds+0.1,89.0)
 foreach($item in $retired) {
  if($item.PowerShell -and $item.Invocation.IsCompleted -and $item.Stopping -and $item.Stopping.IsCompleted) {
   try {$item.PowerShell.EndStop($item.Stopping);$null=$item.PowerShell.EndInvoke($item.Invocation)} catch {}
   $item.PowerShell.Dispose()
  }
  if($item.Pool -and $item.Closing -and (Wait-Until $item.Closing $cleanupDeadline)) {
   $item.Pool.EndClose($item.Closing);$item.Pool.Dispose()
  }
 }
}
Write-Text (Join-Path $directory 'summary.txt') $summary
$directory
