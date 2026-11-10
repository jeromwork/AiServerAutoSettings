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
$controlOnly = $config.PSObject.Properties['control_only'] -and $config.control_only -eq $true
$syncGuard = if ($config.PSObject.Properties['sync_guard']) { $config.sync_guard } else { @{path='';data_dir='';project_id='';host_id=''} }
if ($controlOnly) { $syncGuard=@{path='';data_dir='';project_id=[string]$config.project_id;host_id=[string]$config.host_id} }
$syncState = 'not_checked'
$device = [string]$config.device
$parentProcess = [Diagnostics.Process]::GetProcessById([int]$config.parent_pid)
$processes = @{}
$completed = @{}
$pendingCommands = @{}
$quit = $false
$environmentMutex = New-Object Threading.Mutex($false, ('Global\RemoteAgents.Environment.'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
$leaseRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'RemoteAgents\environment'
[void][IO.Directory]::CreateDirectory($leaseRoot)
foreach($node in @($leaseRoot,(Split-Path $leaseRoot -Parent))){if((Get-Item -LiteralPath $node).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked environment state denied.'}}
$leasePath=Join-Path $leaseRoot 'operations.json'
# Schema 1 is retained for rolling upgrades. Missing exclusive means legacy exclusive.
function Update-Environment([string]$Id,[string]$TaskId,[Diagnostics.Process]$Process,[switch]$Remove,[bool]$Exclusive=$false,[string]$Operation='process_start') {
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
        $previous=@($entries|Where-Object{$_.id -ceq $Id})
        $entries=@($entries|Where-Object{$_.id -cne $Id})
        if(!$Remove){
            $blockers=@($entries|Where-Object{
                $_.taskId -cne $TaskId -and ($Exclusive -or !$_.PSObject.Properties['exclusive'] -or $_.exclusive -eq $true)
            })
            if($blockers.Count){
                $owner=$blockers[0]
                # Only validated metadata crosses MCP; never reflect a command or arbitrary state text.
                $ownerTask=if([string]$owner.taskId -cmatch '^[a-z0-9][a-z0-9_-]{0,63}$'){[string]$owner.taskId}else{'unknown'}
                $kind=if($owner.PSObject.Properties['operation'] -and $owner.operation -in @('command','process_start')){[string]$owner.operation}else{'legacy'}
                $since=if($owner.PSObject.Properties['began']){([DateTime]::new([long]$owner.began,[DateTimeKind]::Utc)).ToString('o')}else{([DateTime]::new([long]$owner.started,[DateTimeKind]::Utc)).ToString('o')}
                throw "Target environment busy: taskId=$ownerTask operation=$kind started=$since"
            }
            if(@($entries|Where-Object{$_.taskId -ceq $TaskId}).Count -ge 8){throw 'Live process limit reached for taskId (8).'}
            if($entries.Count -ge 64){throw 'Global live process limit reached (64).'}
            $began=if($previous.Count -and $previous[0].PSObject.Properties['began']){[long]$previous[0].began}else{[DateTime]::UtcNow.Ticks}
            $entries+=@(@{id=$Id;taskId=$TaskId;pid=$Process.Id;started=$Process.StartTime.ToUniversalTime().Ticks;began=$began;operation=$Operation;exclusive=$Exclusive})
        }
        [IO.File]::WriteAllText($leasePath,(@{schema=1;operations=$entries}|ConvertTo-Json -Depth 5 -Compress),(New-Object Text.UTF8Encoding($false)))
    } finally {$environmentMutex.ReleaseMutex()}
}

function Process-Result($item) {
    $running=-not $item.Process.HasExited
    if(!$running){$item.Process.WaitForExit()} # Flush async output callbacks.
    return @{ok=$true;running=$running;exit_code=$(if(!$running){$item.Process.ExitCode}else{$null});output=$item.Read();output_limit_chars=32768}
}

function Clear-FinishedProcesses {
    foreach($id in @($processes.Keys)){
        if(!$pendingCommands.ContainsKey($id) -and $processes[$id].Process.HasExited){
            $item=$processes[$id]
            $completed[$id]=@{TaskId=$item.TaskId;Finished=[DateTime]::UtcNow;Result=(Process-Result $item)}
            $item.Dispose();$processes.Remove($id)
            Update-Environment $id '' $null -Remove
        }
    }
    foreach($id in @($completed.Keys)){
        if($completed[$id].Finished -lt [DateTime]::UtcNow.AddMinutes(-5)){$completed.Remove($id)}
    }
    # At most 64 retained results (2,097,152 output characters), separate from live process slots.
    while($completed.Count -gt 64){
        $oldest=$completed.Keys|Sort-Object {$completed[$_].Finished}|Select-Object -First 1
        $completed.Remove($oldest)
    }
}

function Request-TaskId($values) {
    $taskId=[string]$values.taskId
    if(!$taskId -and !$config.enforce_target){$taskId='legacy-'+$PID}
    if($taskId -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$'){throw 'Explicit taskId required for environment coordination.'}
    return $taskId
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
    if ($controlOnly) { return }
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

function New-TrackedProcess($values,[string]$Operation='process_start') {
    if (-not $allowShell) { throw 'Shell is disabled; reconnect with owner-authorized AllowShell.' }
    if ([string]::IsNullOrWhiteSpace([string]$values.command) -or ([string]$values.command).Length -gt 16384) { throw 'Invalid command length.' }
    Clear-FinishedProcesses
    $exclusive=$false
    if($null -ne $values.exclusive){
        if($values.exclusive -isnot [bool]){throw 'exclusive must be a boolean.'}
        $exclusive=$values.exclusive
    }
    $cwd = Workspace-Path ([string]$values.cwd)
    if (-not [IO.Directory]::Exists($cwd)) { throw 'Command directory does not exist.' }
    $taskId=Request-TaskId $values
    $id = [Guid]::NewGuid().ToString('N')
    Update-Environment $id $taskId ([Diagnostics.Process]::GetCurrentProcess()) -Exclusive $exclusive -Operation $Operation
    try {
        Assert-SyncBarrier
        $item = New-Object BridgeProcess ([string]$values.command), $cwd
        $item.TaskId=$taskId
        Update-Environment $id $taskId $item.Process -Exclusive $exclusive -Operation $Operation
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
            if ($controlOnly) { return @{ok=$true;device=$device;platform='windows';workspace=$root;shell_enabled=$allowShell;control_only=$true;project_id=[string]$config.project_id;host_id=[string]$config.host_id;file_mutations_enabled=$true;sync_guard=@{required=$false};capabilities=$capabilities;coordination=@{exclusive=$true;per_task_limit=8;global_limit=64;completed_ttl_seconds=300};active_processes=$processes.Count} }
            return @{ ok = $true; device = $device; platform = 'windows'; workspace = $root; shell_enabled = $allowShell; file_mutations_enabled = -not $serverOwned; sync_guard = @{ required=$serverOwned; project_id=[string]$syncGuard.project_id; host_id=[string]$syncGuard.host_id; state=$syncState }; capabilities = $capabilities; coordination=@{exclusive=$true;per_task_limit=8;global_limit=64;completed_ttl_seconds=300};active_processes = $processes.Count; notes = 'Capabilities are executable discovery only; ADB devices, VPN routes and remote SSH have not been tested. A sync preflight confirms the snapshot before process start; it does not freeze subsequent server edits.' }
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
            $tracked = New-TrackedProcess $values 'command'
            # The event loop holds this connection while accepting other agents' requests.
            return @{deferred=$true;id=$tracked.id;deadline=[DateTime]::UtcNow.AddSeconds($timeout)}
        }
        'process_start' {
            $tracked = New-TrackedProcess $values
            return @{ ok = $true; id = $tracked.id; pid = $tracked.item.Process.Id }
        }
        'process_poll' {
            $id = [string]$values.id
            $taskId=Request-TaskId $values
            if($processes.ContainsKey($id)){
                $item=$processes[$id]
                if($taskId -cne $item.TaskId){throw 'Tracked process belongs to another task.'}
                $result=Process-Result $item
                if(!$result.running -and !$pendingCommands.ContainsKey($id)){
                    $item.Dispose();$processes.Remove($id)
                    Update-Environment $id '' $null -Remove
                }
                return $result
            }
            if(!$completed.ContainsKey($id)){throw 'Unknown bridge process (or completed output expired/read).'}
            if($taskId -cne $completed[$id].TaskId){throw 'Tracked process belongs to another task.'}
            $result=$completed[$id].Result;$completed.Remove($id)
            return $result
        }
        'process_stop' {
            $id = [string]$values.id
            $taskId=Request-TaskId $values
            if($processes.ContainsKey($id)){
                if($taskId -cne $processes[$id].TaskId){throw 'Tracked process belongs to another task.'}
                if($pendingCommands.ContainsKey($id)){throw 'Synchronous command cannot be stopped by process_stop.'}
                $processes[$id].Dispose();$processes.Remove($id)
                Update-Environment $id '' $null -Remove
            }elseif($completed.ContainsKey($id)){
                if($taskId -cne $completed[$id].TaskId){throw 'Tracked process belongs to another task.'}
                $completed.Remove($id)
            }else{throw 'Unknown bridge process (or completed output expired/read).'}
            return @{ok=$true;stopped=$true}
        }
        'shutdown' { $script:quit = $true; return @{ ok = $true; stopped = $true } }
        default { throw 'Unknown operation.' }
    }
}

function Send-Response($client,$response) {
    try {
        $json=$response|ConvertTo-Json -Depth 12 -Compress
        $json=$json.Replace($secret,'[redacted]')
        $answer=[Text.Encoding]::UTF8.GetBytes($json+"`n")
        if($answer.Length -gt 262144){$answer=[Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"Response exceeds limit"}'+"`n")}
        $client.GetStream().Write($answer,0,$answer.Length)
    } finally {$client.Close()}
}

function Complete-Commands {
    foreach($id in @($pendingCommands.Keys)){
        $pending=$pendingCommands[$id];$item=$processes[$id]
        $finished=$item.Process.HasExited
        if(!$finished -and [DateTime]::UtcNow -lt $pending.deadline){continue}
        try {
            if(!$finished){$item.Stop()}
            $result=Process-Result $item
            $result.Remove('running');$result.timed_out=-not $finished
        }catch{
            $result=@{ok=$false;error='Command completion failed.'}
        }finally{
            $item.Dispose();$processes.Remove($id);$pendingCommands.Remove($id)
            Update-Environment $id '' $null -Remove
        }
        # Release the lease and slot before the caller receives the final result.
        try{Send-Response $pending.client $result}catch{}
    }
}

$listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
# Partial frames are read incrementally so a slow/disconnected client cannot stall commands.
$frames=@{}
try {
    $null = Workspace-Path '.'
    $listener.Start(128)
    @{ state = 'ready'; port = $listener.LocalEndpoint.Port; device = $device } | ConvertTo-Json -Compress | ForEach-Object { [Console]::WriteLine($_) }
    while (-not $quit) {
        if ($parentProcess.HasExited) { break }
        Complete-Commands
        Clear-FinishedProcesses
        if($listener.Pending()){
            $client=$listener.AcceptTcpClient()
            if($frames.Count+$pendingCommands.Count -ge 128){$client.Close()}else{
                $stream=$client.GetStream();$stream.WriteTimeout=1000
                $frames[[Guid]::NewGuid().ToString('N')]=@{client=$client;stream=$stream;bytes=(New-Object 'Collections.Generic.List[byte]');deadline=[DateTime]::UtcNow.AddSeconds(5)}
            }
        }
        foreach($frameId in @($frames.Keys)){
            $frame=$frames[$frameId];$keep=$true
            try {
                if([DateTime]::UtcNow -ge $frame.deadline){throw 'Frame read timed out.'}
                # Poll detects EOF even when DataAvailable is false.
                if($frame.client.Client.Poll(0,[Net.Sockets.SelectMode]::SelectRead) -and $frame.client.Client.Available -eq 0){throw 'Incomplete frame.'}
                while($frame.stream.DataAvailable){
                    $value=$frame.stream.ReadByte()
                    if($value -eq -1){throw 'Incomplete frame.'}
                    if($value -eq 10){
                        $keep=$false
                        try{$request=[Text.Encoding]::UTF8.GetString($frame.bytes.ToArray())|ConvertFrom-Json;$response=Dispatch $request}
                        catch{$response=@{ok=$false;error='Request rejected: '+$_.Exception.Message}}
                        if($response.deferred){
                            $pendingCommands[$response.id]=@{client=$frame.client;deadline=$response.deadline}
                        }else{Send-Response $frame.client $response}
                        break
                    }
                    if($frame.bytes.Count -ge 262144){throw 'Frame too large.'}
                    $frame.bytes.Add([byte]$value)
                }
            }catch{$keep=$false;$frame.client.Close()}
            if(!$keep){$frames.Remove($frameId)}
        }
        Start-Sleep -Milliseconds 10
    }
} finally {
    $listener.Stop()
    foreach($frame in $frames.Values){$frame.client.Close()}
    foreach($pending in $pendingCommands.Values){$pending.client.Close()}
    foreach ($id in @($processes.Keys)) { $processes[$id].Dispose();Update-Environment $id '' $null -Remove }
    $environmentMutex.Dispose()
    $secret = $null; $config = $null
}
