$ErrorActionPreference='Stop'
$root=Join-Path $PSScriptRoot ('transport fixture '+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
try{
    $exe=Join-Path $root 'native stub.exe'
    Add-Type -OutputAssembly $exe -OutputType ConsoleApplication -TypeDefinition @'
using System;using System.IO;using System.Text;
class Program {static void Main(string[] args){
  var mode=Environment.GetEnvironmentVariable("REMOTEAGENTS_TEST_MODE");
  if(mode=="tunnel"){Console.WriteLine("REMOTEAGENTS_SYNC_TUNNEL_READY");Console.In.ReadToEnd();return;}
  if(mode=="upload"){using(var f=File.Create(Environment.GetEnvironmentVariable("REMOTEAGENTS_TEST_FILE")))Console.OpenStandardInput().CopyTo(f);return;}
  if(mode=="download"){Console.OpenStandardOutput().Write(new byte[]{0,255,10,128},0,4);return;}
  Console.OutputEncoding=new UTF8Encoding(false);Console.Write("UTF8: Привет\n");
}}
'@
    $c=[pscustomobject]@{sshExecutable=$exe;askpassExecutable='unused';arguments=@('-F','config with spaces','example.com')}
    $env:REMOTEAGENTS_TEST_MODE='exec'
    $r=& (Join-Path $PSScriptRoot 'Invoke-RemoteAgentsSsh.ps1') -Request @{action='exec';command='printf public';timeoutSec=5} -Connection $c -DataDir $root
    Assert (@($r).Count -eq 1 -and $r -is [pscustomobject] -and $r.exitCode -eq 0 -and $r.stdout -eq "UTF8: Привет`n") 'UTF8 exec failed'
    $bytes=[Text.Encoding]::UTF8.GetBytes("Привет`npublic`n")
    $file=Join-Path $root 'seed.zip';[IO.File]::WriteAllBytes($file,$bytes)
    $env:REMOTEAGENTS_TEST_MODE='upload';$env:REMOTEAGENTS_TEST_FILE=Join-Path $root 'received.bin'
    $remote='/home/remoteagents/.local/share/remote-agents-sync/p-test/h-test/seed.zip'
    $r=& (Join-Path $PSScriptRoot 'Invoke-RemoteAgentsSsh.ps1') -Request @{action='upload';localPath=$file;remotePath=$remote;timeoutSec=5} -Connection $c -DataDir $root
    Assert (@($r).Count -eq 1 -and $r -is [pscustomobject] -and $r.exitCode -eq 0 -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($env:REMOTEAGENTS_TEST_FILE)) -eq [Convert]::ToBase64String($bytes)) 'Binary upload changed bytes'
    $env:REMOTEAGENTS_TEST_MODE='download'
    $name='snapshot-'+[guid]::NewGuid().ToString('N')+'.json';$file=Join-Path $root $name
    $r=& (Join-Path $PSScriptRoot 'Invoke-RemoteAgentsSsh.ps1') -Request @{action='download';localPath=$file;remotePath=('/home/remoteagents/.local/share/remote-agents-sync/p-test/h-test/'+$name);timeoutSec=5} -Connection $c -DataDir $root
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) -eq 'AP8KgA==') 'Binary download changed bytes'
    $env:REMOTEAGENTS_TEST_MODE='tunnel'
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path $PSHOME 'powershell.exe'
    $info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'Start-RemoteSyncTunnel.ps1')+'" -VPSHost example.com -VPSUser root -IdentityFile unused -KnownHostsFile unused -SSHConfig unused -SSHExecutable "'+$exe+'" -AskpassExecutable unused -LocalForwardPort 21001 -ServerListenPort 21002 -RemoteForwardPort 21003 -WindowsListenPort 21004 -ManagedSession'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $p=[Diagnostics.Process]::Start($info)
    try{
        $line=$p.StandardOutput.ReadLineAsync();Assert ($line.Wait(10000) -and $line.Result -eq '{"state":"connected"}') 'Tunnel readiness failed'
        $p.StandardInput.WriteLine('stop');$p.StandardInput.Close()
        Assert ($p.WaitForExit(10000) -and $p.ExitCode -eq 0) 'Tunnel stop failed'
    }finally{if(-not $p.HasExited){$p.Kill();$p.WaitForExit()};$p.Dispose()}
    # The real standalone project entry uses fake orchestration, real native transport/tunnel.
    foreach($name in @('Connect-RemoteAgentsProject.ps1','Invoke-RemoteAgentsSsh.ps1','Start-RemoteSyncTunnel.ps1','Invoke-RemoteSyncGuard.ps1','setup-vps-ssh.ps1')){[IO.File]::Copy((Join-Path $PSScriptRoot $name),(Join-Path $root $name))}
    [IO.File]::WriteAllText((Join-Path $root 'Sync.Workspace.ps1'),'# fixture')
    [IO.File]::WriteAllText((Join-Path $root 'Sync.Runtime.ps1'),'function Stop-RemoteSyncWorker {param($DataDir,$ProjectId,$HostId)}')
    $fixture=@'
