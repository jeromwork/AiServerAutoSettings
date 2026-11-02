$ErrorActionPreference='Stop'
. "$PSScriptRoot\Sync.Workspace.ps1"
function Assert($Value,$Message){if(!$Value){throw $Message}}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ra-quick-search-'+[guid]::NewGuid().ToString('N'))
$profileRoot=Join-Path $fixture 'profile';$driveRoot=Join-Path $fixture 'drive'
$oldProfile=$env:USERPROFILE;$oldGlobal=$env:GIT_CONFIG_GLOBAL;$oldSystem=$env:GIT_CONFIG_NOSYSTEM
$junction=$null
try {
    [void][IO.Directory]::CreateDirectory($profileRoot);[void][IO.Directory]::CreateDirectory($driveRoot)
    $env:USERPROFILE=$profileRoot;$env:GIT_CONFIG_GLOBAL=Join-Path $fixture 'empty-git-config';$env:GIT_CONFIG_NOSYSTEM='1'
    [IO.File]::WriteAllText($env:GIT_CONFIG_GLOBAL,'')
    $git=Get-SyncGitExecutable
    function New-QuickFixture([string]$Path,[datetime]$Date){
        [void][IO.Directory]::CreateDirectory($Path)
        & $git -C $Path init -q;if($LASTEXITCODE){throw 'Fixture Git init failed'}
        [IO.File]::WriteAllText((Join-Path $Path 'app.js'),'synthetic source')
        [IO.File]::SetLastWriteTimeUtc((Join-Path $Path 'app.js'),$Date)
    }
    $fresh=Join-Path $profileRoot 'Documents\GitHub\fresh'
    $older=Join-Path $profileRoot 'source\repos\older'
    $work=Join-Path $driveRoot 'work';$data=Join-Path $work 'service-state'
    New-QuickFixture $fresh ([datetime]'2025-02-01Z')
    New-QuickFixture $older ([datetime]'2020-01-01Z')
    [IO.File]::WriteAllText((Join-Path $older '.gitignore'),"ignored.js`n")
    [IO.File]::SetLastWriteTimeUtc((Join-Path $older '.gitignore'),[datetime]'2020-01-01Z')
    [IO.File]::WriteAllText((Join-Path $older 'ignored.js'),'synthetic ignored source')
    [IO.File]::SetLastWriteTimeUtc((Join-Path $older 'ignored.js'),[datetime]'2090-01-01Z')
    New-QuickFixture (Join-Path $older 'nested') ([datetime]'2091-01-01Z')
    New-QuickFixture (Join-Path $work 'node_modules\dependency') ([datetime]'2092-01-01Z')
    New-QuickFixture $data ([datetime]'2093-01-01Z')
    New-QuickFixture (Join-Path $fixture 'outside\foreign') ([datetime]'2094-01-01Z')
    & $git -C $fresh add -- app.js
    & $git -C $fresh -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -qm fixture
    if($LASTEXITCODE){throw 'Fixture Git commit failed'}
    $tree=Join-Path $work 'worktree'
    & $git -C $fresh worktree add -q --detach $tree;if($LASTEXITCODE){throw 'Fixture worktree failed'}
    [IO.File]::SetLastWriteTimeUtc((Join-Path $tree 'app.js'),[datetime]'2026-01-01Z')
    $junction=Join-Path $work 'outside-link'
    try{New-Item -ItemType Junction -Path $junction -Target (Join-Path $fixture 'outside') -ErrorAction Stop|Out-Null}catch{$junction=$null}
    $roots=@(Get-RemoteSyncQuickSearchRoots -ProfilePath $profileRoot -DocumentsPath (Join-Path $profileRoot 'Documents') -DesktopPath (Join-Path $profileRoot 'Desktop') -DriveRoots @($driveRoot))
    Assert ($roots -contains (Join-Path $profileRoot 'source') -and $roots -contains (Join-Path $profileRoot 'Documents\GitHub') -and $roots -contains $work) 'Typical project roots missing'
    Assert ($roots -notcontains $profileRoot -and $roots -notcontains $driveRoot) 'Quick search selected whole profile/disk'
    $result=Find-RemoteSyncQuickRepositories -RootPaths ($roots+@($work.ToUpperInvariant(),$older)) -DataDir $data -HostId fixture
    Assert ($result.candidates.Count -eq 4) ('Wrong repositories: '+($result.candidates.sourcePath -join ', '))
    Assert ($result.candidates[0].sourcePath -eq (Join-Path $older 'nested') -and $result.candidates[1].sourcePath -eq $fresh -and $result.candidates[2].sourcePath -eq $older -and $result.candidates[3].sourcePath -eq $tree) 'Git/worktree grouping or eligible source dates wrong'
    Assert (@($result.candidates|Where-Object selected).Count -eq 0 -and @($result.candidates|Where-Object kind -eq worktree).Count -eq 1) 'Auto-selection or worktree detection failed'
    Assert (!(Test-Path -LiteralPath (Join-Path $data 'sync\selections'))) 'Discovery saved bindings'
    $bounded=Find-RemoteSyncQuickRepositories -RootPaths $roots -MaxDirectories 1
    Assert (!$bounded.complete -and $bounded.reasons -contains 'directory-limit') 'Directory bound not reported'
    $limited=Find-RemoteSyncQuickRepositories -RootPaths $roots -MaxProjects 1
    Assert ($limited.candidates.Count -eq 1 -and !$limited.complete) 'Project bound not reported'
    $missing=Get-SyncGitExecutable -DataDir (Join-Path $fixture 'empty-cache') -ForcePortable -InstalledOnly
    Assert (!$missing -and !(Test-Path -LiteralPath (Join-Path $fixture 'empty-cache'))) 'InstalledOnly provisioned/downloaded Git'
    & {
        function Get-SyncGitExecutable {param([switch]$InstalledOnly);return $null}
        $unavailable=Find-RemoteSyncQuickRepositories -RootPaths $roots
        Assert (!$unavailable.complete -and $unavailable.reasons -contains 'git-unavailable') 'Missing Git was not explicit'
    }
    $script:source=(Join-Path $older 'nested')
    $selection=@([pscustomobject]@{sourcePath=$older;selected=$true},[pscustomobject]@{sourcePath=$script:source;selected=$true})
    $overlapDenied=$false;try{Save-RemoteSyncSelection -DataDir (Join-Path $fixture 'selection') -HostId fixture -Candidates $selection|Out-Null}catch{$overlapDenied=$true}
    Assert $overlapDenied 'Nested discovery allowed overlapping seed selection'
    'PASS: nested repo discovery, Git above worktrees, eligible source dates, ignored/dependency/state/link exclusion, overlap refusal, deduplication/bounds and no downloads'
}finally{
    if($junction -and (Test-Path -LiteralPath $junction)){[IO.Directory]::Delete($junction)}
    $env:USERPROFILE=$oldProfile;$env:GIT_CONFIG_GLOBAL=$oldGlobal;$env:GIT_CONFIG_NOSYSTEM=$oldSystem
    $resolved=[IO.Path]::GetFullPath($fixture);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe quick-search fixture cleanup'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
