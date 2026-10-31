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
    Write-Output 'PASS: inventory exclusions, seed archive, barrier positive/negative, traversal, duplicate binding, source preserved'
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup target'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