function Connect-RemoteSyncProject {
param($DataDir,$ProjectId,$HostId,$SSHTransport,$TunnelHook)
$r=& $SSHTransport @{action='exec';command='public fixture';timeoutSec=5}
if($r.exitCode -ne 0){throw 'transport fixture'}
$t=& $TunnelHook @{localForwardPort=21001;serverListenPort=21002;remoteForwardPort=21003;windowsListenPort=21004}
if(-not $t.ok){throw 'tunnel fixture'}
[pscustomobject]@{ready=$true;fresh=$true;projectId=$ProjectId;hostId=$HostId;replicaPath=$DataDir;snapshotId='fixture'}
}
function Invoke-RemoteSyncBarrier {
param($DataDir,$ProjectId,$HostId,$SSHTransport,$TimeoutSec)
[pscustomobject]@{ready=$true;fresh=$true;projectId=$ProjectId;hostId=$HostId;replicaPath=$DataDir;snapshotId='fresh-fixture'}
}
'@
    [IO.File]::WriteAllText((Join-Path $root 'Sync.Orchestrator.ps1'),$fixture)
    $context=@{sshExecutable=$exe;askpassExecutable='unused';arguments=@('example.com');serverAddress='example.com';login='root';keyPath='unused';knownHostsPath='unused';configPath='unused'}
    [IO.File]::WriteAllText((Join-Path $root 'ssh-transport.json'),($context|ConvertTo-Json))
    $info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $root 'Connect-RemoteAgentsProject.ps1')+'" -DataDir "'+$root+'" -ProjectId p-test -HostId h-test -ManagedSession'
    $p=[Diagnostics.Process]::Start($info)
    try{
        $line=$p.StandardOutput.ReadLineAsync();Assert ($line.Wait(15000)) 'Project entry timed out'
        if(-not $line.Result -or ($line.Result|ConvertFrom-Json).state -ne 'project-ready'){throw ('Project entry failed: '+$p.StandardError.ReadToEnd())}
        $p.StandardInput.WriteLine('stop');$p.StandardInput.Close()
        Assert ($p.WaitForExit(10000) -and $p.ExitCode -eq 0) 'Project entry cleanup failed'
    }finally{if(-not $p.HasExited){$p.Kill();$p.WaitForExit()};$p.Dispose()}
    $info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $root 'Invoke-RemoteSyncGuard.ps1')+'"'
    $p=[Diagnostics.Process]::Start($info)
    try{
        $inputJson=@{dataDir=$root;projectId='p-test';hostId='h-test';replicaPath=$root;requestId='request-fixture'}|ConvertTo-Json -Compress
        $inputBytes=[Text.Encoding]::UTF8.GetBytes($inputJson+"`n");$p.StandardInput.BaseStream.Write($inputBytes,0,$inputBytes.Length);$p.StandardInput.BaseStream.Flush();$p.StandardInput.Close()
        Assert ($p.WaitForExit(10000)) 'Fresh guard timed out'
        $r=$p.StandardOutput.ReadToEnd()|ConvertFrom-Json
        Assert ($p.ExitCode -eq 0 -and $r.ready -and $r.fresh -and $r.requestId -eq 'request-fixture' -and $r.snapshotId -eq 'fresh-fixture') 'Fresh guard binding failed'
    }finally{if(-not $p.HasExited){$p.Kill();$p.WaitForExit()};$p.Dispose()}
    'PASS: Windows PS5.1 native UTF8/LF, binary upload/download, path spaces, managed tunnel ready/stop; no SSH/network.'
}finally{
    Remove-Item Env:REMOTEAGENTS_TEST_MODE,Env:REMOTEAGENTS_TEST_FILE -ErrorAction SilentlyContinue
    if([IO.Path]::GetDirectoryName($root) -eq $PSScriptRoot){Remove-Item -LiteralPath $root -Recurse -Force}
}
