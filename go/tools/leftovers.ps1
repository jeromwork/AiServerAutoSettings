[CmdletBinding()]
param(
    [Parameter(Position=0, Mandatory=$true)][string]$Mode,
    [Parameter(Position=1, Mandatory=$true)][string]$Arg1,
    [Parameter(Position=2, Mandatory=$true)][string]$Arg2
); $ErrorActionPreference = 'Stop'; function Show-Usage { [Console]::Error.WriteLine("usage: leftovers.ps1 snap <home> <out_file>"); [Console]::Error.WriteLine("       leftovers.ps1 diff <file_a> <file_b>"); exit 2 }; if ($Mode -eq "diff") {
    if (-not (Test-Path -LiteralPath $Arg1 -PathType Leaf) -or -not (Test-Path -LiteralPath $Arg2 -PathType Leaf)) { [Console]::Error.WriteLine("diff: both files must exist"); exit 2 }
    if ((Get-Content -LiteralPath $Arg1 -Raw) -eq (Get-Content -LiteralPath $Arg2 -Raw)) { exit 0 }; $diff = Compare-Object -ReferenceObject (Get-Content -LiteralPath $Arg1) -DifferenceObject (Get-Content -LiteralPath $Arg2)
    $newPorts = $diff | Where-Object { $_.SideIndicator -eq '=>' -and $_.InputObject -match 'listen:\s*127\.0\.0\.1' }; if ($newPorts) { [Console]::Out.WriteLine("=== New listening ports on 127.0.0.1 ===")
        $newPorts | ForEach-Object { [Console]::Out.WriteLine("+$($_.InputObject)") }; [Console]::Out.WriteLine("========================================") }; $diff | ForEach-Object {
        $prefix = if ($_.SideIndicator -eq '=>') { "+ " } else { "- " }; [Console]::Out.WriteLine("$prefix$($_.InputObject)") }; exit 1 }; if ($Mode -ne "snap") { Show-Usage }; if (-not (Test-Path -LiteralPath $Arg1 -PathType Container)) {
    [Console]::Error.WriteLine("snap: home directory not found: $Arg1"); exit 2 }; $instanceHome = (Resolve-Path -LiteralPath $Arg1).Path.TrimEnd('\', '/'); $inst = ""; $instFile = Join-Path $instanceHome "state\instance"
if (Test-Path -LiteralPath $instFile -PathType Leaf) { $inst = (Get-Content -LiteralPath $instFile -Raw).Trim() }; if (-not $inst) { $tracesFile = Join-Path $instanceHome "state\traces.jsonl"
    if (Test-Path -LiteralPath $tracesFile -PathType Leaf) { $first = Get-Content -LiteralPath $tracesFile -TotalCount 10 | Where-Object { $_ -match '"instance"\s*:\s*"([^"]+)"' } | Select-Object -First 1
        if ($first -and $first -match '"instance"\s*:\s*"([^"]+)"') { $inst = $Matches[1] } } }; $inst8 = if ($inst.Length -ge 8) { $inst.Substring(0, 8) } else { $inst }; $traces = @()
$tracesFile = Join-Path $instanceHome 'state\traces.jsonl'; if (Test-Path -LiteralPath $tracesFile) { foreach ($line in (Get-Content -LiteralPath $tracesFile)) {
        try { $traces += ConvertFrom-Json -InputObject $line -ErrorAction Stop } catch { continue } } }; if ($inst -and $inst -notmatch '^[0-9a-fA-F]{32}$') { throw 'ERROR unsupported: invalid instance' }
$tempFile = [System.IO.Path]::GetTempFileName(); try { $lines = [System.Collections.Generic.List[string]]::new(); $lines.Add("[firewall]"); & { try {
            $fw = Get-NetFirewallRule -ErrorAction Stop | Where-Object { ($inst8 -and ($_.Name -like "ra3-$inst8-*" -or $_.DisplayName -like "ra3-$inst8-*")) }; foreach ($r in ($fw | Sort-Object Name)) { $lines.Add("firewall: $($r.Name)") }
        } catch { if ($_.Exception.Message -match "Access is denied|permission") { [Console]::Out.WriteLine("ERROR permission"); [Console]::Error.WriteLine("ERROR permission: $($_.Exception.Message)"); exit 1 }
            [Console]::Out.WriteLine("ERROR unsupported"); [Console]::Error.WriteLine("ERROR unsupported: Get-NetFirewallRule"); exit 1 } }; $lines.Add("[hosts]")
    $hostsPath = Join-Path $(if ($env:SystemRoot) { $env:SystemRoot } else { "C:\Windows" }) "System32\drivers\etc\hosts"; if (Test-Path -LiteralPath $hostsPath -PathType Leaf) { try {
            $hText = Get-Content -LiteralPath $hostsPath -Raw -ErrorAction Stop; $active = $false; foreach ($line in ($hText -split "`r?`n")) {
                if ($line -match '^\s*#\s*ra3-([^\s]+)\s+begin\s*$') { $active = $inst8 -and $Matches[1] -eq $inst8 }; if ($active) { $lines.Add("hosts: $($line.Trim())") }
                if ($line -match '^\s*#\s*ra3-[^\s]+\s+end\s*$') { $active = $false } } } catch { [Console]::Out.WriteLine("ERROR permission"); [Console]::Error.WriteLine("ERROR permission: hosts"); exit 1 } }; $lines.Add("[interfaces]")
    try { $adapters = Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { ($inst8 -and $_.Name -like "ra3-$inst8*") }; foreach ($a in ($adapters | Sort-Object Name)) { $lines.Add("interface: $($a.Name)") } } catch { throw }
    $procIds = [System.Collections.Generic.HashSet[int]]::new(); $pList = [System.Collections.Generic.List[string]]::new(); try { foreach ($p in (Get-CimInstance Win32_Process -ErrorAction Stop)) {
            $tracedProcess = @($traces | Where-Object { $_.kind -eq 'process' -and $_.instance -eq $inst -and
                $_.data.pid -eq [string]$p.ProcessId -and $_.data.exe -eq $p.ExecutablePath -and
                ([datetimeoffset]$_.data.start).UtcDateTime -eq $p.CreationDate.ToUniversalTime() }).Count -gt 0
            if ($p.ExecutablePath -and ($tracedProcess -or $p.ExecutablePath.StartsWith(($instanceHome + [IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase))) { [void]$procIds.Add([int]$p.ProcessId)
                $rel = $p.ExecutablePath; if (-not $tracedProcess) { $rel = $p.ExecutablePath.Substring($instanceHome.Length).TrimStart('\', '/') }; $pList.Add("process: exe=$rel") } } } catch { throw }; $lines.Add("[listeners]")
    if ($procIds.Count -gt 0) { try { $conns = Get-NetTCPConnection -ErrorAction Stop | Where-Object { $_.State -eq 'Listen' -and $procIds.Contains([int]$_.OwningProcess) }
            foreach ($c in ($conns | Sort-Object LocalPort)) { $lines.Add("listen: $($c.LocalAddress):$($c.LocalPort)") } } catch { throw } }
    $udp = @(Get-NetUDPEndpoint -ErrorAction Stop | Where-Object { $procIds.Contains([int]$_.OwningProcess) }); foreach ($c in $udp) { $lines.Add("listen-udp: $($c.LocalAddress):$($c.LocalPort)") }; $lines.Add('[routes]')
    $indexes = @($adapters | ForEach-Object { $_.ifIndex }); foreach ($r in (Get-NetRoute -ErrorAction Stop | Where-Object { $_.InterfaceIndex -in $indexes })) {
        $lines.Add("route: $($r.DestinationPrefix) $($r.InterfaceAlias) $($r.NextHop) $($r.RouteMetric)") }; foreach ($d in (Get-DnsClientServerAddress -ErrorAction Stop | Where-Object { $_.InterfaceIndex -in $indexes })) {
        $lines.Add("dns: $($d.InterfaceAlias) $($d.AddressFamily) $($d.ServerAddresses -join ',')") }; $lines.Add("[nrpt]"); try { $nrpt = Get-DnsClientNrptRule -ErrorAction Stop | Where-Object { ($inst8 -and $_.Comment -like "ra3-$inst8*")
        }; foreach ($n in ($nrpt | Sort-Object Name)) { $lines.Add("nrpt: $($n.Comment) $($n.Namespace) $($n.NameServers -join ',')") } } catch { throw }; $lines.Add("[processes]"); $pList.Sort(); foreach ($p in $pList) { $lines.Add($p) }
    $lines.Add("[proxy]"); $proxyTraces = @($traces | Where-Object { $_.kind -eq 'proxy' -and $_.instance -eq $inst }); if ($proxyTraces.Count) {
        $proxy = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        foreach ($key in @('ProxyEnable', 'ProxyServer', 'AutoConfigURL')) { $lines.Add("proxy: $key=$($proxy.$key)") } }; $autostart = @($traces | Where-Object { $_.kind -eq 'autostart' -and $_.instance -eq $inst })
    $tasks = Get-ScheduledTask -ErrorAction Stop | Where-Object { $candidate = $_; ($inst8 -and ($_.TaskName -like "RemoteAgents3-$inst8*" -or $_.TaskName -like "ra3-$inst8*")) -or
        @($autostart | Where-Object { $d = @{}; foreach ($map in @($_.data, $_.set)) { if ($map) { foreach ($key in $map.PSObject.Properties) { $d[$key.Name] = $key.Value } } }
            ($d.task -and ($d.task -eq $candidate.TaskName -or $d.task -eq ($candidate.TaskPath + $candidate.TaskName))) -or
            ($d.path -and $d.path -eq ($candidate.TaskPath + $candidate.TaskName)) }).Count -gt 0 }; foreach ($t in $tasks) { $lines.Add("task: $($t.TaskPath)$($t.TaskName)") }; $tmpDir = Join-Path $instanceHome 'tmp'; $roots = @($tmpDir)
    foreach ($trace in ($traces | Where-Object { $_.kind -eq 'tmp' -and $_.instance -eq $inst })) { $path = if ($trace.set.path) { $trace.set.path } else { $trace.data.path }; if ($path) { $roots += $path } }
    foreach ($root in ($roots | Sort-Object -Unique)) { if (-not (Test-Path -LiteralPath $root)) { continue }; $item = Get-Item -LiteralPath $root -Force -ErrorAction Stop; if ($root -ne $tmpDir) { $lines.Add("tmp: $($item.FullName)") }
        if ($item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { foreach ($tf in (Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop)) { $lines.Add("tmp: $($tf.FullName)") } } }
    [System.IO.File]::WriteAllLines($tempFile, [string[]]@($lines | Sort-Object -Unique), [System.Text.Encoding]::UTF8); Move-Item -LiteralPath $tempFile -Destination $Arg2 -Force } catch {
    $kind = if ($_.Exception -is [UnauthorizedAccessException] -or $_.Exception.Message -match 'denied|permission|access') { 'permission' } else { 'unsupported' }; [Console]::Error.WriteLine("ERROR ${kind}: $($_.Exception.Message)"); exit 1
} finally { if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue } }; exit 0
