#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'disk/Disk.Common.ps1')
$script:DiskHome=Join-Path $TestHome 'RemoteDisk'
[void][IO.Directory]::CreateDirectory($script:DiskHome)
$count=0
function Assert($ok,$name){if(-not $ok){throw ('FAIL '+$name)};$script:count++}
$policy=New-SelectionIgnores @('src/deep/file.txt','docs')
Assert ($policy.StartsWith('#escape=\'+"`n")) 'portable escape directive'
Assert ($policy.Contains("!/src/deep/file.txt`n!/src/deep/file.txt/**`n")) 'exact rooted selected file'
Assert (-not $policy.Contains("!/src`n") -and -not $policy.Contains("!/src/deep`n")) 'parents do not include siblings'
Assert ($policy.Contains("!/docs`n!/docs/**`n") -and $policy.EndsWith("*`n")) 'subtree allowlist and default deny'
Assert ($policy.IndexOf('(?i).env*') -lt $policy.IndexOf('!/docs')) 'mandatory exclusions win'
$selection=('{"schema":1,"paths":["project/src/deep","project/docs"]}'+"`r`n")|ConvertFrom-Json
Assert (((Get-ProjectSelection project $selection) -join ',') -eq 'docs,src/deep') 'CRLF JSON selection'
Assert ((New-SelectionIgnores @(Get-ProjectSelection project $selection)) -eq (New-SelectionIgnores @('docs','src/deep'))) 'CRLF policy equivalent'
Assert ((New-SelectionIgnores @('x[a]{b}.txt')).Contains('!/x\[a\]\{b\}.txt')) 'metacharacters escaped literally'
foreach($p in @('../outside','a/../../outside','/absolute','a\b','a/*','a//b','a/CON','a/.env','node_modules/x')){
    $failed=$false;try{[void](New-SelectionIgnores @($p))}catch{$failed=$true};Assert $failed ('reject '+$p)
}
$folder=Join-Path $TestHome 'Disk/project';[void][IO.Directory]::CreateDirectory($folder)
[void][IO.Directory]::CreateDirectory((Join-Path $folder '.stfolder'))
[IO.File]::WriteAllText((Join-Path $folder 'keep.txt'),'latest')
[IO.File]::WriteAllText((Join-Path $folder '.env'),'private')
[IO.File]::WriteAllText((Join-Path $folder '.stignore'),[IO.File]::ReadAllText((Join-Path $repo 'disk/stignore.txt')).Replace("`n","`r`n"))
$script:fixtureFolder=$folder
$f=[pscustomobject]@{id='fixture';label='project';path=$folder;paused=$false}
$script:phase='idle';$script:need=0;$script:serverMatches=$true;$script:paused=$false;$script:removedReceipt=$false
function Invoke-DiskApi($Route,$Method='GET',$Body=$null){
    if($Route -like 'db/scan*'){return}
    if($Route -eq 'config/folders/fixture'){
        if($Method -eq 'PATCH'){$script:paused=$Body.paused;return};return [pscustomobject]@{paused=$script:paused}
    }
    if($Route -eq 'system/status'){return [pscustomobject]@{myID='local'}}
    if($Route -like 'db/status*'){return [pscustomobject]@{state=$(if($script:paused){''}else{$script:phase});needBytes=$script:need;needTotalItems=0;pullErrors=0;receiveOnlyChangedBytes=0;receiveOnlyTotalItems=0}}
    throw ('unexpected route '+$Route)
}
function Invoke-DiskServer($Action,$Data,[switch]$Direct){
    Assert ($Action -eq 'verify-selection' -and $Data.paths.Count -eq 1 -and $Data.paths[0] -eq 'keep.txt') 'receipt only for eligible files'
    $script:removedReceipt=$true
    $hash=(Get-FileHash -LiteralPath (Join-Path $script:fixtureFolder 'keep.txt') -Algorithm SHA256).Hash.ToLowerInvariant()
    if(-not $script:serverMatches){$hash='bad'}
    [pscustomobject]@{ok=$true;hashes=[pscustomobject]@{'keep.txt'=$hash}}
}
$original=[IO.File]::ReadAllText((Join-Path $folder '.stignore'))
foreach($phase in @('scanning','syncing','error')){
    $script:phase=$phase;$failed=$false;try{Set-ProjectSelection $f @()}catch{$failed=$true}
    Assert ($failed -and (Test-Path (Join-Path $folder 'keep.txt'))) ('no deletion while '+$phase)
}
$script:phase='idle';$script:need=1;$failed=$false;try{Set-ProjectSelection $f @()}catch{$failed=$true}
Assert ($failed -and -not $script:removedReceipt -and [IO.File]::ReadAllText((Join-Path $folder '.stignore')) -eq $original) 'needBytes blocks before policy change'
$script:need=0;$script:serverMatches=$false;$failed=$false;try{Set-ProjectSelection $f @()}catch{$failed=$true}
Assert ($failed -and (Test-Path (Join-Path $folder 'keep.txt')) -and -not $script:paused) 'different server version retained and resumed'
$script:serverMatches=$true;Set-ProjectSelection $f @()
Assert (-not (Test-Path (Join-Path $folder 'keep.txt')) -and (Test-Path (Join-Path $folder '.env'))) 'verified copy removed, secret retained'
Assert ([IO.File]::ReadAllText((Join-Path $folder '.stignore')).EndsWith("*`n") -and -not $script:paused) 'ignore installed before resumed engine'
Test-DiskIgnores $folder -Write
Assert ([IO.File]::ReadAllText((Join-Path $folder '.stignore')).EndsWith("*`n")) 'legacy helper preserves managed selective policy'
Set-ProjectSelection $f @()
Assert (-not $script:paused -and (Test-Path (Join-Path $folder '.env'))) 'repeat deselection idempotent'
[IO.File]::WriteAllText((Join-Path $folder 'only-here.txt'),'local, never uploaded')
$script:removedReceipt=$false
Set-ProjectSelection $f @() -KeepLocal @('only-here.txt')
Assert ((Test-Path (Join-Path $folder 'only-here.txt')) -and -not $script:removedReceipt) 'unchecked local-only content remains, no server receipt needed'
Assert ([IO.File]::ReadAllText((Join-Path $folder '.stignore')).EndsWith("*`n")) 'unchecked local-only content is excluded before resume'
[IO.File]::WriteAllText((Join-Path $folder '.stignore'),'// RemoteDisk selective v1'+"`n!/**`n")
$failed=$false;try{Test-DiskIgnores $folder -Write}catch{$failed=$true}
Assert $failed 'forged managed comment does not bypass policy validation'
$detached=Join-Path $TestHome 'detached';[void][IO.Directory]::CreateDirectory($detached)
[IO.File]::WriteAllText((Join-Path $detached 'keep.txt'),'preserve local files')
Initialize-ProjectSelection $detached @('first.txt')
Initialize-ProjectSelection $detached @('second.txt')
Assert ([IO.File]::ReadAllText((Join-Path $detached '.stignore')).Contains('!/second.txt')) 'detached project can change an existing trusted selective policy before attach'
Assert ([IO.File]::ReadAllText((Join-Path $detached 'keep.txt')) -eq 'preserve local files') 'initial policy change never deletes local content'
$policy=Get-SelectionPolicyFile $detached;$receipt=[IO.File]::ReadAllText($policy)
[IO.File]::WriteAllText((Join-Path $detached '.stignore'),'foreign-policy')
$failed=$false;try{Initialize-ProjectSelection $detached @('third.txt')}catch{$failed=$true}
Assert ($failed -and [IO.File]::ReadAllText($policy) -ceq $receipt -and [IO.File]::ReadAllText((Join-Path $detached '.stignore')) -ceq 'foreign-policy') 'foreign policy is rejected before replacing its trust receipt'
# Replace-by-rename between initial hashing and deletion must preserve the new version.
$race=Join-Path $TestHome 'race';[void][IO.Directory]::CreateDirectory((Join-Path $race '.stfolder'))
[IO.File]::WriteAllText((Join-Path $race 'keep.txt'),'latest')
$script:fixtureFolder=$race;$f.path=$race
$script:atomicWriter=(Get-Command Write-SelectionAtomic).ScriptBlock
function Write-SelectionAtomic([string]$File,[string]$Text){
    & $script:atomicWriter $File $Text
    if($File -eq (Join-Path $script:fixtureFolder '.stignore')){
        [IO.File]::Move((Join-Path $script:fixtureFolder 'keep.txt'),(Join-Path $script:fixtureFolder '.stfolder/previous'))
        [IO.File]::WriteAllText((Join-Path $script:fixtureFolder 'keep.txt'),'new unuploaded version')
    }
}
$failed=$false;try{Set-ProjectSelection $f @()}catch{$failed=$true}
Assert ($failed -and [IO.File]::ReadAllText((Join-Path $race 'keep.txt')) -ceq 'new unuploaded version') 'atomic editor replacement after receipt is never deleted'
Assert (-not $script:paused) 'replacement failure safely resumes ignored folder'
Set-Item Function:Write-SelectionAtomic $script:atomicWriter
# A repeated legacy helper call must use the same atomic writer for an active ignore.
$script:atomicCalls=0
function Write-SelectionAtomic([string]$File,[string]$Text){$script:atomicCalls++;& $script:atomicWriter $File $Text}
Test-DiskIgnores $race -Write
Assert ($script:atomicCalls -eq 1) 'legacy ignore refresh is atomic'
Set-Item Function:Write-SelectionAtomic $script:atomicWriter
# The move verification must detect equal-size corruption, and keep original files even on success.
$source=Join-Path $TestHome 'move-source';$dest=Join-Path $TestHome 'move-destination'
[void][IO.Directory]::CreateDirectory($source);[IO.File]::WriteAllText((Join-Path $source 'file.txt'),'original')
$script:movedFolder=[pscustomobject]@{id='move';path=$source;paused=$false}
$script:moved=$false
function Invoke-DiskApi($Route,$Method='GET',$Body=$null){
    if($Route -eq 'config/folders'){return $script:movedFolder}
    if($Route -eq 'config/folders/move'){
        if($Method -eq 'PATCH'){if($Body.ContainsKey('path')){$script:moved=$true;$script:movedFolder.path=$Body.path};return}
        return $script:movedFolder
    }
    if($Route -like 'events*'){return [pscustomobject]@{id=1;type='FolderPaused';data=@{id='move'}}}
    throw 'unexpected move API'
}
$script:realCopy=(Get-Command Copy-DiskTree).ScriptBlock
function Copy-DiskTree([string]$From,[string]$To){& $script:realCopy $From $To;[IO.File]::WriteAllText((Join-Path $To 'file.txt'),'corrupt!')}
$failed=$false;try{Move-DiskFolder move $dest -Copy}catch{$failed=$true}
Assert ($failed -and -not $script:moved -and [IO.File]::ReadAllText((Join-Path $source 'file.txt')) -ceq 'original' -and [IO.File]::ReadAllText((Join-Path $dest 'file.txt')) -ceq 'corrupt!') 'same-size corrupted copy blocks path switch and preserves both trees'
Remove-Item -LiteralPath $dest -Recurse -Force
Set-Item Function:Copy-DiskTree $script:realCopy
[void](Move-DiskFolder move $dest -Copy)
Assert ($script:moved -and [IO.File]::ReadAllText((Join-Path $dest 'file.txt')) -ceq 'original' -and [IO.File]::ReadAllText((Join-Path $source 'file.txt')) -ceq 'original') 'cross-volume copy keeps recovery source after switching engine path'
Write-Output ('OK: '+$count+' selective checks (fixtures; CRLF, policy, unsafe deletion, retry)')
