[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$VPSHost,
    [Parameter(Mandatory=$true)][string]$VPSUser,
    [Parameter(Mandatory=$true)][string]$IdentityFile,
    [Parameter(Mandatory=$true)][string]$KnownHostsFile,
    [Parameter(Mandatory=$true)][string]$SSHConfig,
    [Parameter(Mandatory=$true)][string]$SSHExecutable,
    [Parameter(Mandatory=$true)][string]$AskpassExecutable,
    [Parameter(Mandatory=$true)][ValidateRange(1024,65535)][int]$LocalForwardPort,
    [Parameter(Mandatory=$true)][ValidateRange(1024,65535)][int]$ServerListenPort,
    [Parameter(Mandatory=$true)][ValidateRange(1024,65535)][int]$RemoteForwardPort,
    [Parameter(Mandatory=$true)][ValidateRange(1024,65535)][int]$WindowsListenPort,
    [switch]$ManagedSession
)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
function Convert-NativeArgument([string]$Value) {
    $escaped=[regex]::Replace($Value,'(\\*)"','$1$1\"')
    $escaped=[regex]::Replace($escaped,'(\\+)$','$1$1')
    '"' + $escaped + '"'
}
if(-not $ManagedSession){throw 'Этот компонент запускается из основной программы.'}
if($VPSHost -match '(^-|[\s\x00-\x1f])' -or $VPSUser -notmatch '^[a-zA-Z_][a-zA-Z0-9_.-]*[$]?$'){throw 'Неверные параметры подключения.'}
Add-Type -TypeDefinition @'
using System;using System.Threading;
public static class RemoteSyncTunnelControl {
 public static volatile bool StopRequested;
 public static void Start(){var t=new Thread(()=>{Console.ReadLine();StopRequested=true;});t.IsBackground=true;t.Start();}
}
'@
[RemoteSyncTunnelControl]::Start()
$cancel=$null
$process=$null
try {
    if($env:REMOTE_AGENTS_ASKPASS_CANCEL){$cancel=[Threading.EventWaitHandle]::OpenExisting($env:REMOTE_AGENTS_ASKPASS_CANCEL)}
    while(-not [RemoteSyncTunnelControl]::StopRequested) {
        if($cancel -and $cancel.WaitOne(0)){break}
        $arguments=@('-F',$SSHConfig,'-T','-i',$IdentityFile,'-l',$VPSUser,'-o',('UserKnownHostsFile='+$KnownHostsFile),'-o','StrictHostKeyChecking=yes','-o','IdentitiesOnly=yes','-o','PasswordAuthentication=no','-o','KbdInteractiveAuthentication=no','-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=3','-L',('127.0.0.1:'+$LocalForwardPort+':127.0.0.1:'+$ServerListenPort),'-R',('127.0.0.1:'+$RemoteForwardPort+':127.0.0.1:'+$WindowsListenPort),$VPSHost,'printf "%s\n" REMOTEAGENTS_SYNC_TUNNEL_READY; cat >/dev/null')
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$SSHExecutable
        $info.Arguments=(@($arguments|ForEach-Object{Convert-NativeArgument $_}) -join ' ')
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true
        $info.EnvironmentVariables['SSH_ASKPASS']=$AskpassExecutable
        $info.EnvironmentVariables['SSH_ASKPASS_REQUIRE']='force'
        $process=New-Object Diagnostics.Process
        $process.StartInfo=$info
        [void]$process.Start()
        $line=$process.StandardOutput.ReadLineAsync()
        $connected=$false
        while(-not [RemoteSyncTunnelControl]::StopRequested -and -not $process.HasExited) {
            if($cancel -and $cancel.WaitOne(0)){break}
            if($line.Wait(100)){
                if($line.Result -eq 'REMOTEAGENTS_SYNC_TUNNEL_READY'){
                    $connected=$true
                    Write-Output '{"state":"connected"}'
                    break
                }
                if($null -eq $line.Result){break}
                $line=$process.StandardOutput.ReadLineAsync()
            }
        }
        while($connected -and -not [RemoteSyncTunnelControl]::StopRequested -and -not $process.HasExited){
            if($cancel -and $cancel.WaitOne(0)){break}
            Start-Sleep -Milliseconds 200
        }
        if(-not $process.HasExited){
            $process.StandardInput.Close()
            if(-not $process.WaitForExit(3000)){$process.Kill();$process.WaitForExit()}
        }
        $process.Dispose();$process=$null
        if([RemoteSyncTunnelControl]::StopRequested -or ($cancel -and $cancel.WaitOne(0))){break}
        Write-Output '{"state":"disconnected"}'
        for($i=0;$i -lt 20 -and -not [RemoteSyncTunnelControl]::StopRequested;$i++){Start-Sleep -Milliseconds 100}
    }
    Write-Output '{"state":"stopped"}'
} finally {
    if($process){
        if(-not $process.HasExited){$process.Kill();$process.WaitForExit()}
        $process.Dispose()
    }
    if($cancel){$cancel.Dispose()}
}
