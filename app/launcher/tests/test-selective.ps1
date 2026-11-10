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
[IO.File]::WriteAllText((Join-Path $folder '.stignore'),'// RemoteDisk selective v1'+"`n!/**`n")
$failed=$false;try{Test-DiskIgnores $folder -Write}catch{$failed=$true}
Assert $failed 'forged managed comment does not bypass policy validation'
Write-Output ('OK: '+$count+' selective checks (fixtures; CRLF, policy, unsafe deletion, retry)')
