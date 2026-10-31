# PS5.1 bounded localhost fixture. Uses only its own temporary directory/process.
$ErrorActionPreference = 'Stop'
function Check([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('bridge-sync-fixture-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($fixture)
$modePath = Join-Path $fixture 'mode.txt'
$guardPath = Join-Path $fixture 'fixture-guard.ps1'
$utf8 = New-Object Text.UTF8Encoding $false
$hook = @'
[Console]::InputEncoding = New-Object Text.UTF8Encoding $false
$ErrorActionPreference = 'Stop'
$request = [Console]::ReadLine() | ConvertFrom-Json
$mode = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'mode.txt')).Trim()
if ($mode -eq 'offline') { throw 'fixture-private-transport-detail' }
$answer = @{ ready=($mode -ne 'stale'); fresh=($mode -ne 'cached'); projectId=$request.projectId; hostId=$request.hostId; replicaPath=$request.replicaPath; snapshotId='fixture-snapshot'; requestId=$request.requestId }
if ($mode -eq 'mismatch') { $answer.hostId = 'other-host' }
if ($mode -eq 'replay') { $answer.requestId = 'old-request' }
[Console]::WriteLine(($answer | ConvertTo-Json -Compress))
'@
[IO.File]::WriteAllText($guardPath,$hook,$utf8)
[IO.File]::WriteAllText($modePath,'ready',$utf8)
$tokenBytes = New-Object byte[] 32
$random = [Security.Cryptography.RandomNumberGenerator]::Create()
$random.GetBytes($tokenBytes); $random.Dispose()
$token = [BitConverter]::ToString($tokenBytes).Replace('-','').ToLowerInvariant()
[Array]::Clear($tokenBytes,0,$tokenBytes.Length)
$executor = $null
function Request([string]$op, $values) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1',[int]$ready.port)
        $stream = $client.GetStream(); $stream.ReadTimeout = 40000; $stream.WriteTimeout = 5000
        $payload = [Text.Encoding]::UTF8.GetBytes((@{token=$token;op=$op;args=$values} | ConvertTo-Json -Depth 5 -Compress) + "`n")
        $stream.Write($payload,0,$payload.Length)
        $reader = New-Object IO.StreamReader $stream, ([Text.Encoding]::UTF8)
        return ($reader.ReadLine() | ConvertFrom-Json)
    } finally { $client.Close() }
}
try {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = 'powershell.exe'
    $info.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'windows-bridge-executor.ps1') + '"'
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $executor = New-Object Diagnostics.Process
    $executor.StartInfo=$info; $null=$executor.Start()
    $errors = $executor.StandardError.ReadToEndAsync()
    $configuration = @{token=$token;workspace=$fixture;device='sync-fixture';allow_shell=$true;parent_pid=$PID;server_owned=$true;sync_guard=@{path=$guardPath;data_dir=$fixture;project_id='fixture-project';host_id='fixture-host'}} | ConvertTo-Json -Depth 4 -Compress
    $executor.StandardInput.WriteLine($configuration); $executor.StandardInput.Flush(); $configuration=$null
    $readiness = $executor.StandardOutput.ReadLineAsync()
    Check ($readiness.Wait(10000)) 'Executor readiness timeout'
    $ready = $readiness.Result | ConvertFrom-Json
    Check ($ready.state -eq 'ready') 'Executor did not become ready'
    $status = Request 'status' @{}
    Check ($status.ok -and $status.sync_guard.required -and -not $status.file_mutations_enabled) 'Server-owned status missing'
    $write = Request 'write' @{path='must-not-exist.txt';content='denied'}
    Check (-not $write.ok -and -not [IO.File]::Exists((Join-Path $fixture 'must-not-exist.txt'))) 'Server-owned MCP mutation allowed'
    $result = Request 'command' @{command="Write-Output 'sync-fixture-ready'";timeout_seconds=5}
    if (-not $result.ok) { $failedStatus = Request 'status' @{}; throw ('Fresh ready command failed: ' + $failedStatus.sync_guard.state) }
    Check ($result.exit_code -eq 0 -and $result.output.Contains('sync-fixture-ready')) 'Fresh ready command failed'
    foreach ($mode in @('stale','offline','mismatch','replay','cached')) {
        [IO.File]::WriteAllText($modePath,$mode,$utf8)
        $result = Request 'command' @{command="Write-Output 'must-not-run'";timeout_seconds=5}
        Check (-not $result.ok -and -not ($result | ConvertTo-Json -Compress).Contains('fixture-private-transport-detail')) ('Guard failed closed or leaked detail: ' + $mode)
    }
    [IO.File]::WriteAllText($modePath,'stale',$utf8)
    $result = Request 'process_start' @{command="Write-Output 'must-not-start'"}
    Check (-not $result.ok) 'Process start bypassed sync guard'
    [IO.File]::WriteAllText($modePath,'ready',$utf8)
    $result = Request 'command' @{command="Write-Output 'sync-fixture-recovered'";timeout_seconds=5}
    Check ($result.ok -and $result.output.Contains('sync-fixture-recovered')) 'Fresh recovery failed'
    $null = Request 'shutdown' @{}
    Check ($executor.WaitForExit(5000)) 'Fixture shutdown failed'
    Write-Output 'PASS: ready/recovered execution; stale/offline/mismatch/replay/cached and process-start denial; server-owned file writes denied; hook errors redacted'
} finally {
    if ($executor) { if (-not $executor.HasExited) { $executor.Kill(); $null=$executor.WaitForExit(5000) }; $executor.Dispose() }
    $token=$null
    # Delete only the three files and the exact new empty directory this test created.
    foreach ($file in @($modePath,$guardPath)) { if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } }
    if ([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture,$false) }
}
