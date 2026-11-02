$ErrorActionPreference='Stop'
. "$PSScriptRoot\Sync.Workspace.ps1"
function Assert-Test($Condition,[string]$Message){if(!$Condition){throw $Message}}
function Assert-Throws([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert-Test $failed $Message}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ra-selection-'+[guid]::NewGuid().ToString('N'))
$source=Join-Path $fixture 'plain project';$gitRoot=Join-Path $fixture 'git project';$worktree=Join-Path $fixture 'git worktree';$data=Join-Path $fixture 'state'
$oldGlobal=$env:GIT_CONFIG_GLOBAL;$oldSystem=$env:GIT_CONFIG_NOSYSTEM;$oldProfile=$env:USERPROFILE
New-Item -ItemType Directory -Path $source,$gitRoot -Force|Out-Null
try {
    # Synthetic profile makes fixture Temp eligible without inspecting any real profile folder.
    $env:USERPROFILE=Join-Path $fixture 'synthetic-profile';New-Item -ItemType Directory -Path $env:USERPROFILE|Out-Null
    $env:GIT_CONFIG_GLOBAL=Join-Path $fixture 'empty-config';$env:GIT_CONFIG_NOSYSTEM='1';$emptyIgnore=Join-Path $fixture 'empty-ignore';[IO.File]::WriteAllText($emptyIgnore,'');[IO.File]::WriteAllText($env:GIT_CONFIG_GLOBAL,"[core]`n excludesfile = $($emptyIgnore.Replace('\','/'))`n autocrlf = false`n")
    [IO.File]::WriteAllText((Join-Path $source 'main.py'),'x=1')
    [IO.File]::WriteAllText((Join-Path $source 'package.json'),'{}')
    New-Item -ItemType Directory -Path (Join-Path $source 'node_modules'),(Join-Path $source 'nested') -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'node_modules\dependency.js'),'synthetic')
    [IO.File]::WriteAllText((Join-Path $source 'nested\excluded.js'),'synthetic')
    & git -C (Join-Path $source 'nested') init -q;if($LASTEXITCODE){throw 'Nested fixture init failed'}
    $future=[DateTime]::UtcNow.AddYears(2);[IO.File]::SetLastWriteTimeUtc((Join-Path $source 'node_modules\dependency.js'),$future)
    $paths=@(ConvertFrom-RemoteSyncProjectPaths ('"'+$source+'"' + "`n  '"+$gitRoot+"'`n"+$source.ToUpperInvariant()+"\`n"))
    Assert-Test ($paths.Count -eq 2 -and $paths[0] -eq $source) 'Quoted pasted paths were not normalized/deduplicated'
    Assert-Throws {ConvertFrom-RemoteSyncProjectPaths 'relative\project'} 'Relative path accepted'
    $metadata=Get-RemoteSyncProjectMetadata $source -Refresh
    Assert-Test ($metadata.fileCount -eq 2 -and $metadata.bytes -eq 5 -and $metadata.complete) 'Folder metadata scope/count wrong'
    Assert-Test ([DateTime]$metadata.lastSourceWriteUtc -lt $future) 'Dependency date affected source date'
    Assert-Test (Get-RemoteSyncProjectMetadata $source).cached 'Metadata cache was not used'
    Assert-Test (!(Get-RemoteSyncProjectMetadata $source -MaxFiles 1 -Refresh).complete) 'Metadata file bound was ignored'
    Assert-Test (!(Get-RemoteSyncProjectMetadata $source -MaxDirectories 1 -Refresh).complete) 'Metadata directory bound was ignored'
    $large=Join-Path $source 'large.txt';$stream=[IO.File]::Create($large);try{$stream.SetLength(20971521)}finally{$stream.Dispose()}
    $metadata=Get-RemoteSyncProjectMetadata $source -Refresh
    Assert-Test ($metadata.largeFileCount -eq 1 -and $metadata.bytes -eq 20971526 -and $metadata.complete) 'Large source was silently omitted'
    Remove-Item -LiteralPath $large
    & git -C $gitRoot init -q;if($LASTEXITCODE){throw 'Fixture init failed'}
    [IO.File]::WriteAllText((Join-Path $gitRoot 'main.js'),'synthetic')
    & git -C $gitRoot add -- main.js
    & git -C $gitRoot -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -qm fixture
    if($LASTEXITCODE){throw 'Fixture commit failed'}
    & git -C $gitRoot worktree add -q --detach $worktree;if($LASTEXITCODE){throw 'Fixture worktree failed'}
    [IO.File]::WriteAllText((Join-Path $gitRoot '.gitignore'),"ignored.js`n")
    [IO.File]::WriteAllText((Join-Path $gitRoot 'ignored.js'),'synthetic ignored')
    $gitMetadata=Get-RemoteSyncProjectMetadata $gitRoot -ScopeMode git -Refresh
    Assert-Test ($gitMetadata.fileCount -eq 2 -and $gitMetadata.bytes -eq 20) 'Git ignored source affected metadata'
    Assert-Test ((Get-RemoteSyncProjectCandidate $gitRoot).kind -eq 'git') 'Git candidate kind wrong'
    Assert-Test ((Get-RemoteSyncProjectCandidate $worktree).kind -eq 'worktree') 'Worktree plumbing detection failed'
    $candidates=@(Get-RemoteSyncProjectCandidates @($source,$gitRoot,$worktree) -DataDir $data -HostId local)
    Assert-Test (@($candidates|Where-Object selected).Count -eq 0) 'New discovery was automatically selected'
    Save-RemoteSyncSelection $data local $candidates -Cancel|Out-Null
    Assert-Test (!(Test-Path -LiteralPath $data)) 'Cancel mutated state'
    $candidates[0].selected=$true;$saved=Save-RemoteSyncSelection $data local $candidates
    $id=$saved.projects[0].projectId;$binding=Get-SyncBinding $data $id local
    Assert-Test ($binding.scopeMode -eq 'folder' -and $binding.allowedRoots[0] -eq '.') 'Folder binding schema wrong'
    $repeat=Save-RemoteSyncSelection $data local $candidates
    Assert-Test ($repeat.projects[0].projectId -eq $id -and @(Get-RemoteSyncProjects $data).Count -eq 1) 'Repeated save duplicated registration'
    $candidateId=$repeat.projects[1].projectId
    Assert-Test (!(Test-Path -LiteralPath (Join-Path (Get-SyncStatePath $data $candidateId local) 'project.json'))) 'Unchecked candidate unexpectedly has a binding'
    $candidates[1].selected=$true;Save-RemoteSyncSelection $data local $candidates|Out-Null
    Assert-Test ((Get-SyncBinding $data $candidateId local).projectId -ceq $candidateId) 'Selecting a saved unbound candidate failed'
    $candidates[1].selected=$false;Save-RemoteSyncSelection $data local $candidates|Out-Null
    $omitted=Save-RemoteSyncSelection $data local @()
    Assert-Test ($omitted.projects[0].selected) 'Omitted saved row was silently unchecked'
    $seed=Export-RemoteSyncSeed $data $id local
    $manifest=[IO.File]::ReadAllText($seed.manifestPath)|ConvertFrom-Json
    Assert-Test ($manifest.scopeMode -eq 'folder' -and $manifest.files.Count -eq 2) 'Folder manifest scope wrong'
    New-Item -ItemType Directory -Path $binding.replicaPath -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $binding.replicaPath 'keep.txt'),'preserve')
    $candidates[0].selected=$false;Save-RemoteSyncSelection $data local $candidates|Out-Null
    Assert-Test (!(Get-RemoteSyncSelection $data local).projects[0].selected -and (Test-Path -LiteralPath $binding.replicaPath) -and @(Get-RemoteSyncProjects $data).Count -eq 2) 'Uncheck deleted binding or replica'
    $before=[IO.File]::ReadAllText((Join-Path $data 'sync\selections\local.json'))
    $overlap=@([pscustomobject]@{sourcePath=$source;selected=$true},[pscustomobject]@{sourcePath=(Join-Path $source 'nested');selected=$true})
    Assert-Throws {Save-RemoteSyncSelection $data local $overlap} 'Overlapping roots accepted'
    Assert-Test ($before -ceq [IO.File]::ReadAllText((Join-Path $data 'sync\selections\local.json'))) 'Rejected selection mutated saved state'
    New-RemoteSyncProject -DataDir $data -ProjectId legacy -HostId oldhost -SourcePath $gitRoot -ScopeMode git|Out-Null
    Assert-Test ((Get-RemoteSyncSelection $data oldhost).projects[0].selected) 'Legacy binding did not migrate enabled'
    $discovery=Find-RemoteSyncProjectCandidates $fixture -IncludeNonGit
    Assert-Test (@($discovery.candidates|Where-Object {$_.sourcePath -eq (Join-Path $source 'nested')}).Count -eq 0) 'Discovery included nested project'
    Assert-Test (@($discovery.candidates|Where-Object selected).Count -eq 0) 'Discovery registered or enabled candidates'
    Assert-Test (!(Find-RemoteSyncProjectCandidates $fixture -MaxDirectories 1).complete) 'Discovery directory limit ignored'
    Assert-Throws {Get-RemoteSyncProjectCandidate $env:USERPROFILE} 'Profile root accepted'
    $link=Join-Path $source 'linked';$linkCreated=$false
    try {New-Item -ItemType Junction -Path $link -Target $gitRoot -ErrorAction Stop|Out-Null;$linkCreated=$true}catch{}
    if($linkCreated){try{Assert-Throws {Get-RemoteSyncProjectCandidate $link} 'Reparse project accepted';Assert-Test ((Get-RemoteSyncProjectMetadata $source -Refresh).fileCount -eq 2) 'Reparse contents traversed'}finally{[IO.Directory]::Delete($link)}}
    'PASS: explicit selection, quoted paste, Git/worktree/folder, legacy, cancel/uncheck/repeat, limits, metadata, overlap and reparse'
} finally {
    $env:GIT_CONFIG_GLOBAL=$oldGlobal;$env:GIT_CONFIG_NOSYSTEM=$oldSystem;$env:USERPROFILE=$oldProfile
    $resolved=[IO.Path]::GetFullPath($fixture);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if(!$resolved.StartsWith($temp+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'ra-selection-*'){throw 'Unsafe fixture cleanup path'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
