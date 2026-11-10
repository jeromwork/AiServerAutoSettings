[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.:-]*$')][string]$VPSHost,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-z_][a-z0-9_-]*$')][string]$VPSUser,
    [Parameter(Mandatory=$true)][string]$IdentityFile,
    [Parameter(Mandatory=$true)][string]$Workspace,
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$')][string]$DeviceLabel = 'current-pc',
    [ValidateRange(1,65535)][int]$SSHPort = 22,
    [string]$SSHExecutable = 'ssh.exe',
    [string]$SSHConfig,
    [Parameter(Mandatory=$true)][string]$KnownHostsFile,
    [ValidatePattern('^[a-z_][a-z0-9_-]*$')][string]$ServerUser,
    [ValidatePattern('^(/[a-zA-Z0-9._-]+)+$')][string]$RemoteBase = '/home/remoteagents/.local/share/codex-remote',
    [ValidatePattern('^(/[a-zA-Z0-9._-]+)+$')][string]$SocketPath,
    [switch]$AllowShell,
    [string]$AskpassExecutable,
    [switch]$ServerOwnedReplica,
    [switch]$ControlOnly,
    [string]$SyncGuardPath,
    [string]$SyncDataDir,
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$')][string]$ProjectId,
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$')][string]$HostId,
    [switch]$ManagedSession,
    [switch]$RetryForever,
    [string]$LogFile
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$ProgressPreference = 'SilentlyContinue'
function Quote-Windows([string]$value) {
    # CommandLineToArgvW-compatible quoting; never pass secret in these arguments.
    return '"' + ([regex]::Replace([regex]::Replace($value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1')) + '"'
}
if ($ManagedSession) {
    Add-Type -TypeDefinition @'
using System;
using System.Threading;
public static class BridgeManagedControl {
    public static volatile bool StopRequested;
    public static void Start() {
        var reader = new Thread(() => {
            while(true) { var line = Console.ReadLine(); if(line == null || line.Trim().Equals("stop", StringComparison.OrdinalIgnoreCase)) { StopRequested = true; return; } }
        });
        reader.IsBackground = true; reader.Start();
    }
}
'@
    [BridgeManagedControl]::Start()
}
function Is-Stopping { return $ManagedSession -and [BridgeManagedControl]::StopRequested }
function Write-BridgeStatus([string]$state, [string]$message) {
    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' bridge.' + $state + ' ' + $message + "`r`n")) } catch { } }
    if ($ManagedSession) { [Console]::WriteLine((@{state=$state;device=$DeviceLabel;message=$message} | ConvertTo-Json -Compress)) }
    else { Write-Host $message }
}
function Start-PrivateProcess([string]$file, [string[]]$values, [switch]$ForSSH) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $file
    $info.Arguments = (($values | ForEach-Object { Quote-Windows $_ }) -join ' ')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    if ($ForSSH -and $AskpassExecutable) {
        $info.EnvironmentVariables['SSH_ASKPASS'] = $AskpassExecutable
        $info.EnvironmentVariables['SSH_ASKPASS_REQUIRE'] = 'force'
        $info.EnvironmentVariables['DISPLAY'] = 'codex-remote'
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $null = $process.Start()
    return $process
}
function Await-Line($process, [int]$seconds) {
    $task = $process.StandardOutput.ReadLineAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
    while (-not $task.Wait(100)) {
        if ((Is-Stopping) -or [DateTime]::UtcNow -ge $deadline) { throw 'Connection readiness stopped or timed out.' }
    }
    if ([string]::IsNullOrWhiteSpace($task.Result)) { throw 'Connection ended before readiness.' }
    return $task.Result
}
function Stop-PrivateProcess($process) {
    if ($null -ne $process) {
        try { $process.StandardInput.Close() } catch { }
        if (-not $process.HasExited -and -not $process.WaitForExit(1500)) { $process.Kill(); $null = $process.WaitForExit(5000) }
        $process.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $KnownHostsFile -PathType Leaf)) { throw 'Verified known_hosts file is required. Run SSH setup first.' }
