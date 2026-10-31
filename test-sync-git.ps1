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
    $seed=Export-RemoteSyncSeed "$fixture\state" demo host1
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
    'PASS: Git tracked/new/ignored/deleted/deny/nested scope, seed, repeat, root guard and barrier'
} finally {
    $env:GIT_CONFIG_GLOBAL=$oldGitConfig
    $resolved=[IO.Path]::GetFullPath($fixture)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup target'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
