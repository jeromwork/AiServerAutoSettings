# Windows PowerShell 5.1. Private parent stdin supplies token and selected folder.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'Windows.Paths.ps1')
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Text;
public class BridgeProcess : IDisposable {
    public Process Process;
    public string TaskId;
    public bool Truncated;
    readonly StringBuilder output = new StringBuilder();
    public BridgeProcess(string command, string cwd) : this(command, cwd, null, false) { }
    public BridgeProcess(string command, string cwd, string input, bool script) {
        Process = new Process();
        if(script && command.IndexOfAny(new [] {'"', '\r', '\n'}) >= 0) throw new ArgumentException("Invalid guard path");
        var prefix = "$ProgressPreference='SilentlyContinue';[Console]::InputEncoding=New-Object Text.UTF8Encoding($false);[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false);";
        var source = prefix + (script ? "& '" + command.Replace("'", "''") + "'" : command);
        var arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(source));
        Process.StartInfo = new ProcessStartInfo("powershell.exe", arguments);
        Process.StartInfo.UseShellExecute = false;
        Process.StartInfo.CreateNoWindow = true;
        Process.StartInfo.WorkingDirectory = cwd;
        Process.StartInfo.RedirectStandardOutput = true;
        Process.StartInfo.RedirectStandardError = true;
        Process.StartInfo.RedirectStandardInput = true;
        Process.StartInfo.StandardOutputEncoding = new UTF8Encoding(false);
        Process.StartInfo.StandardErrorEncoding = new UTF8Encoding(false);
        Process.OutputDataReceived += (s,e) => Append(e.Data);
        Process.ErrorDataReceived += (s,e) => Append(e.Data);
        Process.Start();
        Process.BeginOutputReadLine(); Process.BeginErrorReadLine();
        if(input != null) {
            var bytes = new UTF8Encoding(false).GetBytes(input);
            Process.StandardInput.BaseStream.Write(bytes, 0, bytes.Length);
            Process.StandardInput.BaseStream.Flush();
        }
        Process.StandardInput.Close();
    }
    void Append(string value) { if(value == null) return; lock(output) {
        if(value.Length > 16384) { Truncated = true; value = value.Substring(value.Length - 16384); }
        output.AppendLine(value); if(output.Length > 32768) { Truncated = true; output.Remove(0, output.Length - 32768); }
    }}
    public string Read() { lock(output) { return output.ToString(); } }
    public void Stop() {
        if(!Process.HasExited) {
            var info = new ProcessStartInfo("taskkill.exe", "/PID " + Process.Id + " /T /F");
            info.UseShellExecute = false; info.CreateNoWindow = true;
            info.RedirectStandardOutput = true; info.RedirectStandardError = true;
            using(var killer = System.Diagnostics.Process.Start(info)) { killer.WaitForExit(5000); }
            if(!Process.HasExited) Process.Kill();
        }
    }
    public void Dispose() { Stop(); Process.Dispose(); }
}
'@
$config = [Console]::ReadLine() | ConvertFrom-Json
if ($null -eq $config -or $config.token -notmatch '^[a-f0-9]{64}$') { throw 'Invalid private launch configuration.' }
$root = [IO.Path]::GetFullPath([string]$config.workspace).TrimEnd('\')
if (-not [IO.Directory]::Exists($root)) { throw 'Selected workspace does not exist.' }
$secret = [string]$config.token
$allowShell = $config.allow_shell -eq $true
$serverOwned = $config.server_owned -eq $true
$syncGuard = $config.sync_guard
$syncState = 'not_checked'
$device = [string]$config.device
$parentProcess = [Diagnostics.Process]::GetProcessById([int]$config.parent_pid)
$processes = @{}
$quit = $false
$environmentMutex = New-Object Threading.Mutex($false, ('Global\RemoteAgents.Environment.'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
$leaseRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'RemoteAgents\environment'
[void][IO.Directory]::CreateDirectory($leaseRoot)
foreach($node in @($leaseRoot,(Split-Path $leaseRoot -Parent))){if((Get-Item -LiteralPath $node).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked environment state denied.'}}
$leasePath=Join-Path $leaseRoot 'operations.json'
function Update-Environment([string]$Id,[string]$TaskId,[Diagnostics.Process]$Process,[switch]$Remove) {
    try {$acquired=$environmentMutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$acquired=$true}
    if(!$acquired){throw 'Environment coordination timeout.'}
    try {
        $entries=@()
        if(Test-Path -LiteralPath $leasePath){
            if((Get-Item -LiteralPath $leasePath).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked environment state denied.'}
            $record=[IO.File]::ReadAllText($leasePath)|ConvertFrom-Json
            if($record.schema -ne 1){throw 'Invalid environment coordination state.'}
            foreach($entry in $record.operations){
                try {$live=[Diagnostics.Process]::GetProcessById([int]$entry.pid)}catch [ArgumentException]{continue}
                try {if(!$live.HasExited -and $live.StartTime.ToUniversalTime().Ticks -eq [long]$entry.started){$entries+=@($entry)}}finally{$live.Dispose()}
            }
        }
        if(!$Remove -and @($entries|Where-Object{$_.taskId -cne $TaskId}).Count){throw 'Target environment busy in another task. Finish/stop that task before reassigning it.'}
        $entries=@($entries|Where-Object{$_.id -cne $Id})
        if(!$Remove){$entries+=@(@{id=$Id;taskId=$TaskId;pid=$Process.Id;started=$Process.StartTime.ToUniversalTime().Ticks})}
        [IO.File]::WriteAllText($leasePath,(@{schema=1;operations=$entries}|ConvertTo-Json -Depth 5 -Compress),(New-Object Text.UTF8Encoding($false)))
    } finally {$environmentMutex.ReleaseMutex()}
}

function Workspace-Path([string]$relative) {
    if ([string]::IsNullOrEmpty($relative)) { $relative = '.' }
    if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains(':')) { throw 'Only workspace-relative paths are allowed.' }
    $target = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $relative))
    if ($target -ne $root -and -not $target.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Path escapes workspace.' }
    $walk = $target
    while ($walk.Length -ge $root.Length) {
        $part = [IO.Path]::GetFileName($walk)
        if ($part -match '(?i)^(\.env($|\.)|\.ssh$|\.aws$|\.codex$|\.claude$|\.git$|auth\.json$|.*credential.*|.*secret.*|.*token.*|id_(rsa|ed25519|ecdsa)(\..*)?$|.*\.(pem|key|pfx|p12)$)') { throw 'Sensitive path denied.' }
        $walkIO=ConvertTo-RemoteAgentsIOPath $walk
        if ([IO.File]::Exists($walkIO) -or [IO.Directory]::Exists($walkIO)) {
            if (([IO.File]::GetAttributes($walkIO) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse paths are denied.' }
        }
        if ($walk -eq $root) { break }
        $walk = [IO.Path]::GetDirectoryName($walk)
    }
    return $target
}

function Assert-SyncBarrier {
    if (-not $serverOwned) { return }
    $script:syncState = 'denied'
    if (-not $syncGuard -or -not $syncGuard.path -or -not $syncGuard.data_dir -or -not $syncGuard.project_id -or -not $syncGuard.host_id) { throw 'Sync barrier unavailable; execution denied.' }
    $requestId = [Guid]::NewGuid().ToString('N')
    $request = @{ dataDir=[string]$syncGuard.data_dir; projectId=[string]$syncGuard.project_id; hostId=[string]$syncGuard.host_id; replicaPath=$root; requestId=$requestId } | ConvertTo-Json -Compress
    $guard = $null
    $phase = 'hook_start'
    try {
        $guard = New-Object BridgeProcess ([string]$syncGuard.path), $PSScriptRoot, ($request + "`n"), $true
        $phase = 'hook_timeout'
        if (-not $guard.Process.WaitForExit(30000)) { throw 'Sync timeout.' }
        $guard.Process.WaitForExit()
        $raw = $guard.Read()
        $phase = 'hook_output'
        if ($guard.Process.ExitCode -ne 0 -or $guard.Truncated -or $raw.Length -gt 8192) { throw 'Sync hook failed.' }
        $phase = 'hook_json'
        $result = $raw | ConvertFrom-Json
        $phase = 'snapshot_binding'
        if ($result -is [array] -or $result.ready -isnot [bool] -or $result.ready -ne $true -or $result.fresh -isnot [bool] -or $result.fresh -ne $true -or $result.requestId -cne $requestId -or $result.projectId -cne [string]$syncGuard.project_id -or $result.hostId -cne [string]$syncGuard.host_id -or [string]::IsNullOrWhiteSpace([string]$result.snapshotId)) { throw 'Sync hook did not confirm a fresh matching snapshot.' }
        $phase = 'replica_binding'
        $replica = [IO.Path]::GetFullPath([string]$result.replicaPath).TrimEnd('\')
        if (-not $replica.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Sync replica binding mismatch.' }
        $script:syncState = 'ready_at_last_start'
    } catch {
        # Hook output, transport details and exception text never cross MCP.
        $script:syncState = 'denied_' + $phase
        throw 'Fresh project sync barrier rejected execution (offline, stale, conflict, mismatch or hook failure).'
    } finally { if ($guard) { $guard.Dispose() } }
}

function New-TrackedProcess($values) {
    if (-not $allowShell) { throw 'Shell is disabled; reconnect with owner-authorized AllowShell.' }
    if ([string]::IsNullOrWhiteSpace([string]$values.command) -or ([string]$values.command).Length -gt 16384) { throw 'Invalid command length.' }
    if ($processes.Count -ge 8) { throw 'Process limit reached; stop old tracked processes.' }
    $cwd = Workspace-Path ([string]$values.cwd)
    if (-not [IO.Directory]::Exists($cwd)) { throw 'Command directory does not exist.' }
    $taskId=[string]$values.taskId
    if(!$taskId -and !$config.enforce_target){$taskId='legacy-'+$PID}
    if($taskId -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$'){throw 'Explicit taskId required for environment coordination.'}
    $id = [Guid]::NewGuid().ToString('N')
    Update-Environment $id $taskId ([Diagnostics.Process]::GetCurrentProcess())
    try {
        Assert-SyncBarrier
        $item = New-Object BridgeProcess ([string]$values.command), $cwd
        $item.TaskId=$taskId
        Update-Environment $id $taskId $item.Process
    } catch {if($item){$item.Dispose()};Update-Environment $id '' $null -Remove;throw}
    $processes[$id] = $item
    return @{ id = $id; item = $item }
}

function Dispatch($request) {
    if ($request.token -isnot [string] -or $request.token.Length -ne $secret.Length) { throw 'Unauthorized.' }
    $difference = 0
    for ($i = 0; $i -lt $secret.Length; $i++) { $difference = $difference -bor ([int][char]$request.token[$i] -bxor [int][char]$secret[$i]) }
    if ($difference -ne 0) { throw 'Unauthorized.' }
    if($config.enforce_target){
        $binding=$request.binding
        if(!$binding -or $binding.projectId -cne [string]$syncGuard.project_id -or $binding.hostId -cne [string]$syncGuard.host_id -or $binding.deviceLabel -cne $device -or ![string]::Equals([string]$binding.windowsReplica,$root,[StringComparison]::OrdinalIgnoreCase)){throw 'Explicit target binding mismatch; restart MCP and use the device catalog.'}
    }
    $values = $request.args
    switch ([string]$request.op) {
        'status' {
            $capabilities = @{}
            foreach ($name in @('ssh','adb','node','php','git')) {
                $found = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                $capabilities[$name] = @{ available = $null -ne $found; path = $(if ($found) { $found.Source } else { $null }) }
            }
            return @{ ok = $true; device = $device; platform = 'windows'; workspace = $root; shell_enabled = $allowShell; file_mutations_enabled = -not $serverOwned; sync_guard = @{ required=$serverOwned; project_id=[string]$syncGuard.project_id; host_id=[string]$syncGuard.host_id; state=$syncState }; capabilities = $capabilities; active_processes = $processes.Count; notes = 'Capabilities are executable discovery only; ADB devices, VPN routes and remote SSH have not been tested. A sync preflight confirms the snapshot before process start; it does not freeze subsequent server edits.' }
        }
        'list' {
            $target = Workspace-Path ([string]$values.path)
            $entries = @(Get-ChildItem -LiteralPath (ConvertTo-RemoteAgentsIOPath $target) -Force | Select-Object -First 200 | ForEach-Object {
                try { $null = Workspace-Path ([IO.Path]::Combine([string]$values.path, $_.Name)); @{ name = $_.Name; directory = $_.PSIsContainer; length = $(if ($_.PSIsContainer) { 0 } else { $_.Length }) } } catch { }
            })
            return @{ ok = $true; entries = $entries; limit = 200 }
        }
        'read' {
            $target = Workspace-Path ([string]$values.path)
            if ((Get-Item -LiteralPath (ConvertTo-RemoteAgentsIOPath $target)).Length -gt 65536) { throw 'File exceeds 64 KiB.' }
            return @{ ok = $true; content = [IO.File]::ReadAllText((ConvertTo-RemoteAgentsIOPath $target), [Text.Encoding]::UTF8) }
        }
        'write' {
            if ($serverOwned) { throw 'Windows file mutations are disabled for the server-owned replica; edit the VPS workspace.' }
            $target = Workspace-Path ([string]$values.path)
            $content = [string]$values.content
            if ([Text.Encoding]::UTF8.GetByteCount($content) -gt 65536) { throw 'Content exceeds 64 KiB.' }
            [IO.File]::WriteAllText((ConvertTo-RemoteAgentsIOPath $target), $content, (New-Object Text.UTF8Encoding $false))
            return @{ ok = $true; bytes = [Text.Encoding]::UTF8.GetByteCount($content) }
        }
        'command' {
            $timeout = 30
            if ($null -ne $values.timeout_seconds) { $timeout = [int]$values.timeout_seconds }
            if ($timeout -lt 1 -or $timeout -gt 60) { throw 'Timeout must be 1..60 seconds.' }
            $tracked = New-TrackedProcess $values
            try {
                $finished = $tracked.item.Process.WaitForExit($timeout * 1000)
                if (-not $finished) { $tracked.item.Stop() }
                # Flush async line callbacks once the process is known to have ended.
                $tracked.item.Process.WaitForExit()
                return @{ ok = $true; exit_code = $tracked.item.Process.ExitCode; timed_out = -not $finished; output = $tracked.item.Read(); output_limit_chars = 32768 }
            } finally { $tracked.item.Dispose(); $processes.Remove($tracked.id);Update-Environment $tracked.id '' $null -Remove }
        }
        'process_start' {
            $tracked = New-TrackedProcess $values
            return @{ ok = $true; id = $tracked.id; pid = $tracked.item.Process.Id }
        }
        'process_poll' {
            $id = [string]$values.id
            if (-not $processes.ContainsKey($id)) { throw 'Unknown bridge process.' }
            $item = $processes[$id]
            if($config.enforce_target -and $values.taskId -cne $item.TaskId){throw 'Tracked process belongs to another task.'}
            if($item.Process.HasExited){Update-Environment $id '' $null -Remove}
            return @{ ok = $true; running = -not $item.Process.HasExited; exit_code = $(if ($item.Process.HasExited) { $item.Process.ExitCode } else { $null }); output = $item.Read(); output_limit_chars = 32768 }
        }
        'process_stop' {
            $id = [string]$values.id
            if (-not $processes.ContainsKey($id)) { throw 'Unknown bridge process.' }
            if($config.enforce_target -and $values.taskId -cne $processes[$id].TaskId){throw 'Tracked process belongs to another task.'}
            $processes[$id].Dispose(); $processes.Remove($id)
            Update-Environment $id '' $null -Remove
            return @{ ok = $true; stopped = $true }
        }
        'shutdown' { $script:quit = $true; return @{ ok = $true; stopped = $true } }
        default { throw 'Unknown operation.' }
    }
}

$listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
try {
    $null = Workspace-Path '.'
    $listener.Start(4)
    @{ state = 'ready'; port = $listener.LocalEndpoint.Port; device = $device } | ConvertTo-Json -Compress | ForEach-Object { [Console]::WriteLine($_) }
    while (-not $quit) {
        if (-not $listener.Pending()) {
            if ($parentProcess.HasExited) { break }
            Start-Sleep -Milliseconds 50
            continue
        }
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream(); $stream.ReadTimeout = 5000; $stream.WriteTimeout = 5000
            $bytes = New-Object 'Collections.Generic.List[byte]'
            $readDeadline = [DateTime]::UtcNow.AddSeconds(5)
            while ($true) {
                if ([DateTime]::UtcNow -ge $readDeadline) { throw 'Frame read timed out.' }
                $value = $stream.ReadByte()
                if ($value -eq -1) { throw 'Incomplete frame.' }
                if ($value -eq 10) { break }
                if ($bytes.Count -ge 262144) { throw 'Frame too large.' }
                $bytes.Add([byte]$value)
            }
            try { $request = [Text.Encoding]::UTF8.GetString($bytes.ToArray()) | ConvertFrom-Json; $response = Dispatch $request }
            catch { $response = @{ ok = $false; error = 'Request rejected: ' + $_.Exception.Message } }
            $json = $response | ConvertTo-Json -Depth 12 -Compress
            # Token may not be reflected even if an explicitly requested command prints it.
            $json = $json.Replace($secret, '[redacted]')
            $answer = [Text.Encoding]::UTF8.GetBytes($json + "`n")
            if ($answer.Length -gt 262144) { $answer = [Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"Response exceeds limit"}' + "`n") }
            $stream.Write($answer, 0, $answer.Length)
        } catch { } finally { $client.Close() }
    }
} finally {
    $listener.Stop()
    foreach ($id in @($processes.Keys)) { $processes[$id].Dispose();Update-Environment $id '' $null -Remove }
    $environmentMutex.Dispose()
    $secret = $null; $config = $null
}
