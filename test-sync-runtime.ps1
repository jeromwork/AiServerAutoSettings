param([Parameter(Mandatory)][string]$Archive)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Sync.Workspace.ps1"
. "$PSScriptRoot\Sync.Runtime.ps1"
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ra-sync-runtime-'+[guid]::NewGuid().ToString('N'))
$worker=$null
try {
    New-Item -ItemType Directory -Path "$fixture\source" -Force|Out-Null
    [IO.File]::WriteAllText("$fixture\source\app.js",'synthetic')
    $binary=Install-RemoteSyncBinary $fixture $Archive
    New-RemoteSyncProject $fixture fixture a "$fixture\source" @('app.js')|Out-Null
    New-RemoteSyncProject $fixture fixture b "$fixture\source" @('app.js')|Out-Null
    $a=Initialize-RemoteSyncWorker $fixture fixture a $binary '' 29220 29221 29385
    $b=Initialize-RemoteSyncWorker $fixture fixture b $binary '' 29222 29223 29386
    Initialize-RemoteSyncWorker $fixture fixture a $binary $b.deviceId 29220 29221 29385 | Out-Null
    $worker=Start-RemoteSyncWorker $fixture fixture a
    $health=$null
    for($attempt=0;$attempt -lt 20;$attempt++) {
        Start-Sleep -Milliseconds 250
        try {$health=Get-RemoteSyncLiveHealth $fixture fixture a;break}catch{}
        if($worker.process.HasExited){throw 'Worker exited during startup'}
    }
    if(!$health){throw 'Private API did not become ready'}
    if($health.connected){throw 'Unpaired remote peer unexpectedly connected'}
    Write-Output 'PASS: pinned archive, generated private worker, private API health, disconnected peer fails closed'
} finally {
    if($worker){try{Stop-RemoteSyncWorker $fixture fixture a}catch{};if(!$worker.process.WaitForExit(5000)){$worker.process.Kill()}}
    $resolved=[IO.Path]::GetFullPath($fixture)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup target'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
