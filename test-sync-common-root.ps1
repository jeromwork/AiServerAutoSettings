$ErrorActionPreference='Stop'
. "$PSScriptRoot\Sync.Workspace.ps1"
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ra-common-root-'+[guid]::NewGuid().ToString('N'))
$root=Join-Path $fixture 'projects';$state=Join-Path $root 'private-state';$link=Join-Path $root 'escape-link'
$oldConfig=$env:GIT_CONFIG_GLOBAL;$junctionCreated=$false
New-Item -ItemType Directory -Path $root -Force|Out-Null
try {
    $env:GIT_CONFIG_GLOBAL=Join-Path $fixture 'git-config'
    [IO.File]::WriteAllText("$fixture\ignore",'')
    [IO.File]::WriteAllText($env:GIT_CONFIG_GLOBAL,"[core]`n excludesfile = $($fixture.Replace('\','/'))/ignore`n")
    $git=Get-SyncGitExecutable
    function New-FixtureRepo([string]$Path) {
        New-Item -ItemType Directory -Path "$Path\src" -Force|Out-Null
        & $git -C $Path init -q;if($LASTEXITCODE){throw 'Synthetic Git init failed'}
        [IO.File]::WriteAllText("$Path\src\index.js",'synthetic source')
    }
    foreach($relative in @('alpha','group\deep\beta','legacy','alpha\nested','node_modules\dependency','vendor\dependency','private-state\internal')){New-FixtureRepo (Join-Path $root $relative)}
    New-FixtureRepo "$fixture\outside\foreign"
    New-Item -ItemType Directory -Path "$root\plain"|Out-Null
    [IO.File]::WriteAllText("$root\plain\notes.txt",'not a repository')
    try {New-Item -ItemType Junction -Path $link -Target "$fixture\outside" -ErrorAction Stop|Out-Null;$junctionCreated=$true}catch{}
    $legacy=New-RemoteSyncProject -DataDir $state -ProjectId legacy -HostId host1 -SourcePath "$root\legacy" -AllowedRoots src
    New-RemoteSyncProject -DataDir $state -ProjectId otherhost -HostId host2 -SourcePath "$root\alpha" -ScopeMode git|Out-Null
    $legacyPath=Join-Path (Get-SyncStatePath $state legacy host1) 'project.json'
    $legacyHash=Get-SyncSHA256 $legacyPath
    if(Get-RemoteSyncRoot $state host1){throw 'Unconfigured root unexpectedly present'}
    Save-RemoteSyncRoot $state host1 $root|Out-Null
    if((Get-RemoteSyncRoot $state host1).rootPath -cne $root){throw 'Common root was not saved'}
    $first=Update-RemoteSyncRootProjects $state host1
    if(!$first.complete -or $first.foundCount -ne 3 -or $first.addedCount -ne 2 -or $first.existingCount -ne 1){throw 'Sibling/deep/nested/denied scope incorrect'}
    if((Get-SyncSHA256 $legacyPath) -cne $legacyHash){throw 'Legacy binding changed'}
    $bindings=@(Get-RemoteSyncProjects $state|Where-Object{$_.hostId -eq 'host1'})
    if($bindings.Count -ne 3 -or @($bindings.replicaPath|Sort-Object -Unique).Count -ne 3){throw 'Project replicas are not separate'}
    foreach($binding in $bindings){if(!$binding.projectId -or !$binding.hostId -or !$binding.replicaPath){throw 'Handoff metadata missing'}}
    $second=Update-RemoteSyncRootProjects $state host1
    if($second.addedCount -ne 0 -or $second.existingCount -ne 3){throw 'Repeat duplicated project bindings'}
    New-FixtureRepo "$root\gamma"
    $third=Update-RemoteSyncRootProjects $state host1
    if($third.addedCount -ne 1 -or $third.existingCount -ne 3){throw 'New project was not detected on repeat'}
    $bounded=Find-RemoteSyncRepositories -RootPath $root -MaxDepth 1 -ExcludedPaths @($state)
    if($bounded.complete -or 'depth-limit' -notin $bounded.reasons){throw 'Incomplete bounded discovery was not reported'}
    $bounded=Find-RemoteSyncRepositories -RootPath $root -MaxProjects 1 -ExcludedPaths @($state)
    if($bounded.complete -or $bounded.repositories.Count -ne 1){throw 'Project count limit failed'}
    New-FixtureRepo "$fixture\root-repo";New-FixtureRepo "$fixture\root-repo\nested"
    $direct=Find-RemoteSyncRepositories "$fixture\root-repo"
    if($direct.repositories.Count -ne 1 -or $direct.repositories[0].relativeProjectPath -ne '.'){throw 'Repository directly at common root failed'}
    Save-RemoteSyncRoot "$fixture\direct-state" host1 "$fixture\root-repo"|Out-Null
    $directBinding=Update-RemoteSyncRootProjects "$fixture\direct-state" host1
    if($directBinding.addedCount -ne 1 -or $directBinding.projects[0].relativeProjectPath -ne '.'){throw 'Direct root repository binding failed'}
    $blocked=$false;try{Find-RemoteSyncRepositories ([IO.Path]::GetPathRoot($root))|Out-Null}catch{$blocked=$true}
    if(!$blocked){throw 'Entire-drive discovery allowed'}
    if($junctionCreated){
        $blocked=$false;try{Save-RemoteSyncRoot $state host3 $link|Out-Null}catch{$blocked=$true}
        if(!$blocked){throw 'Reparse root accepted'}
        if(!(Test-Path -LiteralPath "$fixture\outside\foreign\src\index.js")){throw 'Reparse target changed'}
    }
    # Legacy discovery remains callable, but the installer never auto-registers findings.
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'setup-vps-ssh.ps1'),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Installer PS5.1 parse failed'}
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Connect-ProjectFolders'},$true)
    if(!$node){throw 'Installer project list function missing'}
    . ([scriptblock]::Create($node.Extent.Text))
    foreach($number in 1..10){New-FixtureRepo (Join-Path $root ('batch\repo'+$number.ToString('00')))}
    $context=[pscustomobject]@{DataDir=$state;ClientId='host1'}
    $script:ListMessages=New-Object 'Collections.Generic.List[string]'
    function Initialize-ProjectModule {}
    function Get-ProjectClientContext {$context}
    function Add-ProjectFolder {param($Context);[pscustomobject]@{cancelled=$true}}
    function Save-ProfileMetadata {param($Value,$Path)}
    function Read-Host {param($Prompt) '0'}
    function Write-Host {param([Parameter(ValueFromRemainingArguments=$true)]$Values) $script:ListMessages.Add(($Values -join ' '))}
    $script:sshExecutable='synthetic';$script:askpassExecutable='';$ServerAddress='synthetic';$Login='synthetic';$keyPath='unused';$knownHostsPath='unused';$configPath='unused';$common=@()
    $before=@(Get-RemoteSyncProjects $state|Where-Object{$_.hostId -eq 'host1'}).Count
    Connect-ProjectFolders 'codex' @{}
    if(@(Get-RemoteSyncProjects $state|Where-Object{$_.hostId -eq 'host1'}).Count -ne $before){throw 'Installer auto-registered unselected discoveries'}
    'PASS: legacy root compatibility, sibling/deep discovery, nested/deps exclusion, replicas/hosts, repeat/new repo, bounds, root repo; installer cancellation does not auto-register'
    if(!$junctionCreated){'SKIP: junction creation not permitted; reparse fixture unavailable'}else{'PASS: junction escape and linked-root rejection'}
} finally {
    $env:GIT_CONFIG_GLOBAL=$oldConfig
    if($junctionCreated -and (Test-Path -LiteralPath $link)){[IO.Directory]::Delete($link)}
    $resolved=[IO.Path]::GetFullPath($fixture);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup target'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
