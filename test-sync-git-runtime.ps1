# Uses only a synthetic repository and a checksum-pinned official binary.
param([string]$Archive)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Sync.Workspace.ps1"
. "$PSScriptRoot\Sync.Runtime.ps1"
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ra-git-runtime-'+[guid]::NewGuid().ToString('N'))
$worker=$null;$oldGitConfig=$env:GIT_CONFIG_GLOBAL
New-Item -ItemType Directory -Path "$fixture\source" -Force|Out-Null
try {
    $env:GIT_CONFIG_GLOBAL=Join-Path $fixture 'config'
    [IO.File]::WriteAllText("$fixture\ignore",'')
    [IO.File]::WriteAllText($env:GIT_CONFIG_GLOBAL,"[core]`n excludesfile = $($fixture.Replace('\','/'))/ignore`n")
    & git -C "$fixture\source" init -q
    [IO.File]::WriteAllText("$fixture\source\app.js",'synthetic')
    $binary=Install-RemoteSyncBinary $fixture $Archive
    $binding=New-RemoteSyncProject $fixture demo a "$fixture\source" -ScopeMode git
    New-RemoteSyncProject $fixture demo b "$fixture\source" -ScopeMode git|Out-Null
    $a=Initialize-RemoteSyncWorker $fixture demo a $binary '' 29220 29221 29385
    $b=Initialize-RemoteSyncWorker $fixture demo b $binary '' 29222 29223 29386
    Initialize-RemoteSyncWorker $fixture demo a $binary $b.deviceId 29220 29221 29385|Out-Null
    # Generated private worker config is asserted internally; it is never printed.
    [xml]$config=[IO.File]::ReadAllText((Join-Path (Get-SyncStatePath $fixture demo a) 'worker\config.xml'))
    if($config.configuration.folder.type -ne 'receiveonly'){throw 'Git receiver must be receive-only'}
    $ignores=[IO.File]::ReadAllLines((Join-Path $binding.replicaPath '.stignore'))
    if('!/**' -notin $ignores -or '.git' -notin $ignores -or 'node_modules' -notin $ignores){throw 'Git receiver exclusion policy missing'}
    $worker=Start-RemoteSyncWorker $fixture demo a
    $health=$null
    for($attempt=0;$attempt -lt 30;$attempt++) {
        Start-Sleep -Milliseconds 250
        try { $health=Get-RemoteSyncLiveHealth $fixture demo a;break }catch{}
        if($worker.process.HasExited){throw 'Git receiver exited during startup'}
    }
    if(!$health){throw 'Git receiver API failed'}
    Resume-RemoteSyncFolder $fixture demo a|Out-Null
    Start-Sleep -Milliseconds 500
    $health=Get-RemoteSyncLiveHealth $fixture demo a
    if($health.connected -or $health.state -eq 'error'){throw 'Unpaired Git receiver did not fail closed'}
    'PASS: pinned binary, Git receive-only root, dependency/Git exclusions, live API and disconnected peer'
} finally {
    $env:GIT_CONFIG_GLOBAL=$oldGitConfig
    if($worker){try{Stop-RemoteSyncWorker $fixture demo a}catch{};if(!$worker.process.WaitForExit(5000)){$worker.process.Kill()}}
    $resolved=[IO.Path]::GetFullPath($fixture)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup target'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
