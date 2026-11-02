$ErrorActionPreference='Stop'
. "$PSScriptRoot\Sync.Workspace.ps1"
. "$PSScriptRoot\Sync.Runtime.ps1"
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ra-sync-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$fixture\source\src","$fixture\source\node_modules","$fixture\source\src\cache" -Force|Out-Null
try {
    [IO.File]::WriteAllText("$fixture\source\src\app.js","console.log('synthetic');`n")
    # Synthetic decoys only. Never touches real project secrets.
    [IO.File]::WriteAllText("$fixture\source\src\.env",'FAKE_ONLY=not-a-secret')
    [IO.File]::WriteAllText("$fixture\source\src\credentials.json",'{"fake":true}')
    [IO.File]::WriteAllText("$fixture\source\src\cache\app.js",'fake-cache')
    $inventory=@(Get-SyncInventory "$fixture\source" @('src'))
    if($inventory.Count -ne 1 -or $inventory[0].path -ne 'src/app.js'){throw 'Exclusions failed'}
    $binding=New-RemoteSyncProject -DataDir "$fixture\state" -ProjectId demo -HostId host1 -SourcePath "$fixture\source" -AllowedRoots src
    $seed=Export-RemoteSyncSeed "$fixture\state" demo host1
    if($seed.fileCount -ne 1){throw 'Seed count failed'}
    $cachedSeed=Get-RemoteSyncPreparedSeed "$fixture\state" demo host1
    if(!$cachedSeed.cached -or $cachedSeed.sha256 -cne $seed.sha256){throw 'Prepared archive index was not reused'}
    $realHash=${function:Get-SyncSHA256};$forbiddenArchive=$seed.archivePath
    function Get-SyncSHA256([string]$LiteralPath,[scriptblock]$OnChunk){if($LiteralPath -ceq $forbiddenArchive){throw 'Cached archive was unnecessarily read'};& $realHash $LiteralPath $OnChunk}
    try{Get-RemoteSyncPreparedSeed "$fixture\state" demo host1|Out-Null}
    finally{Set-Item Function:\Get-SyncSHA256 $realHash}
    [IO.File]::WriteAllText((Join-Path (Get-SyncStatePath "$fixture\state" demo host1) 'seed-index.json'),'invalid interrupted index')
    $repaired=Get-RemoteSyncPreparedSeed "$fixture\state" demo host1
    if($repaired.cached -or $repaired.sha256 -cne $seed.sha256){throw 'Broken index was trusted or could not be rebuilt'}
    New-Item -ItemType Directory -Path ($binding.replicaPath+'\src') -Force|Out-Null
    Copy-Item -LiteralPath "$fixture\source\src\app.js" -Destination ($binding.replicaPath+'\src\app.js')
    $goodHealth={ [pscustomobject]@{connected=$true;state='idle';sequence=1;needTotalItems=0;pullErrors=0;receiveOnlyTotalItems=0} }
    $barrier=Test-RemoteSyncBarrier "$fixture\state" demo host1 $seed.manifestPath $goodHealth
    if(!$barrier.ready){throw ('Good barrier rejected: '+$barrier.reason)}
    [IO.File]::WriteAllText(($binding.replicaPath+'\src\app.js'),'local-change')
    if((Test-RemoteSyncBarrier "$fixture\state" demo host1 $seed.manifestPath $goodHealth).ready){throw 'Hash mismatch accepted'}
    if((Test-RemoteSyncBarrier "$fixture\state" demo host1 $seed.manifestPath).ready){throw 'No health accepted'}
    $denied=$false;try{Get-SyncInventory "$fixture\source" @('..\source')|Out-Null}catch{$denied=$true};if(!$denied){throw 'Traversal accepted'}
    $duplicate=$false;try{New-RemoteSyncProject "$fixture\state" demo host1 "$fixture\source" @('src')|Out-Null}catch{$duplicate=$true};if(!$duplicate){throw 'Duplicate binding accepted'}
    if(!(Test-Path -LiteralPath "$fixture\source\src\.env")){throw 'Source changed'}
    $retry=New-RemoteSyncProject "$fixture\retry-state" retry host1 "$fixture\source" @('src')
    $retryState=Get-SyncStatePath "$fixture\retry-state" retry host1
    $updates=New-Object 'Collections.Generic.List[object]'
    $cancelBuild={param($update)$updates.Add($update);if($update.stage -eq 'archive' -and $update.doneBytes -gt 0){throw 'synthetic interruption'}}
    $stopped=$false;try{Export-RemoteSyncSeed "$fixture\retry-state" retry host1 -Progress $cancelBuild|Out-Null}catch{$stopped=$_.Exception.Message -eq 'synthetic interruption'}
    if(!$stopped -or (Test-Path -LiteralPath (Join-Path $retryState 'seed-manifest.json'))){throw 'Interrupted build was committed'}
    # An archive left by an older interrupted version must not block retry or
    # be overwritten silently. Only its own staging state may be moved.
    [IO.File]::WriteAllText((Join-Path $retryState 'seed.zip'),'incomplete fixture')
    $retrySeed=Export-RemoteSyncSeed "$fixture\retry-state" retry host1 -Progress {param($update)$updates.Add($update)}
    if(!(Test-Path -LiteralPath $retrySeed.manifestPath) -or @(Get-ChildItem -LiteralPath $retryState -Filter 'seed-incomplete-*.zip').Count -ne 1){throw 'Seed retry failed to preserve old incomplete artifact'}
    if(@(Get-ChildItem -LiteralPath $retryState -Filter '*building*').Count -or @($updates|Where-Object {$_.stage -eq 'archive' -and $_.totalBytes -gt 0}).Count -eq 0){throw 'Seed progress or staging cleanup missing'}
    # Reproduce the real installer's nested profile/computer/project layout.
    # Its state directory fits MAX_PATH, but unique staging files do not.
    $longProject='p-'+[guid]::NewGuid().ToString('N');$longHost=[guid]::NewGuid().ToString('N')
    $suffix="\sync\projects\$longProject\$longHost"
    $longData=Join-Path $fixture ('d'*(221-$suffix.Length-$fixture.Length-1))
    $longSource=Join-Path $fixture 'long-source'
    $relative=(1..5|ForEach-Object {'nested'+('x'*34)}) -join '/';$relative+='/app.js'
    $sourceFile=Join-Path $longSource $relative
    [void][IO.Directory]::CreateDirectory((ConvertTo-RemoteAgentsIOPath ([IO.Path]::GetDirectoryName($sourceFile))))
    [IO.File]::WriteAllText((ConvertTo-RemoteAgentsIOPath $sourceFile),'long path public fixture')
    $longBinding=New-RemoteSyncProject $longData $longProject $longHost $longSource @($relative.Split('/')[0])
    $longState=Get-SyncStatePath $longData $longProject $longHost
    if($longState.Length -ne 221 -or $sourceFile.Length -le 260){throw 'Long path regression fixture too short'}
    $longSeed=Export-RemoteSyncSeed $longData $longProject $longHost
    $snapshot=Join-Path $longState ('snapshot-'+[guid]::NewGuid().ToString('N')+'.json')
    Write-SyncJson $snapshot (Get-Content -LiteralPath (ConvertTo-RemoteAgentsIOPath $longSeed.manifestPath) -Raw|ConvertFrom-Json)
    $receiveFile=Join-Path $longBinding.replicaPath $relative
    [void][IO.Directory]::CreateDirectory((ConvertTo-RemoteAgentsIOPath ([IO.Path]::GetDirectoryName($receiveFile))))
    [IO.File]::Copy((ConvertTo-RemoteAgentsIOPath $sourceFile),(ConvertTo-RemoteAgentsIOPath $receiveFile))
    $longBarrier=Test-RemoteSyncBarrier $longData $longProject $longHost $snapshot $goodHealth
    if(!$longBarrier.ready){throw ('Long snapshot/replica barrier failed: '+$longBarrier.reason)}
    $longInventory=@(Get-SyncInventory $longSource @('.') -WholeRoot -GitSourceTypes -Hash)
    if($longInventory.Count -ne 1 -or $longInventory[0].path -cne $relative -or $longInventory[0].path.Contains('?')){throw 'Extended prefix escaped into relative manifest paths'}
    $unc='\\fixture.invalid\share\folder\file.txt'
    if((ConvertFrom-RemoteAgentsIOPath (ConvertTo-RemoteAgentsIOPath $unc)) -cne $unc){throw 'UNC logical path roundtrip failed'}
    if((ConvertFrom-RemoteAgentsIOPath (ConvertTo-RemoteAgentsIOPath ('\\?\'+$fixture+'\nested\..\file.txt'))) -cne (Join-Path $fixture 'file.txt')){throw 'Extended input bypassed dot-segment normalization'}
    Write-Output 'PASS: inventory exclusions, seed archive, barrier positive/negative, traversal, duplicate binding, source preserved'
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup target'}
    Remove-Item -LiteralPath (ConvertTo-RemoteAgentsIOPath $resolved) -Recurse -Force
}
