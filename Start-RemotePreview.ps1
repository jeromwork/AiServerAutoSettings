[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$VPSHost,
    [Parameter(Mandatory=$true)][string]$VPSUser,
    [Parameter(Mandatory=$true)][string]$IdentityFile,
    [Parameter(Mandatory=$true)][string]$KnownHostsFile,
    [Parameter(Mandatory=$true)][string]$SSHConfig,
    [Parameter(Mandatory=$true)][string]$SSHExecutable,
    [Parameter(Mandatory=$true)][string]$AskpassExecutable,
    [Parameter(Mandatory=$true)][ValidateRange(1024,65535)][int]$ServerPort,
    [ValidateRange(1024,65535)][int]$LocalPort=3801,
    [switch]$ManagedSession
)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
function Quote-PreviewArgument([string]$Value) {
    '"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'
}
function Get-PreviewPort([int]$Preferred) {
    $probe=New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback),$Preferred
    try {$probe.Start();return $probe.LocalEndpoint.Port}
    catch {
        $probe.Stop();$probe=New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback),0
        $probe.Start();return $probe.LocalEndpoint.Port
    } finally {$probe.Stop()}
}
if(!$ManagedSession){throw 'Открывайте просмотр из основной программы.'}
if($VPSHost -match '(^-|[\s\x00-\x1f])' -or $VPSUser -notmatch '^[a-zA-Z_][a-zA-Z0-9_.-]*[$]?$'){throw 'Неверное подключение.'}
foreach($path in @($IdentityFile,$KnownHostsFile,$SSHConfig)){if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw 'Сначала настройте проверенное SSH-подключение.'}}
Add-Type -TypeDefinition @'
using System;using System.Threading;
public static class PreviewControl { public static volatile bool Stop; public static void Start(){var t=new Thread(()=>{Console.ReadLine();Stop=true;});t.IsBackground=true;t.Start();} }
'@
[PreviewControl]::Start()
$process=$null;$cancel=$null
try {
    if($env:REMOTE_AGENTS_ASKPASS_CANCEL){$cancel=[Threading.EventWaitHandle]::OpenExisting($env:REMOTE_AGENTS_ASKPASS_CANCEL)}
    for($attempt=0;$attempt -lt 3 -and ![PreviewControl]::Stop;$attempt++){
        $LocalPort=Get-PreviewPort $(if($attempt -eq 0){$LocalPort}else{0})
        $values=@('-F',$SSHConfig,'-T','-i',$IdentityFile,'-l',$VPSUser,'-o',('UserKnownHostsFile='+$KnownHostsFile),'-o','StrictHostKeyChecking=yes','-o','IdentitiesOnly=yes','-o','PasswordAuthentication=no','-o','KbdInteractiveAuthentication=no','-o','ExitOnForwardFailure=yes','-o','ConnectTimeout=10','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=3','-L',('127.0.0.1:'+$LocalPort+':127.0.0.1:'+$ServerPort),$VPSHost,'printf "%s\n" REMOTEAGENTS_PREVIEW_READY; cat >/dev/null')
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$SSHExecutable;$info.Arguments=(@($values|ForEach-Object{Quote-PreviewArgument $_}) -join ' ')
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $info.EnvironmentVariables['SSH_ASKPASS']=$AskpassExecutable;$info.EnvironmentVariables['SSH_ASKPASS_REQUIRE']='force'
        $process=New-Object Diagnostics.Process;$process.StartInfo=$info
        [void]$process.Start();$errors=$process.StandardError.ReadToEndAsync();$line=$process.StandardOutput.ReadLineAsync()
        $deadline=[DateTime]::UtcNow.AddMinutes(5);$ready=$false
        while(![PreviewControl]::Stop -and !$process.HasExited -and [DateTime]::UtcNow -lt $deadline){
            if($cancel -and $cancel.WaitOne(0)){break}
            if($line.Wait(100)){
                if($line.Result -eq 'REMOTEAGENTS_PREVIEW_READY'){$ready=$true;break}
                if($null -eq $line.Result){break};$line=$process.StandardOutput.ReadLineAsync()
            }
        }
        if($ready){
            [Console]::WriteLine((@{state='preview';url=('http://127.0.0.1:'+$LocalPort+'/');localPort=$LocalPort;serverPort=$ServerPort;serviceChecked=$false}|ConvertTo-Json -Compress))
            while(![PreviewControl]::Stop -and !$process.HasExited){if($cancel -and $cancel.WaitOne(0)){break};Start-Sleep -Milliseconds 100}
        }
        if(!$process.HasExited){$process.StandardInput.Close();if(!$process.WaitForExit(2000)){$process.Kill();$process.WaitForExit()}}
        $process.Dispose();$process=$null
        if($ready -or [PreviewControl]::Stop -or ($cancel -and $cancel.WaitOne(0))){break}
    }
    if(!$ready -and ![PreviewControl]::Stop){throw 'SSH-проброс не открыт. Проверьте подключение и повторите.'}
    [Console]::WriteLine('{"state":"stopped"}')
} finally {
    if($process){if(!$process.HasExited){$process.Kill();$process.WaitForExit()};$process.Dispose()}
    if($cancel){$cancel.Dispose()}
}
