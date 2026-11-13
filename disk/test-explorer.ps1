#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
if(-not $TestHome){$TestHome=Join-Path ([IO.Path]::GetTempPath()) ('disk-explorer-'+[guid]::NewGuid().ToString('N'))}
[void][IO.Directory]::CreateDirectory($TestHome)
$oldLocal=$env:LOCALAPPDATA;$env:LOCALAPPDATA=Join-Path $TestHome 'local'
. (Join-Path $PSScriptRoot 'Disk.Common.ps1')
. (Join-Path $PSScriptRoot 'Disk.Union.ps1')
$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk';[void][IO.Directory]::CreateDirectory($script:DiskHome)
$count=0
function Assert($Value,[string]$Label){if(-not $Value){throw ('FAIL: '+$Label)};$script:count++}
function Refuses([scriptblock]$Action){try{& $Action|Out-Null;return $false}catch{return $true}}
$base=Join-Path $TestHome 'Disk';$project=Join-Path $base 'Project';[void][IO.Directory]::CreateDirectory($project)
$ini=Join-Path $project 'desktop.ini'
$owned="[.ShellClassInfo]`r`nInfoTip=Server`r`n[RemoteAgents]`r`nOwner=RemoteAgents.Disk.v1`r`nPlaceholder=1`r`nOriginalReadOnly=0`r`nCreatedDirectory=1`r`n"
$utf8=New-Object Text.UTF8Encoding($true)
[IO.File]::WriteAllText($ini,$owned,$utf8)
$tree=[pscustomobject]@{entries=@([pscustomobject]@{path='Project';directory=$true;hasChildren=$true})}
Assert (Test-DiskPlaceholder $project) 'CRLF own empty placeholder recognized'
$union=Get-DiskUnion $tree $base
Assert ($union.rows.Count -eq 1 -and $union.rows[0].presence -ceq 'server') 'placeholder does not claim a local copy'
Assert (-not (Test-DiskLocalContent $project)) 'placeholder is not offered as local content for a merge'
Assert (@((Get-DiskUnion ([pscustomobject]@{entries=@()}) $base).rows).Count -eq 0) 'orphan empty placeholder is not local inventory'
$user=Join-Path $project 'mine.txt';[IO.File]::WriteAllText($user,'local')
Assert (-not (Test-DiskPlaceholder $project) -and (Test-DiskLocalContent $project)) 'user files make placeholder a local copy'
Assert ((Get-DiskUnion $tree $base).rows[0].presence -ceq 'both') 'local copy with server presence is merged normally'
[IO.File]::Delete($user)
[IO.File]::WriteAllText($ini,"[.ShellClassInfo]`r`nInfoTip=Mine`r`n",$utf8)
Assert (-not (Test-DiskPlaceholder $project)) 'foreign desktop.ini is never a placeholder'
Assert ((Get-DiskUnion $tree $base).rows[0].presence -ceq 'both') 'foreign customized folder remains a local copy'
$storageProject=Join-Path $base 'storage';[void][IO.Directory]::CreateDirectory((Join-Path $storageProject 'app'))
$storageLevel=Get-DiskUnion ([pscustomobject]@{entries=@()}) $base 'storage'
Assert (@($storageLevel.rows|Where-Object {$_.path -ceq 'storage/app'}).Count -eq 1) 'root-only patterns are relative to each project, not to Disk root'
[IO.Directory]::Delete((Join-Path $storageProject 'app'),$false);[IO.Directory]::Delete($storageProject,$false)
# Real links are the portable surrogate of a Windows junction. Test entry points as well as descendants.
$outside=Join-Path $TestHome 'Outside';[void][IO.Directory]::CreateDirectory((Join-Path $outside 'deep'));[IO.File]::WriteAllText((Join-Path $outside 'deep/private.txt'),'do not enumerate')
$link=Join-Path $base 'Link';$linkKind='SymbolicLink';if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){$linkKind='Junction'};[void](New-Item -ItemType $linkKind -Path $link -Target $outside)
$rows=@((Get-DiskUnion ([pscustomobject]@{entries=@()}) $base).rows)
Assert (@($rows|Where-Object {$_.path -eq 'Link'}).Count -eq 0) 'union does not enumerate a junction as a local project'
Assert (Refuses {Get-DiskUnion ([pscustomobject]@{entries=@()}) $base 'Link'}) 'direct tree into junction refused'
Assert (Refuses {Get-SelectionFiles $link}) 'recursive inventory entry point cannot follow a junction'
Assert (Refuses {Get-DiskTreeList $link}) 'copy verification entry point cannot follow a junction'
Assert (Refuses {Copy-DiskTree $link (Join-Path $TestHome 'Copy')}) 'copy cannot follow a junction at its entry point'
Assert (Refuses {Get-DiskTreeList $base}) 'copy verification cannot follow a nested junction'
[IO.Directory]::Delete($link,$false)
# Real Syncthing ignore persistence is represented by its narrow REST wrapper.
$template=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'stignore.txt')).Replace("`r",'')
$oldTemplate=$template.Substring(0,$template.LastIndexOf('// Оформление Проводника',[StringComparison]::Ordinal))
$ignoreFile=Join-Path $project '.stignore';$script:ignorePosts=0;$script:loadedRules=$oldTemplate.TrimEnd("`n") -split "`n"
function Invoke-DiskApi($Route,$Method='GET',$Body=$null){
    if($Route -ceq 'config/folders'){return $script:mockFolders}
    if($Route -notlike 'db/ignores?folder=*'){throw ('Unexpected REST '+$Route)}
    if($Route -ceq 'db/ignores?folder=outside'){
        if($Method -ceq 'POST'){
            $script:ignorePosts++;$script:outsideRules=@($Body.ignore)
            Write-DiskUtf8 (Join-Path $outside '.stignore') (($script:outsideRules -join "`n")+"`n")
        }
        return @{ignore=@($script:outsideRules)}
    }
    if($Method -ceq 'POST'){
        $script:ignorePosts++;$script:loadedRules=@($Body.ignore)
        Write-DiskUtf8 $ignoreFile (($script:loadedRules -join "`n")+"`n")
    }
    @{ignore=@($script:loadedRules)}
}
$folder=[pscustomobject]@{id='project';path=$project}
[IO.File]::WriteAllText($ignoreFile,$oldTemplate.Replace("`n","`r`n"),$utf8)
Ensure-DiskExplorerFolderIgnores $folder|Out-Null
Assert ($script:ignorePosts -eq 1 -and [IO.File]::ReadAllText($ignoreFile) -ceq $template) 'known CRLF old template upgraded through Syncthing REST and confirmed'
Ensure-DiskExplorerFolderIgnores $folder|Out-Null
Assert ($script:ignorePosts -eq 1) 'ignore upgrade idempotent after engine confirms load'
$proof=Ensure-DiskExplorerFolderIgnores $folder
Assert ($proof.path -ceq $project -and $proof.sha256 -ceq (Get-DiskExplorerProofHash $template.Replace("`n","`r`n"))) 'native proof hashes the trusted normalized policy'
$oldPolicy='#escape=\'+"`n"+$oldTemplate+"// RemoteDisk selective v1`n!/docs`n!/docs/**`n*`n"
Save-SelectionPolicy $project $oldPolicy
Write-DiskUtf8 $ignoreFile $oldPolicy;$script:loadedRules=$oldPolicy.TrimEnd("`n") -split "`n"
Ensure-DiskExplorerFolderIgnores $folder|Out-Null
$upgraded=Get-DiskExplorerUpgradedPolicy $oldPolicy
Assert ([IO.File]::ReadAllText($ignoreFile) -ceq $upgraded -and [IO.File]::ReadAllText((Get-SelectionPolicyFile $project)) -ceq $upgraded) 'managed selective policy and receipt upgraded together'
Assert ($upgraded.EndsWith("// RemoteDisk selective v1`n!/docs`n!/docs/**`n*`n")) 'selective include/exclude suffix is preserved'
# Interrupted between db/ignores and receipt: exact expected upgrade is recoverable.
Save-SelectionPolicy $project $oldPolicy;$before=$script:ignorePosts
Ensure-DiskExplorerFolderIgnores $folder|Out-Null
Assert ($script:ignorePosts -eq $before -and [IO.File]::ReadAllText((Get-SelectionPolicyFile $project)) -ceq $upgraded) 'interrupted native ignore upgrade recovers its receipt without changing rules'
Write-DiskUtf8 $ignoreFile 'foreign rules'
Assert (Refuses {Ensure-DiskExplorerFolderIgnores $folder}) 'foreign ignore file rejected'
Assert ([IO.File]::ReadAllText($ignoreFile) -ceq 'foreign rules' -and $script:ignorePosts -eq $before) 'foreign ignores unchanged and no REST mutation'
[IO.File]::Delete($ignoreFile);[IO.File]::Delete((Get-SelectionPolicyFile $project))
# The batch returns only positively confirmed physical paths, for the tray's proof guard.
function Read-DiskState {}
Write-DiskUtf8 (Join-Path $script:DiskHome 'server.txt') 'PEER'
Write-DiskUtf8 $ignoreFile $oldTemplate;$script:loadedRules=$oldTemplate.TrimEnd("`n") -split "`n"
$unknown=Join-Path $base 'Unknown';[void][IO.Directory]::CreateDirectory($unknown);Write-DiskUtf8 (Join-Path $unknown '.stignore') 'foreign rules'
$script:mockFolders=@(
    [pscustomobject]@{id='project';path=$project;label='Project';devices=@(@{deviceID='PEER'})},
    [pscustomobject]@{id='unknown';path=$unknown;label='Unknown';devices=@(@{deviceID='PEER'})},
    [pscustomobject]@{id='outside';path=$outside;label='Outside';devices=@(@{deviceID='PEER'})}
)
$confirmed=@(Ensure-DiskExplorerIgnores $base)
Assert ($confirmed.Count -eq 1 -and $confirmed[0] -ceq $project) 'batch proof includes only confirmed top-level shared project'
Assert ([IO.File]::ReadAllText((Join-Path $unknown '.stignore')) -ceq 'foreign rules') 'batch leaves foreign ignores unchanged'
Write-DiskExternal @([pscustomobject]@{path=$outside;remote='Outside';direction='both';junction=(Join-Path $base 'Outside')})
$script:outsideRules=@()
$confirmed=@(Ensure-DiskExplorerIgnores $base)
Assert ($confirmed.Count -eq 2 -and $outside -cin $confirmed) 'explicit configured external target gets confirmed without traversing its junction'
$proofs=@(Ensure-DiskExplorerIgnores $base -Proofs)
Assert ($proofs.Count -eq 2 -and @($proofs|Where-Object {$_.sha256 -cne (Get-DiskExplorerProofHash $template)}).Count -eq 0) 'batch proof mode returns trusted hashes for each confirmed source'
Assert ([IO.File]::ReadAllText((Join-Path $outside 'deep/private.txt')) -ceq 'do not enumerate') 'external data remains untouched by ignore preparation' 
[IO.File]::Delete($ignoreFile);[IO.File]::Delete((Join-Path $unknown '.stignore'));[IO.Directory]::Delete($unknown,$false)
# Cleanup uses thin HKCU/native wrappers; no real registry is touched by this test.
$script:registry=@{};$script:notifications=0
function Get-DiskNavPaneValue([string]$Key,[string]$Name){$script:registry[$Key+'|'+$Name]}
function Remove-DiskNavPaneKey([string]$Key){foreach($k in @($script:registry.Keys)){if($k.StartsWith($Key+'|')){$script:registry.Remove($k)}}}
function Update-DiskNavPaneShell {}
function Update-DiskExplorerItem([string]$Path){$script:notifications++}
[IO.File]::WriteAllText((Join-Path $script:DiskHome 'base.txt'),$base)
[IO.File]::WriteAllText($ini,$owned,$utf8)
[IO.File]::WriteAllText((Join-Path $outside 'desktop.ini'),$owned.Replace('Placeholder=1','Placeholder=0'),$utf8)
[IO.File]::SetAttributes($project,([IO.File]::GetAttributes($project) -bor [IO.FileAttributes]::ReadOnly))
$foreign=Join-Path $base 'Foreign';[void][IO.Directory]::CreateDirectory($foreign)
$foreignIni=Join-Path $foreign 'desktop.ini';[IO.File]::WriteAllText($foreignIni,'foreign customization')
$script:registry['Software\Classes\Directory\shell\RemoteAgents.Disk.download|RemoteAgentsOwner']='RemoteAgents.Disk.v1'
$script:registry['Software\Classes\Directory\shell\RemoteAgents.Disk.add|RemoteAgentsOwner']='Other.Application'
$icons=Join-Path $env:LOCALAPPDATA 'RemoteAgents/icons';[void][IO.Directory]::CreateDirectory($icons)
[IO.File]::WriteAllText((Join-Path $icons 'RemoteAgents.Disk.v1.Synced.ico'),'owned')
[IO.File]::WriteAllText((Join-Path $icons 'foreign.ico'),'foreign')
Remove-DiskExplorer $base
Assert (-not [IO.File]::Exists($ini) -and -not ([IO.File]::GetAttributes($project) -band [IO.FileAttributes]::ReadOnly)) 'cleanup removes own ini and restores original folder attribute'
Assert ([IO.File]::ReadAllText($foreignIni) -ceq 'foreign customization') 'cleanup preserves foreign desktop.ini'
Assert (-not $script:registry.ContainsKey('Software\Classes\Directory\shell\RemoteAgents.Disk.download|RemoteAgentsOwner') -and $script:registry.Count -eq 1) 'cleanup removes only owner-marked shell keys'
Assert (-not [IO.File]::Exists((Join-Path $icons 'RemoteAgents.Disk.v1.Synced.ico')) -and [IO.File]::Exists((Join-Path $icons 'foreign.ico'))) 'cleanup removes only own known icons'
Assert (-not [IO.File]::Exists((Join-Path $outside 'desktop.ini')) -and [IO.File]::Exists((Join-Path $outside 'deep/private.txt'))) 'cleanup removes only explicit external metadata and preserves its data'
Assert ($script:notifications -eq 2) 'metadata cleanup notifies each changed folder once'
Remove-DiskExplorer $base
Assert ($script:registry.Count -eq 1 -and $script:notifications -eq 2) 'repeated cleanup is idempotent'
# ReadOnly originally set by user stays set.
[IO.File]::WriteAllText($ini,$owned.Replace('OriginalReadOnly=0','OriginalReadOnly=1'),$utf8)
[IO.File]::SetAttributes($project,([IO.File]::GetAttributes($project) -bor [IO.FileAttributes]::ReadOnly))
Remove-DiskExplorerFolderMetadata $project
Assert ([IO.File]::GetAttributes($project) -band [IO.FileAttributes]::ReadOnly) 'cleanup preserves original ReadOnly'
[IO.File]::SetAttributes($project,([IO.File]::GetAttributes($project) -band (-bnot [IO.FileAttributes]::ReadOnly)))
[IO.File]::WriteAllText($ini,$owned.Replace('OriginalReadOnly=0','OriginalReadOnly=1'),$utf8)
Remove-DiskExplorerFolderMetadata $project
Assert ([IO.File]::GetAttributes($project) -band [IO.FileAttributes]::ReadOnly) 'cleanup restores recorded ReadOnly even if it was cleared after decoration'
[IO.File]::SetAttributes($project,([IO.File]::GetAttributes($project) -band (-bnot [IO.FileAttributes]::ReadOnly)))
# Disable removes presentation while retaining the explicit source link for re-enable.
$externalLink=Join-Path $base 'Outside'
[void](New-Item -ItemType $linkKind -Path $externalLink -Target $outside)
[IO.File]::WriteAllText((Join-Path $outside 'desktop.ini'),$owned.Replace('Placeholder=1','Placeholder=0'),$utf8)
Remove-DiskExplorer $base -KeepJunctions
Assert (([IO.File]::GetAttributes($externalLink) -band [IO.FileAttributes]::ReparsePoint) -and -not [IO.File]::Exists((Join-Path $outside 'desktop.ini'))) 'disable removes external presentation and preserves its junction for re-enable'
Remove-DiskExplorer $base
Assert (-not (Test-DiskExternalEntry $externalLink) -and [IO.File]::Exists((Join-Path $outside 'deep/private.txt'))) 'uninstall unlinks the owned external junction and preserves source files'
$env:LOCALAPPDATA=$oldLocal
Write-Output ('PASS: Explorer Disk PowerShell: '+$count+' checks (CRLF placeholder, native ignore upgrade, junction guards, cleanup)')
