[CmdletBinding(DefaultParameterSetName='Snapshot')]
param(
 [Parameter(ParameterSetName='Snapshot')][string]$Label='снимок',
 [Alias('Home')][string]$NetHome=([IO.Path]::Combine([string]$env:LOCALAPPDATA, 'RemoteAgents')),
 [string]$Out=([IO.Path]::Combine([string]$env:USERPROFILE, 'Desktop/RemoteAgents-проверка-сети')),
 [Parameter(Mandatory=$true,ParameterSetName='Compare')][string[]]$Compare,
 [ValidateRange(1,168)][int]$EventHours=2,
 [string[]]$ProbeNames=@(), [string[]]$ProbeUrls=@(),
 # Injection seam: command name -> script text; inherited by every isolated job.
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
# All collectors run concurrently. No network/system setting commands are used.
$worker={param($Part,$NetHome,$Hours,$Names,$Urls,$Overrides)
 $ErrorActionPreference='Stop'
 foreach($key in $Overrides.Keys) {Set-Item -Path ('Function:'+ $key) -Value ([scriptblock]::Create([string]$Overrides[$key]))}
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
  # Each probe has its own isolated 5-second deadline; outer collector is capped at 10s.
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
  $jobs=@();try {
   foreach($t in $tasks) {
    $j=Start-Job -ScriptBlock {param($code,$vals,$ov)
     $ErrorActionPreference='Stop';foreach($k in $ov.Keys){Set-Item ('Function:'+$k) ([scriptblock]::Create([string]$ov[$k]))}
     $global:LASTEXITCODE=0; & ([scriptblock]::Create($code)) @vals; if($LASTEXITCODE -ne 0){throw 'Probe command failed'}
    } -ArgumentList $t[1],$t[2],$Overrides
    $jobs+=@{Job=$j;Title=$t[0];Started=[DateTime]::UtcNow}
   }
   foreach($t in $jobs) {
    $remaining=[Math]::Max(0,5-([DateTime]::UtcNow-$t.Started).TotalSeconds)
    if($t.Job.State -eq 'Completed' -or ($remaining -gt 0 -and (Wait-Job $t.Job -Timeout ([Math]::Ceiling($remaining))))) {
     Show $t.Title {$r=@(Receive-Job $t.Job -ErrorAction Stop);if($r.Count -eq 1 -and $r[0] -is [bool]) {if($r[0]){'PASS'}else{'FAIL'}}else{'PASS (команда завершена; результат ниже)';$r}}
    } else {"TIMEOUT: $($t.Title)"}
   }
  } finally {foreach($t in $jobs){Remove-Job $t.Job -Force -ErrorAction SilentlyContinue}}
 }
 }
}
$parts=@('system','adapters','ip','routes','dns','proxy','vpn-processes','vpn-services','firewall','events','remoteagents','checks')
$jobs=@();$summary=New-Object Collections.Generic.List[string];$clock=[Diagnostics.Stopwatch]::StartNew()
try {
 foreach($part in $parts) {
  $job=Start-Job -ScriptBlock $worker -ArgumentList $part,$NetHome,$EventHours,$ProbeNames,$ProbeUrls,$Executors
  $jobs+=@{Part=$part;Job=$job;Started=$clock.Elapsed.TotalSeconds}
 }
 foreach($item in $jobs) {
  $remaining=[Math]::Min($PartTimeout-($clock.Elapsed.TotalSeconds-$item.Started),85-$clock.Elapsed.TotalSeconds)
  $lines=@()
  if($item.Job.State -eq 'Completed' -or ($remaining -gt 0 -and (Wait-Job $item.Job -Timeout ([Math]::Ceiling($remaining))))) {
   try {$lines=@(Receive-Job $item.Job -ErrorAction Stop | ForEach-Object {[string]$_})}catch{$lines=@('не собрано: '+$item.Part+' ('+$_.Exception.GetType().Name+')')}
   $summary.Add($item.Part+': собрано')
   foreach($line in $lines){foreach($entry in ($line -split "`r?`n")){if($entry -match 'нет прав:|не собрано:|TIMEOUT|PASS|FAIL'){$summary.Add($item.Part+': '+$entry)}}}
  } else {$lines=@('TIMEOUT: '+$item.Part);$summary.Add('TIMEOUT: '+$item.Part)}
  Write-Text (Join-Path $directory ($item.Part+'.txt')) $lines
 }
} finally {foreach($item in $jobs){Remove-Job $item.Job -Force -ErrorAction SilentlyContinue}}
Write-Text (Join-Path $directory 'summary.txt') $summary
$directory
