[CmdletBinding()]
param(
    [string]$VPSHost, [string]$VPSUser, [string]$IdentityFile,
    [string]$SSHExecutable = "$env:WINDIR\System32\OpenSSH\ssh.exe",
    [string]$SSHConfig, [string]$KnownHostsFile, [string]$AskpassExecutable,
    [ValidateRange(1,65535)][int]$SSHPort = 22,
    [string]$ServerUser = 'remoteagents',
    [switch]$Prepare, [switch]$SetDesktopPassword, [switch]$ManagedSession,
    [ValidateSet('0','1','2','3')][string]$AgentApplications = '0'
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

function Convert-DesktopSshArgument([string]$Value) {
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function New-DesktopSshStart([string[]]$Arguments) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $SSHExecutable
    $start.Arguments = (@($Arguments | ForEach-Object { Convert-DesktopSshArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    if ($AskpassExecutable) {
        $start.EnvironmentVariables['SSH_ASKPASS'] = $AskpassExecutable
        $start.EnvironmentVariables['SSH_ASKPASS_REQUIRE'] = 'force'
        $start.EnvironmentVariables['DISPLAY'] = 'remoteagents-askpass'
        $start.EnvironmentVariables['REMOTE_AGENTS_ASKPASS_CANCEL'] = $script:desktopCancelEventName
    }
    return $start
}

function Invoke-DesktopSsh([string[]]$Arguments, [byte[]]$InputBytes = @()) {
    $start = New-DesktopSshStart $Arguments
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $started = $false
    try {
        if (-not $process.Start()) { throw 'SSH did not start.' }
        $started = $true
        # Retain the native handle while asynchronous streams drain (PS5.1).
        $processHandle = $process.Handle
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if ($InputBytes.Length) {
            # Compatible with Windows PowerShell 5.1 / .NET Framework. No StreamWriter encoding.
            $process.StandardInput.BaseStream.Write($InputBytes, 0, $InputBytes.Length)
            $process.StandardInput.BaseStream.Flush()
        }
        $process.StandardInput.Close()
        while (-not $process.WaitForExit(250)) {
            if ($script:desktopCancelled -and $script:desktopCancelled.WaitOne(0)) {
                $process.Kill(); $process.WaitForExit()
                throw 'SSH key passphrase entry was cancelled.'
            }
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $outputTask.GetAwaiter().GetResult(); Error = $errorTask.GetAwaiter().GetResult() }
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
}

function Assert-DesktopSshResult($Result) {
    if ($Result.ExitCode -ne 0) {
        $tail = (($Result.Error + "`n" + $Result.Output) -split "`r?`n" | Select-Object -Last 15) -join "`n"
        throw "Desktop SSH operation failed (exit $($Result.ExitCode)).`n$tail"
    }
}

function Get-DesktopFreePort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    try { $listener.Start(); return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function Initialize-DesktopProbe {
    if ('RemoteAgentsDesktopProbe' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
public static class RemoteAgentsDesktopProbe {
    private static byte[] ReadExact(Stream stream, int length) {
        byte[] data = new byte[length]; int offset = 0;
        while (offset < length) { int count = stream.Read(data, offset, length - offset); if (count == 0) throw new IOException("RDP EOF"); offset += count; }
        return data;
    }
    public static bool Test(int port, string fingerprint) {
        try {
            using (TcpClient client = new TcpClient()) {
                IAsyncResult connect = client.BeginConnect("127.0.0.1", port, null, null);
                if (!connect.AsyncWaitHandle.WaitOne(3000)) return false;
                client.EndConnect(connect); connect.AsyncWaitHandle.Close();
                client.ReceiveTimeout = 5000; client.SendTimeout = 5000;
                using (NetworkStream stream = client.GetStream()) {
                    byte[] request = {3,0,0,19,14,224,0,0,0,0,0,1,0,8,0,1,0,0,0};
                    stream.Write(request, 0, request.Length);
                    byte[] reply = ReadExact(stream,19);
                    byte[] expected = {2,0,8,0,1,0,0,0};
                    if (reply[0] != 3 || reply[1] != 0) return false;
                    // Byte 12 advertises optional capabilities, not the selected security protocol.
                    for (int index=0; index<8; index++) if (index != 1 && reply[index+11] != expected[index]) return false;
                    using (SslStream secure = new SslStream(stream,false, delegate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors) {
                        if (certificate == null || (errors & SslPolicyErrors.RemoteCertificateNameMismatch) != 0) return false;
                        X509Certificate2 leaf = new X509Certificate2(certificate);
                        if (DateTime.Now < leaf.NotBefore || DateTime.Now > leaf.NotAfter) return false;
                        using (SHA256 hash = SHA256.Create()) {
                            string actual = BitConverter.ToString(hash.ComputeHash(leaf.RawData)).Replace("-", "");
                            // Explicit certificate pin obtained over host-key-verified SSH, not a permissive callback.
                            return String.Equals(actual, fingerprint, StringComparison.OrdinalIgnoreCase);
                        }
                    })) {
                        secure.ReadTimeout = 5000; secure.WriteTimeout = 5000;
                        secure.AuthenticateAsClient("127.0.0.1",null,SslProtocols.Tls12,false);
                        return secure.IsAuthenticated && secure.IsEncrypted;
                    }
                }
            }
        } catch { return false; }
    }
}
'@
}

function Write-DesktopRdpFile([string]$Path, [int]$Port, [string]$UserName) {
    $content = @"
full address:s:127.0.0.1:$Port
username:s:$UserName
prompt for credentials:i:0
enablecredsspsupport:i:0
authentication level:i:2
redirectclipboard:i:1
redirectdrives:i:0
redirectprinters:i:0
drivestoredirect:s:
audiomode:i:0
audiocapturemode:i:1
screen mode id:i:2
use multimon:i:0
dynamic resolution:i:1
session bpp:i:32
desktopwidth:i:1440
desktopheight:i:900
"@
    [IO.File]::WriteAllText($Path, $content, [Text.Encoding]::Unicode)
}

# Offline tests can dot-source pure helpers without network, GUI or password prompts.
if ($MyInvocation.InvocationName -eq '.') { return }
$tunnel = $null; $rdpFile = $null; $script:desktopCancelled = $null; $phase = 'validation'
try {
    if ($VPSHost -notmatch '^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}$' -or $VPSHost.Contains('..')) { throw 'Invalid server host.' }
    if ($VPSUser -notmatch '^[a-z_][a-z0-9_-]{0,31}$' -or $ServerUser -notmatch '^[a-z_][a-z0-9_-]{0,31}$' -or $ServerUser -eq 'root') { throw 'Invalid server account.' }
    if ($VPSUser -ne 'root' -and $VPSUser -ne $ServerUser) { throw 'Для закрытого RDP-сокета нужен SSH-профиль root или самого пользователя рабочего стола.' }
    foreach ($path in @($SSHExecutable, $IdentityFile, $SSHConfig, $KnownHostsFile)) {
        if (-not $path -or -not [IO.File]::Exists($path) -or $path.IndexOfAny(@([char]0,[char]10,[char]13,[char]34)) -ge 0) { throw 'A required verified SSH file is missing or invalid.' }
    }
    if ($AskpassExecutable) {
        if (-not [IO.File]::Exists($AskpassExecutable)) { throw 'SSH key passphrase helper is missing.' }
        $script:desktopCancelEventName = 'Local\RemoteAgents.DesktopAskpass.' + [guid]::NewGuid().ToString('N')
        $security = New-Object Security.AccessControl.EventWaitHandleSecurity
        $security.SetAccessRuleProtection($true,$false)
        $security.AddAccessRule((New-Object Security.AccessControl.EventWaitHandleAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().User,'FullControl','Allow')))
        $created = $false
        $script:desktopCancelled = [Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$script:desktopCancelEventName,[ref]$created,$security)
    }
    $batch = if ($AskpassExecutable) { 'BatchMode=no' } else { 'BatchMode=yes' }
    $baseArgs = @('-F',$SSHConfig,'-p',[string]$SSHPort,'-i',$IdentityFile,
        '-o',"UserKnownHostsFile=`"$KnownHostsFile`"",'-o','StrictHostKeyChecking=yes','-o',$batch,
        '-o','PasswordAuthentication=no','-o','KbdInteractiveAuthentication=no','-o','NumberOfPasswordPrompts=1',
        '-o','IdentitiesOnly=yes','-o','ConnectTimeout=15','-o','ServerAliveInterval=30','-o','ServerAliveCountMax=3')
    $destination = "$VPSUser@$VPSHost"
    $privilege = if ($VPSUser -eq 'root') { '' } else { 'sudo -n ' }
    $ready = Invoke-DesktopSsh ($baseArgs + @($destination,"${privilege}python3 /usr/local/lib/remoteagents-desktop/check.py && { systemctl is-active --quiet remoteagents-desktop-audio.service || printf 'AUDIO_SETUP_REQUIRED\n'; }"))
    if ($Prepare -and $ready.ExitCode -ne 0) {
        $phase = 'подготовка сервера'
        [Console]::WriteLine('REMOTEAGENTS_DESKTOP_PROGRESS=Установка и настройка пакетов рабочего стола')
        $bootstrap = Join-Path $PSScriptRoot 'server-desktop-bootstrap.sh'
        $bytes = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($bootstrap).Replace("`r`n","`n"))
        Write-Output 'Подготовка рабочего стола сервера (первая установка может занять несколько минут)...'
        $prepared = Invoke-DesktopSsh ($baseArgs + @($destination,"${privilege}bash -s -- $ServerUser")) $bytes
        Assert-DesktopSshResult $prepared
    }
    if($Prepare -and ($ready.ExitCode -ne 0 -or $ready.Output -match 'AUDIO_SETUP_REQUIRED')){
        $audioBootstrap = Join-Path $PSScriptRoot 'server-desktop-audio.sh'
        [Console]::WriteLine('REMOTEAGENTS_DESKTOP_PROGRESS=Настройка звука и микрофона')
        if (-not [IO.File]::Exists($audioBootstrap)) { throw 'Не хватает компонента звука. Скопируйте весь комплект программы.' }
        $audioBytes = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($audioBootstrap).Replace("`r`n","`n"))
        Write-Output 'Настройка звука и микрофона этого компьютера для диктовки на сервере.'
        $audioResult = Invoke-DesktopSsh ($baseArgs + @($destination,"${privilege}bash -s -- $ServerUser")) $audioBytes
        if ($audioResult.ExitCode -ne 0) {
            Write-Output 'Звук пока не настроен; рабочий стол сохранён. Повторите подключение позднее.'
            Write-Output $audioResult.Error
        } else {
            Write-Output 'Звук и микрофон подготовлены. После подключения заново откройте приложение для диктовки.'
        }
    }
    $phase = 'проверка сервера'
    [Console]::WriteLine('REMOTEAGENTS_DESKTOP_PROGRESS=Проверка готовности рабочего стола')
    if($ready.ExitCode -ne 0){$ready = Invoke-DesktopSsh ($baseArgs + @($destination,"${privilege}python3 /usr/local/lib/remoteagents-desktop/check.py"))}
    Assert-DesktopSshResult $ready
    if ($AgentApplications -ne '0') {
        $launchPath = Join-Path $PSScriptRoot 'server-desktop-onboarding.py'
        $launchBytes = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($launchPath).Replace("`r`n","`n"))
        $launchCommand = "${privilege}runuser -u $ServerUser -- env HOME=/home/$ServerUser python3 -I - $AgentApplications"
        $launched = Invoke-DesktopSsh ($baseArgs + @($destination,$launchCommand)) $launchBytes
        if ($launched.ExitCode -ne 0) { Write-Output 'Приложение не открылось автоматически. Используйте ярлык Codex/Claude на рабочем столе сервера.' }
    }
    $phase = 'SSH-подключение'
    [Console]::WriteLine('REMOTEAGENTS_DESKTOP_PROGRESS=Подключение к рабочему столу')
    $certificate = Invoke-DesktopSsh ($baseArgs + @($destination,"${privilege}openssl x509 -in /usr/local/lib/remoteagents-desktop/tls/cert.pem -noout -fingerprint -sha256"))
    Assert-DesktopSshResult $certificate
    $fingerprint = ($certificate.Output.Trim() -split '=')[-1].Replace(':','')
    if ($fingerprint -notmatch '^[0-9a-fA-F]{64}$') { throw 'Invalid public desktop TLS certificate fingerprint.' }
    $port = Get-DesktopFreePort
    $start = New-DesktopSshStart ($baseArgs + @('-N','-o','ExitOnForwardFailure=yes','-L',"127.0.0.1:${port}:/run/remoteagents-desktop-rdp/rdp.socket",$destination))
    $start.RedirectStandardError = $true
    $tunnel = New-Object Diagnostics.Process; $tunnel.StartInfo = $start
    if (-not $tunnel.Start()) { throw 'Desktop SSH tunnel did not start.' }
    $errors = $tunnel.StandardError.ReadToEndAsync()
    Initialize-DesktopProbe
    $connected = $false
    for ($attempt=0; $attempt -lt 20; $attempt++) {
        if ($tunnel.HasExited) { throw "Desktop tunnel failed: $($errors.GetAwaiter().GetResult())" }
        if ([RemoteAgentsDesktopProbe]::Test($port,$fingerprint)) { $connected = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $connected) { throw 'RDP/TLS verification through the private tunnel failed.' }
    $rdpFile = Join-Path ([IO.Path]::GetTempPath()) ('remoteagents-desktop-' + [guid]::NewGuid().ToString('N') + '.rdp')
    Write-DesktopRdpFile $rdpFile $port $ServerUser
    Write-Output "Отпечаток сертификата SHA256: $fingerprint"
    Write-Output 'Windows может показать сертификат сервера. В окне Desktop (SSH) нажмите OK: пароль Linux не нужен.'
    $mstsc = Join-Path $env:WINDIR 'System32\mstsc.exe'
    $phase = 'открытие рабочего стола'
    [Console]::WriteLine('REMOTEAGENTS_DESKTOP_PROGRESS=Открытие окна рабочего стола Windows')
    Start-Process -FilePath $mstsc -ArgumentList ((Convert-DesktopSshArgument $rdpFile) + ' /public') | Out-Null
    if ($ManagedSession) {
        [Console]::Out.WriteLine("REMOTEAGENTS_DESKTOP_READY=127.0.0.1:$port")
        [Console]::Out.Flush()
        $stopRequest = [Console]::In.ReadLineAsync()
        while (-not $stopRequest.Wait(500)) {
            if ($tunnel.HasExited) { throw "Desktop tunnel stopped: $($errors.GetAwaiter().GetResult())" }
        }
    } else {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show('Оставьте это окно открытым во время работы. В окне Desktop (SSH) нажмите OK без ввода пароля. Здесь кнопка OK закрывает SSH-подключение; рабочий стол остаётся на сервере.','Рабочий стол сервера','OK','Information') | Out-Null
    }
    exit 0
} catch {
    [Console]::Error.WriteLine("Рабочий стол ($($phase)): $($_.Exception.Message)")
    if (-not $ManagedSession -and [Environment]::UserInteractive) {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Ошибка подключения','OK','Error') | Out-Null
    }
    exit 1
} finally {
    if ($tunnel) {
        if (-not $tunnel.HasExited) { $tunnel.Kill(); $tunnel.WaitForExit() }
        $tunnel.Dispose()
    }
    if ($rdpFile -and [IO.File]::Exists($rdpFile)) { [IO.File]::Delete($rdpFile) }
    if ($script:desktopCancelled) { $script:desktopCancelled.Dispose() }
}
