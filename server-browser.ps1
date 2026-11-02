[CmdletBinding()]
param(
    [string]$VPSHost,
    [string]$VPSUser,
    [string]$IdentityFile,
    [string]$SSHExecutable = "$env:WINDIR\System32\OpenSSH\ssh.exe",
    [string]$SSHConfig,
    [string]$KnownHostsFile,
    [string]$AskpassExecutable,
    [ValidateRange(1,65535)][int]$SSHPort = 22,
    [string]$ServerUser = 'remoteagents',
    [switch]$Prepare,
    [switch]$ManagedSession
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

function Convert-BrowserSshArgument([string]$Value) {
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function New-BrowserSshStart([string[]]$Arguments) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $SSHExecutable
    $start.Arguments = (@($Arguments | ForEach-Object { Convert-BrowserSshArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    if ($AskpassExecutable) {
        $start.EnvironmentVariables['SSH_ASKPASS'] = $AskpassExecutable
        $start.EnvironmentVariables['SSH_ASKPASS_REQUIRE'] = 'force'
        $start.EnvironmentVariables['DISPLAY'] = 'remoteagents-askpass'
        $start.EnvironmentVariables['REMOTE_AGENTS_ASKPASS_CANCEL'] = $script:browserCancelEventName
    }
    return $start
}

function Invoke-BrowserSsh([string[]]$Arguments, [string]$InputText) {
    $start = New-BrowserSshStart $Arguments
    $start.RedirectStandardInput = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'SSH did not start.' }
        if ($InputText) {
            # Write UTF-8 without a BOM; do not let a Windows console code page alter shell source.
            $bytes = [Text.Encoding]::UTF8.GetBytes($InputText.Replace("`r`n", "`n"))
            $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        }
        $process.StandardInput.Close()
        while (-not $process.WaitForExit(250)) {
            if ($script:browserCancelled -and $script:browserCancelled.WaitOne(0)) {
                $process.Kill(); $process.WaitForExit()
                throw 'SSH password entry was cancelled.'
            }
        }
        if ($process.ExitCode -ne 0) { throw "Server browser SSH operation failed (exit $($process.ExitCode)). See the console error above." }
    } finally { $process.Dispose() }
}

function Get-BrowserFreePort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    try { $listener.Start(); return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function Test-BrowserTunnel([int]$Port) {
    $response = $null
    try {
        $request = [Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/vnc.html")
        $request.Proxy = $null
        $request.Timeout = 1500
        $response = $request.GetResponse()
        return [int]$response.StatusCode -eq 200
    } catch { return $false }
    finally { if ($response) { $response.Close() } }
}

# Dot sourcing defines pure helpers for the offline test without connecting or opening a UI.
if ($MyInvocation.InvocationName -eq '.') { return }

$tunnel = $null
$script:browserCancelled = $null
try {
    if ($VPSHost -notmatch '^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}$' -or $VPSHost.Contains('..')) { throw 'Invalid server host.' }
    if ($VPSUser -notmatch '^[a-z_][a-z0-9_-]{0,31}$' -or $ServerUser -notmatch '^[a-z_][a-z0-9_-]{0,31}$' -or $ServerUser -eq 'root') { throw 'Invalid server user.' }
    # Existence checks inspect path metadata only; private-key contents are never read by this script.
    foreach ($path in @($SSHExecutable, $IdentityFile, $SSHConfig, $KnownHostsFile)) {
        if (-not $path -or -not [IO.File]::Exists($path)) { throw 'A required verified SSH connection file is missing. Complete SSH setup first.' }
        if ($path.IndexOfAny(@([char]0, [char]10, [char]13, [char]34)) -ge 0) { throw 'Invalid SSH file path.' }
    }
    if ($AskpassExecutable) {
        if (-not [IO.File]::Exists($AskpassExecutable)) { throw 'The SSH password window helper is missing.' }
        $script:browserCancelEventName = 'Local\RemoteAgents.BrowserAskpass.' + [guid]::NewGuid().ToString('N')
        $security = New-Object Security.AccessControl.EventWaitHandleSecurity
        $security.SetAccessRuleProtection($true, $false)
        $security.AddAccessRule((New-Object Security.AccessControl.EventWaitHandleAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'Allow')))
        $created = $false
        $script:browserCancelled = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $script:browserCancelEventName, [ref]$created, $security)
    }
    $batchMode = if ($AskpassExecutable) { 'BatchMode=no' } else { 'BatchMode=yes' }
    $baseArgs = @('-F', $SSHConfig, '-p', [string]$SSHPort, '-i', $IdentityFile,
        '-o', "UserKnownHostsFile=`"$KnownHostsFile`"", '-o', 'StrictHostKeyChecking=yes',
        '-o', $batchMode, '-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no',
        '-o', 'NumberOfPasswordPrompts=1', '-o', 'IdentitiesOnly=yes', '-o', 'ConnectTimeout=15',
        '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3')
    $destination = "$VPSUser@$VPSHost"
    if ($Prepare) {
        $bootstrap = Join-Path $PSScriptRoot 'server-browser-bootstrap.sh'
        if (-not [IO.File]::Exists($bootstrap)) { throw 'server-browser-bootstrap.sh must be beside this launcher.' }
        $command = if ($VPSUser -eq 'root') { "bash -s -- $ServerUser" } else { "sudo -n bash -s -- $ServerUser" }
        Invoke-BrowserSsh ($baseArgs + @($destination, $command)) ([IO.File]::ReadAllText($bootstrap))
    }
    Invoke-BrowserSsh ($baseArgs + @($destination, 'systemctl is-active --quiet remoteagents-browser.service && curl --fail --silent --max-time 3 -H "Host: 127.0.0.1:6091" http://127.0.0.1:6091/vnc.html >/dev/null')) ''
    $port = Get-BrowserFreePort
    $start = New-BrowserSshStart ($baseArgs + @('-N', '-o', 'ExitOnForwardFailure=yes', '-L', "127.0.0.1:${port}:127.0.0.1:6091", $destination))
    $start.RedirectStandardError = $true
    $tunnel = New-Object Diagnostics.Process
    $tunnel.StartInfo = $start
    if (-not $tunnel.Start()) { throw 'Could not start the private browser tunnel.' }
    $errors = $tunnel.StandardError.ReadToEndAsync()
    $ready = $false
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        if ($tunnel.HasExited) { throw "Browser tunnel failed: $($errors.GetAwaiter().GetResult())" }
        if (Test-BrowserTunnel $port) { $ready = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $ready) { throw 'Server browser tunnel did not become ready.' }
    Start-Process "http://127.0.0.1:$port/vnc.html#autoconnect=true&resize=scale" | Out-Null
    if ($ManagedSession) {
        [Console]::Out.WriteLine("REMOTEAGENTS_BROWSER_READY=http://127.0.0.1:$port/vnc.html#autoconnect=true&resize=scale")
        [Console]::Out.Flush()
        $stopRequest = [Console]::In.ReadLineAsync()
        while (-not $stopRequest.Wait(500)) {
            if ($tunnel.HasExited) { throw "Browser tunnel stopped: $($errors.GetAwaiter().GetResult())" }
        }
        # Any line or EOF requests cleanup; no account information is accepted on stdin.
    } else {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show(
            'The browser is running on your server. Enter account passwords only in that browser. Keep this window open while using it. Press OK to close the SSH connection; your server browser profile stays on the server.',
            'Server browser connection', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    if (-not $ManagedSession -and [Environment]::UserInteractive) {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Server browser error', 'OK', 'Error') | Out-Null
    }
    exit 1
} finally {
    if ($tunnel) {
        if (-not $tunnel.HasExited) { $tunnel.Kill(); $tunnel.WaitForExit() }
        $tunnel.Dispose()
    }
    if ($script:browserCancelled) { $script:browserCancelled.Dispose() }
}
