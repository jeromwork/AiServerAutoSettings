#requires -Version 5.1
param([string]$TestHome,[string]$Common)
$ErrorActionPreference='Stop'
if(-not $TestHome){$TestHome=Join-Path ([IO.Path]::GetTempPath()) ('disk-accept-'+[guid]::NewGuid().ToString('N'))}
if(-not $Common){$Common=Join-Path $PSScriptRoot 'Disk.Common.ps1'}
. $Common
$oldLocal=$env:LOCALAPPDATA;$oldUser=$env:USERPROFILE
$env:LOCALAPPDATA=Join-Path $TestHome 'local';$env:USERPROFILE=Join-Path $TestHome 'user'
$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'
$count=0
function Assert($Value,[string]$Label){if(-not $Value){throw ('FAIL: '+$Label)};$script:count++}
function Refuses([scriptblock]$Action){try{& $Action|Out-Null;return $false}catch{return $true}}
try{
    $base=Get-DiskBase;[void][IO.Directory]::CreateDirectory($base)
    [void][IO.Directory]::CreateDirectory($script:DiskHome)
    Write-DiskUtf8 (Join-Path $script:DiskHome 'server.txt') 'PEER'
    $script:folders=@();$script:offers=@{};$script:posts=0;$script:polls=0;$script:patches=0
    $script:defaults=@{fsWatcherDelayS=10;rescanIntervalS=777}
    function Invoke-DiskApi($Route,$Method='GET',$Body=$null){
        switch -Wildcard ($Route){
            'config/folders' {
                if($Method -eq 'GET'){return $script:folders}
                Assert ($Method -ceq 'POST') 'collection uses POST'
                $script:posts++;$script:folders+=@($Body);return
            }
            'cluster/pending/folders' {$script:polls++;return $script:offers}
            'config/defaults/folder' {
                if($Method -eq 'GET'){return $script:defaults}
                $script:defaults.fsWatcherDelayS=$Body.fsWatcherDelayS;return
            }
            'config/folders/*' {
                Assert ($Method -ceq 'PATCH') 'migration uses PATCH'
                $id=[Uri]::UnescapeDataString($Route.Substring('config/folders/'.Length))
                $f=@($script:folders|Where-Object {$_.id -ceq $id})[0]
                foreach($k in $Body.Keys){$f[$k]=$Body[$k]};$script:patches++;return
            }
            default {throw ('Unexpected REST '+$Route)}
        }
    }
    $script:now=0.0
    function Get-DiskNowMilliseconds { $script:now }
    function Start-Sleep { param($Milliseconds) $script:now+=$Milliseconds }
    # H02 / 10d: a timeout cannot become a new upload intention.
    $waiting=Join-Path $base 'Waiting'
    Accept-DiskFolders @(@{id='Waiting';path=$waiting}) 'PEER' 'LOCAL'
    Assert ($script:posts -eq 0 -and -not [IO.Directory]::Exists($waiting)) 'timeout waits for server: no ID, no registration, no folder'
    Assert ([IO.File]::ReadAllText((Join-Path $script:DiskHome 'install.log')).Contains('Ожидает сервер')) 'waiting state is journalled'
    $script:offers=@{'disk-server-id'=@{offeredBy=@{PEER=@{label='Waiting'}}}}
    Accept-DiskFolders @(@{id='Waiting';path=$waiting}) 'PEER' 'LOCAL'
    Assert ($script:posts -eq 1 -and $script:folders[0].id -ceq 'disk-server-id') 'late offer uses original server ID'
    Assert ($script:folders[0].versioning.params.maxAge -ceq '2592000') '30 day version policy'
    Accept-DiskFolders @(@{id='Waiting';path=$waiting}) 'PEER' 'LOCAL'
    Assert ($script:posts -eq 1) 'repeat acceptance does not duplicate'
    # Q7: installer cannot silently merge a local copy.
    $copy=Join-Path $base 'Copy';[void][IO.Directory]::CreateDirectory($copy)
    Write-DiskUtf8 (Join-Path $copy 'only-local.txt') 'keep'
    $script:offers=@{'server-copy'=@{offeredBy=@{PEER=@{label='Copy'}}}}
    Accept-DiskFolders @(@{id='Copy';path=$copy}) 'PEER' 'LOCAL'
    Assert ($script:posts -eq 1 -and [IO.File]::ReadAllText((Join-Path $copy 'only-local.txt')) -ceq 'keep') 'nonempty copy requires explicit Explorer merge'
    # H17 applies to the installer as well as Explorer.
    $retired=Join-Path $script:DiskHome 'explorer-retired-PEER.json'
    Write-DiskUtf8 $retired '{"peer":"PEER","removed":{"old-id":{"path":"unused","name":"Tomb"}}}'
    $script:offers=@{'old-id'=@{offeredBy=@{PEER=@{label='Tomb'}}}}
    $tomb=Join-Path $base 'Tomb'
    Accept-DiskFolders @(@{id='Tomb';path=$tomb}) 'PEER' 'LOCAL'
    Assert ($script:posts -eq 1 -and -not [IO.Directory]::Exists($tomb)) 'retired ID is never accepted again by installer'
    $journal=Join-Path $script:DiskHome 'disk-operations.json';$saved=[IO.File]::ReadAllText($journal)
    Write-DiskUtf8 $journal '{broken'
    Assert (Refuses {Accept-DiskFolders @(@{id='Tomb';path=$tomb}) 'PEER' 'LOCAL'}) 'corrupt operation journal blocks installer before mutation'
    Write-DiskUtf8 $journal $saved
    # H13: same admission for AcceptFile and the imperative helper.
    foreach($path in @($base,$env:USERPROFILE,(Join-Path $TestHome 'External'),(Join-Path $waiting 'Nested'))){
        Assert (Refuses {Assert-DiskAcceptPath $path @()}) 'root, parent, external and nested refused'
        $accept=Join-Path $TestHome 'accept.json';Write-DiskUtf8 $accept (@{folders=@(@{id='Bad';path=$path})}|ConvertTo-Json -Depth 10)
        Assert (Refuses {Read-DiskAcceptFile $accept}) 'AcceptFile shares path restriction'
    }
    # H11: BOM/CRLF and negations cannot precede mandatory rules; duplicates removed.
    $ignore=Join-Path $waiting '.stignore'
    [IO.File]::WriteAllText($ignore,"!**`r`n#include .stignore-remoteagents`r`n!.env`r`n",(New-Object Text.UTF8Encoding($true)))
    Set-DiskFolderIgnores $waiting
    $text=[IO.File]::ReadAllText($ignore)
    Assert ($text.StartsWith("#include .stignore-remoteagents`r`n!**`r`n") -and ([regex]::Matches($text,'#include .stignore-remoteagents')).Count -eq 1 -and $text.Contains("!.env`r`n")) 'mandatory first; user rules retained; no duplicate'
    $once=[IO.File]::ReadAllBytes($ignore);Set-DiskFolderIgnores $waiting
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($ignore)) -ceq [Convert]::ToBase64String($once)) 'ignore migration idempotent'
    # A folder accepted manually in Tray is not in AcceptFile; startup still migrates it.
    $tray=Join-Path $base 'Tray';[void][IO.Directory]::CreateDirectory($tray)
    Write-DiskUtf8 (Join-Path $tray '.stignore') '!**'
    $script:folders+=@(@{id='tray-id';path=$tray;type='receiveonly';paused=$true;maxConflicts=7;devices=@(@{deviceID='PEER'});fsWatcherDelayS=10})
    Set-DiskWatcherDelay
    $f=$script:folders[1]
    Assert ([IO.File]::ReadAllText((Join-Path $tray '.stignore')).StartsWith('#include .stignore-remoteagents')) 'Tray folder receives policy'
    Assert ($f.paused -and $f.type -ceq 'receiveonly' -and $f.versioning.params.maxAge -ceq '2592000' -and $f.maxConflicts -eq -1 -and $f.fsWatcherDelayS -eq 2) 'migration preserves user pause/type and applies versions'
    $managed=Join-Path $tray '.stignore-remoteagents';[IO.File]::Delete($managed)
    $target=Join-Path $TestHome 'link-target';Write-DiskUtf8 $target 'untouched'
    [void](New-Item -ItemType SymbolicLink -Path $managed -Target $target)
    Assert (Refuses {Set-DiskFolderIgnores $tray}) 'no writes through links'
    Assert ([IO.File]::ReadAllText($target) -ceq 'untouched') 'link target unchanged'
    Write-Output ('PASS: '+$count+' Disk acceptance/policy/path checks; isolated HOME, local REST fixture, virtual 30-second timeout')
}finally{$env:LOCALAPPDATA=$oldLocal;$env:USERPROFILE=$oldUser}
