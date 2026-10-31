param([string]$Archive)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Sync.Workspace.ps1"
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ra-mingit-'+[guid]::NewGuid().ToString('N'))
$oldPath=$env:PATH;$oldConfig=$env:GIT_CONFIG_GLOBAL
New-Item -ItemType Directory -Path $fixture|Out-Null
try {
    $installed=Get-SyncGitExecutable
    if(!(Test-Path -LiteralPath $installed -PathType Leaf)){throw 'Existing Git discovery failed'}
    $portable=Get-SyncGitExecutable -DataDir $fixture -DownloadedArchive $Archive -ForcePortable
    if(!$portable.StartsWith($fixture+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Portable Git escaped fixture'}
    $env:PATH=''
    $version=& $portable --version
    if($LASTEXITCODE -ne 0 -or $version -notmatch '^git version 2\.56\.0\.windows\.4$'){throw 'Portable Git cannot run without PATH'}
    $reused=Get-SyncGitExecutable -DataDir $fixture -ForcePortable
    if($reused -cne $portable){throw 'Portable Git was not reused'}
    New-Item -ItemType Directory -Path "$fixture\source\src" -Force|Out-Null
    $env:GIT_CONFIG_GLOBAL=Join-Path $fixture 'config'
    [IO.File]::WriteAllText("$fixture\ignore",'')
    [IO.File]::WriteAllText($env:GIT_CONFIG_GLOBAL,"[core]`n excludesfile = $($fixture.Replace('\','/'))/ignore`n autocrlf = false`n")
    & $portable -C "$fixture\source" init -q
    [IO.File]::WriteAllText("$fixture\source\src\new.py",'print(1)')
    if(@(Get-SyncGitInventory "$fixture\source").Count -ne 1){throw 'Git scope did not use portable executable'}
    $originalLength=(Get-Item -LiteralPath $portable).Length
    $stream=[IO.File]::Open($portable,[IO.FileMode]::Append);try{$stream.WriteByte(0)}finally{$stream.Dispose()}
    $blocked=$false;try{Get-SyncGitExecutable|Out-Null}catch{$blocked=$true}
    if(!$blocked){throw 'Modified cached portable executable accepted'}
    $stream=[IO.File]::OpenWrite($portable);try{$stream.SetLength($originalLength)}finally{$stream.Dispose()}
    $marker=Join-Path (Split-Path (Split-Path $portable -Parent) -Parent) 'portable-git.json'
    $original=[IO.File]::ReadAllText($marker)
    $bad=$original|ConvertFrom-Json;$bad.executableSHA256='fake-checksum'
    Write-SyncJson $marker $bad
    $blocked=$false;try{Get-SyncGitExecutable -DataDir $fixture -ForcePortable|Out-Null}catch{$blocked=$true}
    if(!$blocked){throw 'Modified portable metadata accepted'}
    [IO.File]::WriteAllText($marker,$original)
    [IO.File]::WriteAllText("$fixture\bad.zip",'synthetic invalid archive')
    $blocked=$false;try{Get-SyncGitExecutable -DataDir "$fixture\bad-state" -DownloadedArchive "$fixture\bad.zip" -ForcePortable|Out-Null}catch{$blocked=$true}
    if(!$blocked){throw 'Untrusted archive accepted'}
    'PASS: existing Git discovery, pinned portable install, no PATH, Git scope, reuse and tamper/hash rejection'
} finally {
    $env:PATH=$oldPath;$env:GIT_CONFIG_GLOBAL=$oldConfig
    $resolved=[IO.Path]::GetFullPath($fixture)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup target'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
