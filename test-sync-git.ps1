$ErrorActionPreference='Stop'
. "$PSScriptRoot\Sync.Workspace.ps1"
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ra-git-test-'+[guid]::NewGuid().ToString('N'))
$source=Join-Path $fixture 'source'
$oldGitConfig=$env:GIT_CONFIG_GLOBAL
New-Item -ItemType Directory -Path "$source\src","$source\node_modules","$source\nested" -Force|Out-Null
try {
    $env:GIT_CONFIG_GLOBAL=Join-Path $fixture 'empty-config'
    $emptyIgnore=Join-Path $fixture 'empty-ignore'
    [IO.File]::WriteAllText($emptyIgnore,'')
    [IO.File]::WriteAllText($env:GIT_CONFIG_GLOBAL,"[core]`n excludesfile = $($emptyIgnore.Replace('\','/'))`n autocrlf = false`n")
    & git -C $source init -q; if($LASTEXITCODE){throw 'git init failed'}
    # An unreachable arbitrary Git host must not be contacted for local seed.
    & git -C $source remote add origin https://git.example.invalid/team/project.git
    if($LASTEXITCODE){throw 'git remote fixture failed'}
    [IO.File]::WriteAllText("$source\.gitignore","ignored.js`n")
    [IO.File]::WriteAllText("$source\src\tracked.js",'tracked')
    [IO.File]::WriteAllText("$source\src\deleted.js",'deleted')
    & git -C $source add -- .gitignore src/tracked.js src/deleted.js
    if($LASTEXITCODE){throw 'git add fixture failed'}
    [IO.File]::WriteAllText("$source\src\new.py",'print(1)')
    [IO.File]::WriteAllText("$source\ignored.js",'ignored synthetic')
    # Synthetic decoys; their contents are never staged, opened, or hashed.
    [IO.File]::WriteAllText("$source\.env",'FAKE_ONLY')
    [IO.File]::WriteAllText("$source\node_modules\fake.js",'synthetic dependency')
    & git -C $source update-index --add --cacheinfo '100644,e69de29bb2d1d6434b8b29ae775ad8c2e48c5391,.env'
    & git -C $source update-index --add --cacheinfo '100644,e69de29bb2d1d6434b8b29ae775ad8c2e48c5391,node_modules/fake.js'
    & git -C "$source\nested" init -q
    [IO.File]::WriteAllText("$source\nested\foreign.js",'foreign')
    Remove-Item -LiteralPath "$source\src\deleted.js"
    if('src/new.py' -in @(Get-SyncInventory $source @('src')).path){throw 'Legacy extension policy changed'}
    $inventory=@(Get-SyncGitInventory $source -Hash)
    if(($inventory.path -join ',') -cne '.gitignore,src/new.py,src/tracked.js'){throw ('Git scope incorrect: '+($inventory.path -join ','))}
    $binding=New-RemoteSyncProject -DataDir "$fixture\state" -ProjectId demo -HostId host1 -SourcePath $source -ScopeMode git
    if($binding.allowedRoots.Count -ne 1 -or $binding.allowedRoots[0] -ne '.'){throw 'Root scope incorrect'}
    $realInvokeGit=${function:Invoke-SyncGit};$gitDeadlines=New-Object 'Collections.Generic.List[int]'
    function Invoke-SyncGit([string]$Root,[string[]]$Arguments,[int]$TimeoutMilliseconds=15000,[int]$MaxOutputCharacters=16777216) {
        $gitDeadlines.Add($TimeoutMilliseconds)
        & $realInvokeGit $Root $Arguments $TimeoutMilliseconds $MaxOutputCharacters
    }
    try {$seed=Export-RemoteSyncSeed "$fixture\state" demo host1}
    finally {Set-Item Function:\Invoke-SyncGit $realInvokeGit}
    if($gitDeadlines.Count -ne 2 -or @($gitDeadlines|Where-Object {$_ -ne 60000}).Count){throw 'Seed Git deadline did not reach both local inspections'}
    $manifest=Get-Content -LiteralPath $seed.manifestPath -Raw|ConvertFrom-Json
    if($manifest.scopeMode -ne 'git' -or $manifest.gitPaths.Count -ne 3){throw 'Git manifest missing'}
    $blocked=$false;try{Export-RemoteSyncSeed "$fixture\state" demo host1|Out-Null}catch{$blocked=$true}
    if(!$blocked){throw 'Repeated seed overwritten'}
    $blocked=$false;try{Get-SyncGitPaths "$source\src"|Out-Null}catch{$blocked=$true}
    if(!$blocked){throw 'Repository subfolder accepted'}
    New-Item -ItemType Directory -Path "$($binding.replicaPath)\src" -Force|Out-Null
    foreach($file in $inventory){Copy-Item -LiteralPath (Join-Path $source $file.path) -Destination (Join-Path $binding.replicaPath $file.path)}
    $health={ [pscustomobject]@{connected=$true;state='idle';sequence=1;needTotalItems=0;pullErrors=0;receiveOnlyTotalItems=0} }
    if(!(Test-RemoteSyncBarrier "$fixture\state" demo host1 $seed.manifestPath $health).ready){throw 'Git barrier failed'}
    [IO.File]::WriteAllText("$($binding.replicaPath)\src\extra.js",'extra')
    if((Test-RemoteSyncBarrier "$fixture\state" demo host1 $seed.manifestPath $health).ready){throw 'Extra file accepted'}
    # Reproduce the actual launcher: hidden PS5.1, an OPEN control stdin pipe,
    # and a background Console.ReadLine. Git must have its own closed stdin.
    $childCode=@'
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
Add-Type -TypeDefinition 'using System;using System.Threading;public class PipeReader {public static void Start(){var t=new Thread(()=>Console.ReadLine());t.IsBackground=true;t.Start();}}'
[PipeReader]::Start()
. (Join-Path $env:RA_TEST_MODULE 'Sync.Workspace.ps1')
$result=Invoke-SyncGit $env:RA_TEST_SOURCE @('rev-parse','--show-toplevel') 3000
if(!$result){throw 'Empty Git result'}
[Console]::WriteLine('GIT_PIPE_OK')
'@
    $childInfo=New-Object Diagnostics.ProcessStartInfo
    $childInfo.FileName=Join-Path $PSHOME powershell.exe
    $childInfo.Arguments='-NoProfile -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCode))
    $childInfo.EnvironmentVariables['RA_TEST_MODULE']=$PSScriptRoot;$childInfo.EnvironmentVariables['RA_TEST_SOURCE']=$source
    $childInfo.UseShellExecute=$false;$childInfo.CreateNoWindow=$true
    $childInfo.RedirectStandardInput=$true;$childInfo.RedirectStandardOutput=$true;$childInfo.RedirectStandardError=$true
    $child=[Diagnostics.Process]::Start($childInfo);$childHandle=$child.Handle
    try {
        $childOut=$child.StandardOutput.ReadToEndAsync();$childErr=$child.StandardError.ReadToEndAsync()
        if(!$child.WaitForExit(12000)){throw 'Managed Git hung on the control input pipe'}
        if($child.ExitCode -ne 0 -or $childOut.Result.Trim() -cne 'GIT_PIPE_OK'){throw ('Managed Git failed: '+$childErr.Result)}
    }finally{if(!$child.HasExited){$child.Kill();$child.WaitForExit()};$child.Dispose()}
    # Exercise real redirected pipes and process cleanup, not a mocked timeout.
    $fakeGit=Join-Path $fixture 'slow-git.exe'
    Add-Type -OutputAssembly $fakeGit -OutputType ConsoleApplication -TypeDefinition @'
using System;using System.IO;using System.Threading;
public class SyncGitFailureFixture {
    public static int Main() {
        File.WriteAllText(Environment.GetEnvironmentVariable("RA_GIT_TEST_PID"), System.Diagnostics.Process.GetCurrentProcess().Id.ToString());
        Console.Error.WriteLine("fixture-private-remote-must-not-appear");
        var mode=Environment.GetEnvironmentVariable("RA_GIT_TEST_MODE");
        if(mode=="failure")return 23;
        Console.Write(mode=="overflow" ? new string('x',8192) : "src/partial.js\0");Console.Out.Flush();
        Thread.Sleep(10000);return 0;
    }
}
'@
    $previousGit=$script:SyncGitExecutable;$previousPID=$env:RA_GIT_TEST_PID;$previousMode=$env:RA_GIT_TEST_MODE
    try {
        $script:SyncGitExecutable=$fakeGit;$env:RA_GIT_TEST_PID=Join-Path $fixture 'child-pid'
        foreach($mode in @('timeout','overflow','failure')) {
            $env:RA_GIT_TEST_MODE=$mode;$message='';$partial=@();$timer=[Diagnostics.Stopwatch]::StartNew()
            try {$partial=@(Invoke-SyncGit $source @('ls-files','--cached','-z') 1000 1024)}catch{$message=$_.Exception.Message}
            if(!$message -or $message -notmatch 'git ls-files' -or $message -match 'fixture-private-remote' -or $partial.Count){throw 'Git failure was partial, unlabelled or exposed stderr'}
            if($mode -eq 'timeout' -and ($message -notmatch '1000 ms' -or $timer.Elapsed.TotalSeconds -gt 5)){throw 'Git timeout was not bounded or lost its deadline'}
            if($mode -eq 'overflow' -and $message -notmatch 'output limit'){throw 'Oversized Git output accepted'}
            if($mode -eq 'failure' -and $message -notmatch 'exit 23'){throw 'Git exit code missing'}
            $childPID=[int][IO.File]::ReadAllText($env:RA_GIT_TEST_PID)
            if(Get-Process -Id $childPID -ErrorAction SilentlyContinue){throw 'Failed Git process was left running'}
        }
    } finally {$script:SyncGitExecutable=$previousGit;$env:RA_GIT_TEST_PID=$previousPID;$env:RA_GIT_TEST_MODE=$previousMode}
    'PASS: local Git seed without hosting access; scope/barrier; seed deadline; managed stdin regression; native timeout/overflow/exit diagnostics and process cleanup'
} finally {
    $env:GIT_CONFIG_GLOBAL=$oldGitConfig
    $resolved=[IO.Path]::GetFullPath($fixture)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup target'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
