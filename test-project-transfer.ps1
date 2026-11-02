$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Sync.Workspace.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('ra-transfer-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$saved=@{};foreach($name in @('RA_TRANSFER_ROOT','RA_TRANSFER_MODE','RA_TRANSFER_HASH')){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
function Assert($value,$message){if(!$value){throw $message}}
try {
    $exe=Join-Path $root 'ssh-fixture.exe'
    Add-Type -OutputAssembly $exe -OutputType ConsoleApplication -TypeDefinition @'
using System;using System.IO;using System.Text;using System.Threading;using System.Security.Cryptography;
class TransferFixture {
    static string Hash(string path){using(var sha=SHA256.Create())using(var f=File.OpenRead(path))return BitConverter.ToString(sha.ComputeHash(f)).Replace("-","").ToLowerInvariant();}
    public static int Main(string[] args){
        var root=Environment.GetEnvironmentVariable("RA_TRANSFER_ROOT");var mode=Environment.GetEnvironmentVariable("RA_TRANSFER_MODE");
        var command=String.Join(" ",args);var part=Path.Combine(root,"partial.bin");var target=Path.Combine(root,"received.bin");
        Console.OutputEncoding=new UTF8Encoding(false);
        if(command.Contains("REMOTEAGENTS_SEED_PROBE")){
            File.WriteAllText(Path.Combine(root,"probe.sh"),args[args.Length-1],new UTF8Encoding(false));
            if(File.Exists(target)&&Hash(target)==Environment.GetEnvironmentVariable("RA_TRANSFER_HASH"))Console.Write("complete");
            else Console.Write(File.Exists(part)?new FileInfo(part).Length:0);return 0;
        }
        if(command.Contains("REMOTEAGENTS_SEED_UPLOAD")){
            File.WriteAllText(Path.Combine(root,"upload.sh"),args[args.Length-1],new UTF8Encoding(false));
            if(mode=="stall"){Thread.Sleep(10000);return 9;}
            using(var output=new FileStream(part,FileMode.Append))using(var input=Console.OpenStandardInput()){
                var buffer=new byte[8192];int count;long done=0;
                while((count=input.Read(buffer,0,buffer.Length))>0){output.Write(buffer,0,count);output.Flush();done+=count;Thread.Sleep(20);
                    if(mode=="disconnect"&&done>=131072)return 7;
                }
            }
            if(Hash(part)!=Environment.GetEnvironmentVariable("RA_TRANSFER_HASH"))return 65;
            File.Move(part,target);return 0;
        }
        if(mode=="heartbeat"){
            for(int i=0;i<12;i++){Console.Error.WriteLine("REMOTEAGENTS_PROJECT_HEARTBEAT");Thread.Sleep(150);}
            Console.Error.WriteLine("REMOTEAGENTS_PROJECT_PROGRESS={\"stage\":\"extract\",\"message\":\"fixture\",\"doneBytes\":5368709120,\"totalBytes\":10737418240,\"doneFiles\":1,\"totalFiles\":2}");
            Thread.Sleep(100);Console.Write("ok");return 0;
        }
        Thread.Sleep(10000);return 0;
    }
}
'@
    $env:RA_TRANSFER_ROOT=$root;$env:RA_TRANSFER_MODE='disconnect'
    $file=Join-Path $root 'seed.zip';$bytes=New-Object byte[] 4194304
    $random=[Security.Cryptography.RandomNumberGenerator]::Create();try{$random.GetBytes($bytes)}finally{$random.Dispose()}
    [IO.File]::WriteAllBytes($file,$bytes);$env:RA_TRANSFER_HASH=Get-SyncSHA256 $file
    $connection=[pscustomobject]@{sshExecutable=$exe;arguments=@('fixture.invalid');askpassExecutable='unused'}
    $updates=New-Object 'Collections.Generic.List[object]';$callback={param($update)$updates.Add($update)}
    $request=@{action='upload';localPath=$file;remotePath='/home/remoteagents/.local/share/remote-agents-sync/p-fixture/h-fixture/seed.zip';resume=$true;sha256=$env:RA_TRANSFER_HASH;timeoutSec=40;idleTimeoutSec=5;longRunning=$true;stage='upload';message='fixture upload';progress=$callback}
    $failed=$false
    try{$result=& "$PSScriptRoot\Invoke-RemoteAgentsSsh.ps1" -Request $request -Connection $connection -DataDir $root;$failed=$result.exitCode -ne 0}catch{$failed=$true}
    Assert $failed 'Disconnect was accepted'
    $partial=(Get-Item -LiteralPath (Join-Path $root 'partial.bin')).Length
    Assert ($partial -gt 0 -and $partial -lt $bytes.Length) 'Partial upload was not retained'
    Assert (@($updates|Where-Object {$_.totalBytes -gt 0 -and $_.doneBytes -ge $_.totalBytes}).Count -eq 0) 'Failed upload showed completion'
    $env:RA_TRANSFER_MODE='slow';$updates.Clear();$timer=[Diagnostics.Stopwatch]::StartNew()
    $result=& "$PSScriptRoot\Invoke-RemoteAgentsSsh.ps1" -Request $request -Connection $connection -DataDir $root
    Assert ($result.exitCode -eq 0 -and $result.resumedBytes -eq $partial) ('Upload restarted instead of resuming: '+($result|ConvertTo-Json -Compress)+'; expected '+$partial)
    Assert ($timer.Elapsed.TotalSeconds -gt 5 -and $updates.Count -ge 3) 'Slow transfer did not remain active beyond idle limit'
    Assert ((Get-SyncSHA256 (Join-Path $root 'received.bin')) -ceq $env:RA_TRANSFER_HASH) 'Resumed binary payload differs'
    Assert ($updates[$updates.Count-1].doneBytes -eq $bytes.Length) 'Verified upload did not finish at 100 percent'
    $result=& "$PSScriptRoot\Invoke-RemoteAgentsSsh.ps1" -Request $request -Connection $connection -DataDir $root
    Assert ($result.transferredBytes -eq 0 -and $result.resumedBytes -eq $bytes.Length) 'Complete verified archive was retransmitted'
    $bash=Join-Path ${env:ProgramFiles} 'Git\bin\bash.exe'
    if(Test-Path -LiteralPath $bash){
        foreach($name in @('probe.sh','upload.sh')){& $bash -n ((Join-Path $root $name).Replace('\','/'));Assert ($LASTEXITCODE -eq 0) 'Generated resume/heartbeat shell syntax failed'}
        # Execute the transmitted nested Bash script, not just the outer wrapper
        # and not the marker-based native emulator. This catches CRLF here-strings.
        $envelope=[IO.File]::ReadAllText((Join-Path $root 'probe.sh'))
        $begin=$envelope.IndexOf('bash -c ')+8;$end=$envelope.IndexOf('; elif [',$begin)
        Assert ($begin -ge 8 -and $end -gt $begin) 'Cannot extract generated Bash argument'
        $quoted=$envelope.Substring($begin,$end-$begin)
        $single=[string][char]39;$double=[string][char]34
        $script=$quoted.Substring(1,$quoted.Length-2).Replace(($single+$double+$single+$double+$single),$single)
        Assert (!$script.Contains("`r")) 'Windows CRLF reached the remote Bash script'
        $bashDirectory=Join-Path $root 'actual-bash';[void][IO.Directory]::CreateDirectory($bashDirectory)
        $bashPath=$bashDirectory.Replace('\','/');$bashPath='/'+$bashPath.Substring(0,1).ToLowerInvariant()+$bashPath.Substring(2)
        $script=$script.Replace($request.remotePath,($bashPath+'/seed.zip'))
        $scriptFile=Join-Path $root 'actual-probe.sh';[IO.File]::WriteAllText($scriptFile,$script,(New-Object Text.UTF8Encoding($false)))
        $out=& $bash ($scriptFile.Replace('\','/'));Assert ($LASTEXITCODE -eq 0 -and "$out" -ceq '0') 'Actual Bash rejected empty resume probe'
        [IO.File]::Copy($file,(Join-Path $bashDirectory 'seed.zip'))
        $out=& $bash ($scriptFile.Replace('\','/'));Assert ($LASTEXITCODE -eq 0 -and "$out" -ceq 'complete') 'Actual Bash did not recognize verified complete archive'
        $partialFile=Join-Path $bashDirectory ('seed.zip.part-'+$env:RA_TRANSFER_HASH)
        [IO.File]::Move((Join-Path $bashDirectory 'seed.zip'),$partialFile)
        $stream=[IO.File]::OpenWrite($partialFile);try{$stream.SetLength(64)}finally{$stream.Dispose()}
        $out=& $bash ($scriptFile.Replace('\','/'));Assert ($LASTEXITCODE -eq 0 -and [long]$out -eq 64) 'Actual Bash did not return partial archive offset'
    }
    $env:RA_TRANSFER_MODE='heartbeat';$updates.Clear()
    $result=& "$PSScriptRoot\Invoke-RemoteAgentsSsh.ps1" -Request @{action='exec';command='fixture';timeoutSec=20;idleTimeoutSec=1;longRunning=$true;progress=$callback;stage='extract'} -Connection $connection -DataDir $root
    Assert ($result.exitCode -eq 0 -and $result.stderr -eq '' -and @($updates|Where-Object {$_.doneBytes -eq 5368709120}).Count -eq 1) 'Heartbeat/64-bit remote progress parsing failed'
    $env:RA_TRANSFER_MODE='quiet';$failed=$false;$timer.Restart()
    try{& "$PSScriptRoot\Invoke-RemoteAgentsSsh.ps1" -Request @{action='exec';command='fixture';timeoutSec=20;idleTimeoutSec=1;stage='idle-test'} -Connection $connection -DataDir $root|Out-Null}catch{$failed=$_.Exception.Message -like '*idle-test*'}
    Assert ($failed -and $timer.Elapsed.TotalSeconds -lt 5) 'Inactive process was not stopped by idle timeout'
    # The actual managed reader must render progress (including values > 4 GiB).
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'setup-vps-ssh.ps1'),[ref]$null,[ref]$null)
    foreach($name in @('Convert-SshArgument','Initialize-ManagedOutput','Start-ManagedComponent','Stop-ManagedComponent')){
        $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        . ([scriptblock]::Create($node.Extent.Text))
    }
    $child=Join-Path $root 'progress-child.ps1'
    [IO.File]::WriteAllText($child,@'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
[Console]::WriteLine('{"state":"project-progress","stage":"upload","message":"fixture upload","doneBytes":5368709120,"totalBytes":10737418240,"doneFiles":1,"totalFiles":2}')
Start-Sleep -Milliseconds 350
[Console]::WriteLine('{"state":"project-ready"}')
[Console]::ReadLine()|Out-Null
'@,(New-Object Text.UTF8Encoding($true)))
    $script:managed=$null
    try{$rendered=@(& {$script:managed=Start-ManagedComponent $child @() 'project-ready'} 6>&1);Assert (($rendered|Out-String) -match '50%') 'Managed launcher hid the transfer percentage'}
    finally{if($script:managed){Stop-ManagedComponent $script:managed}}
    # A real private Win32 console must reuse one row and erase shorter updates.
    $typeSource=$ast.Find({param($n)($n -is [Management.Automation.Language.ExpandableStringExpressionAst] -or $n -is [Management.Automation.Language.StringConstantExpressionAst]) -and $n.Value.Contains('class ConsoleStatusLine')},$true)
    Assert ($null -ne $typeSource) 'Console progress source missing'
    $consoleHarness=@'
public class ProgressConsoleFixture {
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] struct Coord {public short X;public short Y;}
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]static extern bool AllocConsole();
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]static extern bool FreeConsole();
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]static extern System.IntPtr GetConsoleWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")]static extern bool ShowWindow(System.IntPtr h,int mode);
    [System.Runtime.InteropServices.DllImport("kernel32.dll",CharSet=System.Runtime.InteropServices.CharSet.Unicode)]static extern System.IntPtr CreateFileW(string path,uint access,uint share,System.IntPtr security,uint disposition,uint flags,System.IntPtr template);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]static extern bool SetStdHandle(int which,System.IntPtr h);
    [System.Runtime.InteropServices.DllImport("kernel32.dll",CharSet=System.Runtime.InteropServices.CharSet.Unicode)]static extern bool ReadConsoleOutputCharacterW(System.IntPtr h,char[] text,uint length,Coord position,out uint read);
    public static int Main(string[] args){
        try {
            FreeConsole();if(!AllocConsole())throw new System.Exception("No private console");ShowWindow(GetConsoleWindow(),0);
            var handle=CreateFileW("CONOUT$",0xC0000000,3,System.IntPtr.Zero,3,0,System.IntPtr.Zero);SetStdHandle(-11,handle);SetStdHandle(-12,handle);
            System.Console.SetOut(new System.IO.StreamWriter(System.Console.OpenStandardOutput()){AutoFlush=true});
            using(var line=new RemoteAgents.ConsoleStatusLine()){
                if(!line.Write("files 1000/1000",true))throw new System.Exception("Interactive row unavailable");
                int row=System.Console.CursorTop;
                if(!line.Write("files 2/10",false)||System.Console.CursorTop!=row)throw new System.Exception("Progress appended another row");
                var text=new char[40];uint count;
                if(!ReadConsoleOutputCharacterW(handle,text,40,new Coord{X=0,Y=(short)row},out count))throw new System.Exception("Cannot read private console");
                var visible=new string(text,0,(int)count);
                if(!visible.StartsWith("files 2/10 ")||visible.Contains("1000"))throw new System.Exception("Old counter tail was not erased");
                line.Write("archive 0%",true);if(System.Console.CursorTop!=row+1)throw new System.Exception("Stage did not finish previous row");
                line.Write("archive 100%",false);if(System.Console.CursorTop!=row+1)throw new System.Exception("Stage counter scrolled");
                line.End();if(System.Console.CursorTop!=row+2)throw new System.Exception("Final prompt row missing");
            }
            System.IO.File.WriteAllText(args[0],"PASS");return 0;
        }catch(System.Exception error){System.IO.File.WriteAllText(args[0],error.ToString());return 1;}finally{FreeConsole();}
    }
}
'@
    $consoleExe=Join-Path $root 'console-progress.exe';$consoleResult=Join-Path $root 'console-result.txt'
    Add-Type -OutputAssembly $consoleExe -OutputType ConsoleApplication -TypeDefinition ($typeSource.Value+"`n"+$consoleHarness)
    $consoleInfo=New-Object Diagnostics.ProcessStartInfo
    $consoleInfo.FileName=$consoleExe;$consoleInfo.Arguments='"'+$consoleResult+'"';$consoleInfo.UseShellExecute=$false;$consoleInfo.CreateNoWindow=$true
    $consoleChild=[Diagnostics.Process]::Start($consoleInfo)
    try{Assert ($consoleChild.WaitForExit(10000)) 'Private console test timed out';Assert ($consoleChild.ExitCode -eq 0 -and [IO.File]::ReadAllText($consoleResult) -eq 'PASS') ('Single-row console failed: '+[IO.File]::ReadAllText($consoleResult))}
    finally{if(!$consoleChild.HasExited){$consoleChild.Kill();$consoleChild.WaitForExit()};$consoleChild.Dispose()}
    # Real orchestration + seed/barrier, replacing only network and worker API.
    $module=New-Module -ArgumentList $PSScriptRoot -ScriptBlock {
        param($moduleRoot)
        . (Join-Path $moduleRoot 'Sync.Workspace.ps1');. (Join-Path $moduleRoot 'Sync.Runtime.ps1');. (Join-Path $moduleRoot 'Sync.Orchestrator.ps1')
        function Install-RemoteSyncBinary {param($DataDir,$DownloadedArchive) if($script:failInstall){throw 'fixture install interrupted'};'fixture.exe'}
        function Initialize-RemoteSyncWorker {param($DataDir,$ProjectId,$HostId,$Executable,$PeerDeviceId,$ListenPort,$PeerTunnelPort,$GuiPort) [pscustomobject]@{deviceId=('A'*63)}}
        function Resume-RemoteSyncFolder {param($DataDir,$ProjectId,$HostId)}
        function Get-RemoteSyncLiveHealth {
            param($DataDir,$ProjectId,$HostId)
            $script:healthCalls++;$busy=$script:healthCalls -lt 3
            [pscustomobject]@{connected=$true;state=$(if($busy){'syncing'}else{'idle'});sequence=1;needTotalItems=$([int]$busy);pullErrors=0;receiveOnlyTotalItems=0;globalBytes=14L;needBytes=$(if($busy){14L}else{0L});receivedBytes=$script:healthCalls*100L}
        }
    }
    & $module {
        param($fixture)
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'source'))
        [IO.File]::WriteAllText((Join-Path $fixture 'source\app.js'),'public fixture')
        $binding=New-RemoteSyncProject (Join-Path $fixture 'state') p-flow h-flow (Join-Path $fixture 'source') @('app.js')
        $script:requests=New-Object 'Collections.Generic.List[object]';$script:serverState='empty';$script:failInstall=$true;$script:healthCalls=0
        $transport={param($r)
            $script:requests.Add($r);$stdout=''
            if($r.action -eq 'exec' -and $r.command -like '*echo configured*'){$stdout=$script:serverState}
            elseif($r.action -eq 'exec' -and $r.command -like '*server-sync.py seed --*'){$script:serverState='seeded'}
            elseif($r.action -eq 'exec' -and $r.command -like '*server-sync-runtime.py identity*'){$stdout=@{deviceId=('B'*63)}|ConvertTo-Json -Compress}
            elseif($r.action -eq 'download'){
                $state=Get-SyncStatePath (Join-Path $fixture 'state') p-flow h-flow
                $snapshot=Get-Content -LiteralPath (Join-Path $state 'seed-manifest.json') -Raw
                [IO.File]::WriteAllText($r.localPath,$snapshot)
                [void][IO.Directory]::CreateDirectory($binding.replicaPath)
                [IO.File]::WriteAllText((Join-Path $binding.replicaPath 'app.js'),'public fixture')
            }
            [pscustomobject]@{exitCode=0;stdout=$stdout;stderr=''}
        }
        $updates=New-Object 'Collections.Generic.List[object]';$progress={param($update)$updates.Add($update)}
        $stopped=$false
        try{Connect-RemoteSyncProject (Join-Path $fixture 'state') p-flow h-flow $transport { @{ok=$true} } -Progress $progress|Out-Null}catch{$stopped=$_.Exception.Message -eq 'fixture install interrupted'}
        if(!$stopped -or $script:serverState -ne 'seeded'){throw 'Fixture did not interrupt after successful server seed'}
        $seedRequests=@($script:requests|Where-Object {$_.action -eq 'upload' -and $_.localPath -like '*seed.zip'})
        if($seedRequests.Count -ne 1 -or !$seedRequests[0].resume -or $seedRequests[0].timeoutSec -ne 43200 -or $seedRequests[0].idleTimeoutSec -ne 300){throw 'Seed upload has short/missing transfer budgets or no resume'}
        $script:requests.Clear();$script:failInstall=$false
        $result=Connect-RemoteSyncProject (Join-Path $fixture 'state') p-flow h-flow $transport { @{ok=$true} } -Progress $progress
        if(!$result.ready -or !$result.fresh){throw ('Resumed orchestration did not verify real replica: '+$result.reason)}
        if(@($script:requests|Where-Object {$_.action -eq 'upload' -and $_.localPath -like '*seed.zip'}).Count){throw 'Completed server seed was resent'}
        $scan=@($script:requests|Where-Object {$_.action -eq 'exec' -and $_.command -like '*server-sync-runtime.py scan*'})
        if($scan.Count -ne 1 -or $scan[0].timeoutSec -ne 43200 -or $scan[0].command -notlike '*--operation-timeout 43200*'){throw 'Initial server scan kept a short timeout'}
        $script:requests.Clear()
        $guard=Invoke-RemoteSyncBarrier (Join-Path $fixture 'state') p-flow h-flow $transport -TimeoutSec 1
        if(!$guard.ready -or @($script:requests|Where-Object {$_.timeoutSec -gt 30}).Count){throw 'Per-command barrier lost its short budgets'}
        foreach($stage in @('server','inventory','archive','archive-checksum','sync-install','tunnel','snapshot','receive','verify')){if($stage -notin @($updates.stage)){throw ('Missing project stage: '+$stage)}}
    } (Join-Path $root 'orchestration')
    'PASS: native disconnect/resume/hash, verified reuse, slow active transfer, heartbeat/idle, 64-bit progress and real managed console rendering; no SSH/network'
}finally{
    foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
    $checked=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$checked.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe transfer fixture cleanup'}
    if(Test-Path -LiteralPath $checked){Remove-Item -LiteralPath $checked -Recurse -Force}
}