if (-not (Test-Path -LiteralPath $IdentityFile -PathType Leaf)) { throw 'SSH identity path does not exist.' }
if ($SSHConfig -and -not (Test-Path -LiteralPath $SSHConfig -PathType Leaf)) { throw 'SSH config path does not exist.' }
if ($AskpassExecutable -and -not (Test-Path -LiteralPath $AskpassExecutable -PathType Leaf)) { throw 'Askpass helper path does not exist.' }
if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) { throw 'Select an existing workspace folder.' }
if ($ControlOnly -and ($ServerOwnedReplica -or $SyncGuardPath -or $SyncDataDir -or -not $ProjectId -or -not $HostId)) { throw 'ControlOnly requires identity without sync mode.' }
if (($SyncGuardPath -or $SyncDataDir -or $ProjectId -or $HostId) -and -not $ServerOwnedReplica -and -not $ControlOnly) { throw 'Sync binding requires ServerOwnedReplica mode.' }
if ($SyncGuardPath) {
    if (-not $SyncDataDir -or -not $ProjectId -or -not $HostId) { throw 'Sync guard requires DataDir, ProjectId and HostId.' }
    $SyncGuardPath = [IO.Path]::GetFullPath($SyncGuardPath)
    if (-not (Test-Path -LiteralPath $SyncGuardPath -PathType Leaf) -or [IO.Path]::GetExtension($SyncGuardPath) -ne '.ps1' -or ((Get-Item -LiteralPath $SyncGuardPath).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Sync guard must be an existing regular PowerShell script.' }
    $SyncDataDir = [IO.Path]::GetFullPath($SyncDataDir)
}
if (-not $SocketPath) {
    if (-not $ServerUser) { $ServerUser = $VPSUser }
    $SocketPath = '/home/' + $ServerUser + '/.local/state/codex-remote/' + $DeviceLabel + '.sock'
}
$tokenBytes = New-Object byte[] 32
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($tokenBytes); $rng.Dispose()
$token = ([BitConverter]::ToString($tokenBytes)).Replace('-','').ToLowerInvariant()
[Array]::Clear($tokenBytes,0,$tokenBytes.Length)
$executor = $null; $ssh = $null
try {
    $executorExe='powershell.exe';if($env:OS -eq 'Windows_NT'){$executorExe=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'}
    $executor = Start-PrivateProcess $executorExe @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'windows-bridge-executor.ps1'))
    $localConfig = @{ token = $token; workspace = [IO.Path]::GetFullPath($Workspace); device = $DeviceLabel; allow_shell = [bool]$AllowShell; parent_pid = $PID; server_owned = [bool]$ServerOwnedReplica; enforce_target=[bool]$ServerOwnedReplica; sync_guard = @{ path=$SyncGuardPath; data_dir=$SyncDataDir; project_id=$ProjectId; host_id=$HostId } } | ConvertTo-Json -Depth 4 -Compress
    if ($ControlOnly) {
        $controlConfig=$localConfig | ConvertFrom-Json
        $controlConfig | Add-Member -NotePropertyName control_only -NotePropertyValue $true
        $controlConfig | Add-Member -NotePropertyName project_id -NotePropertyValue $ProjectId
        $controlConfig | Add-Member -NotePropertyName host_id -NotePropertyValue $HostId
        $controlConfig.enforce_target=$true
        $localConfig=$controlConfig | ConvertTo-Json -Depth 4 -Compress
    }
    $executor.StandardInput.WriteLine($localConfig); $executor.StandardInput.Flush(); $localConfig = $null
    $ready = (Await-Line $executor 20) | ConvertFrom-Json
    if ($ready.state -ne 'ready') { throw 'Windows executor did not initialize.' }
    Write-BridgeStatus 'ready' ('Windows bridge ready: ' + $DeviceLabel + '. Shell enabled: ' + [bool]$AllowShell)
    $attempt = 0
    while (-not $executor.HasExited -and -not (Is-Stopping)) {
        $attempt++
        $portBytes = New-Object byte[] 2
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($portBytes); $rng.Dispose()
        $remotePort = 49152 + ([BitConverter]::ToUInt16($portBytes,0) % 16384)
        $command = "python3 '$RemoteBase/codex-bridge-session.py' --socket '$SocketPath'"
        if ($ServerUser -and $ServerUser -ne $VPSUser) {
            $command = 'if [ "$(id -u)" -eq 0 ]; then exec runuser -u ' + $ServerUser + ' -- ' + $command + '; else exec sudo -n -u ' + $ServerUser + ' -- ' + $command + '; fi'
        } else { $command = 'exec ' + $command }
        $batchMode = $(if ($AskpassExecutable) { 'BatchMode=no' } else { 'BatchMode=yes' })
        $sshArgs = @('-T','-p',[string]$SSHPort,'-i',$IdentityFile,'-o',$batchMode,'-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile="' + $KnownHostsFile.Replace('\','/') + '"'),'-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=3','-o','ConnectTimeout=10')
        if ($SSHConfig) { $sshArgs += @('-F',$SSHConfig) } else { $sshArgs += @('-F','NUL') }
        $sshArgs += @('-R',('127.0.0.1:' + $remotePort + ':127.0.0.1:' + $ready.port),($VPSUser + '@' + $VPSHost),$command)
        try {
            $ssh = Start-PrivateProcess $SSHExecutable $sshArgs -ForSSH
            $sshErrors = $ssh.StandardError.ReadToEndAsync()
            $ssh.StandardInput.WriteLine((@{ token = $token; port = $remotePort; device = $DeviceLabel; deviceLabel=$DeviceLabel; projectId=$ProjectId; hostId=$HostId; windowsReplica=[IO.Path]::GetFullPath($Workspace) } | ConvertTo-Json -Compress)); $ssh.StandardInput.Flush()
            $remoteReady = (Await-Line $ssh 25) | ConvertFrom-Json
            if ($remoteReady.state -ne 'connected') { throw 'Remote bridge session was not ready.' }
            $attempt = 0
            Write-BridgeStatus 'connected' ('Connected: ' + $DeviceLabel + '. Codex can use the Windows MCP tools. Ctrl+C disconnects and stops tracked processes.')
            while (-not $ssh.HasExited -and -not $executor.HasExited -and -not (Is-Stopping)) { Start-Sleep -Milliseconds 250 }
            if (-not (Is-Stopping) -and -not $executor.HasExited) { throw 'SSH connection ended; reconnecting the Windows bridge.' }
        } catch {
            if (-not (Is-Stopping)) {
                $detail = $_.Exception.Message
                if ($ssh -and -not $ssh.HasExited) { $null = $ssh.WaitForExit(500) }
                if ($sshErrors -and $sshErrors.Wait(500) -and -not [string]::IsNullOrWhiteSpace($sshErrors.Result)) { $detail = $sshErrors.Result.Trim() }
                $detail = $detail.Replace($token, '[redacted]')
                if ($detail.Length -gt 1000) { $detail = $detail.Substring(0,1000) }
                Write-BridgeStatus 'disconnected' ('Bridge disconnected. ' + $detail)
            }
        } finally { Stop-PrivateProcess $ssh; $ssh = $null }
        if ($attempt -ge 5 -and -not $RetryForever -and -not (Is-Stopping)) { throw 'Bridge failed five times. Check uploaded bridge files, remote user, verified host key and SSH forwarding permissions.' }
        if (-not $executor.HasExited -and -not (Is-Stopping)) { Start-Sleep -Seconds ([Math]::Min($(if ($RetryForever) { 30 } else { 10 }), 2 + $attempt)) }
    }
    if (-not (Is-Stopping)) { throw 'Windows executor stopped.' }
} finally {
    Stop-PrivateProcess $ssh
    if ($executor -and -not $executor.HasExited -and $ready) {
        try {
            $client = New-Object Net.Sockets.TcpClient
            $client.Connect('127.0.0.1',[int]$ready.port)
            $stream = $client.GetStream(); $stream.WriteTimeout = 1000
            $payload = [Text.Encoding]::UTF8.GetBytes((@{ token = $token; op = 'shutdown'; args = @{};binding=@{projectId=$ProjectId;hostId=$HostId;deviceLabel=$DeviceLabel;windowsReplica=[IO.Path]::GetFullPath($Workspace)} } | ConvertTo-Json -Depth 4 -Compress) + "`n")
            $stream.Write($payload,0,$payload.Length); $client.Close()
            $null = $executor.WaitForExit(5000)
        } catch { }
    }
    Stop-PrivateProcess $executor
    $token = $null
    Write-BridgeStatus 'stopped' 'Windows bridge stopped.'
}
