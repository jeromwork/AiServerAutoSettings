#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
if(-not $TestHome){$TestHome=Join-Path ([IO.Path]::GetTempPath()) ('disk-choice-'+[guid]::NewGuid().ToString('N'))}
[void][IO.Directory]::CreateDirectory($TestHome)
$oldLocal=$env:LOCALAPPDATA;$env:LOCALAPPDATA=Join-Path $TestHome 'local'
$fixture=Join-Path $TestHome 'bundle/disk';[void][IO.Directory]::CreateDirectory($fixture)
Get-ChildItem (Join-Path $repo 'disk') -File|Where-Object {$_.Extension -in @('.ps1','.sh') -or $_.Name -like 'stignore*'}|Copy-Item -Destination $fixture
$fake=@'
# Production uses an NTFS junction; the portable fixture substitutes a symlink via the narrow wrapper.
function New-DiskExternalJunction([string]$Link,[string]$Target) {$kind='SymbolicLink';if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){$kind='Junction'};[void](New-Item -ItemType $kind -Path $Link -Target $Target)}
function Remove-DiskExternalJunction([string]$Link) {if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){[IO.Directory]::Delete($Link,$false)}else{[IO.File]::Delete($Link)}}
function Read-DiskProfile {}
function Read-DiskState {}
function Write-DiskLog {}
function Invoke-DiskSsh {''}
function Invoke-DiskServer($Action,$Data) {
    switch($Action){
        'tree' {return @{schema=1;folders=@($global:ServerFolders|ForEach-Object {@{name=$_.name;hasChildren=$true}})}}
        'list' {return $global:ServerFolders}
        'attach' {[void]$global:Attaches.Add($Data);if($Data.name -ceq 'Broken'){throw 'Сервер отказал: проверка'};return @{ok=$true}}
        default {throw ('unexpected server action '+$Action)}
    }
}
function Invoke-DiskApi($Route,$Method='GET',$Body=$null) {
    [void]$global:Calls.Add(@{route=$Route;method=$Method;body=$Body})
    switch -Wildcard ($Route){
        'system/status' {return [pscustomobject]@{myID='LOCAL'}}
        'config/defaults/folder' {
            if($Method -eq 'PATCH'){$global:Defaults.path=$Body.path;return}
            return [pscustomobject]@{id='';label='';path=$global:Defaults.path;type='sendreceive';paused=$false;devices=@();maxConflicts=10}
        }
        'config/devices/*' {return [pscustomobject]@{autoAcceptFolders=$false}}
        'cluster/pending/folders' {return $global:Pending}
        'config/folders' {return $global:Folders.Values}
        'config/folders/*' {
            $id=[Uri]::UnescapeDataString($Route.Substring('config/folders/'.Length))
            if($Method -eq 'DELETE'){[void]$global:Folders.Remove($id);return}
            if($Method -eq 'PUT'){$global:Folders[$id]=$Body;return}
            if(-not $global:Folders.ContainsKey($id)){throw ('missing folder '+$id)}
            $folder=$global:Folders[$id]
            if($Method -eq 'PATCH'){foreach($key in $Body.Keys){$folder.$key=$Body[$key]};return}
            return $folder
        }
        'db/status?*' {
            $id=[Uri]::UnescapeDataString($Route.Substring('db/status?folder='.Length));$state='idle'
            if($global:Folders[$id].paused){$state=''}
            return @{state=$state;receiveOnlyTotalItems=$global:LocalChanges}
        }
        'db/revert?*' {if($Method -ne 'POST'){throw 'revert must POST'};return}
        default {throw ('unexpected API route '+$Route)}
    }
}
'@
[IO.File]::AppendAllText((Join-Path $fixture 'Disk.Common.ps1'),$fake,(New-Object Text.UTF8Encoding($true)))
. (Join-Path $fixture 'Disk.Common.ps1')
. (Join-Path $fixture 'Disk.Union.ps1')
$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk';[void][IO.Directory]::CreateDirectory((Join-Path $script:DiskHome 'state'))
[IO.File]::WriteAllText((Join-Path $script:DiskHome 'server.txt'),'PEER')
[IO.File]::WriteAllText((Join-Path $script:DiskHome 'state/config.xml'),'<fixture/>')
$base=Join-Path $TestHome 'Disk';$project=Join-Path $base 'Project';[void][IO.Directory]::CreateDirectory((Join-Path $project '.stfolder'))
[IO.File]::WriteAllText((Join-Path $project 'local.txt'),'unsent local version')
[IO.File]::WriteAllText((Join-Path $script:DiskHome 'base.txt'),$base)
$global:Folders=@{project=[pscustomobject]@{id='project';label='Project';path=$project;type='sendreceive';paused=$false;devices=@(@{deviceID='PEER'});maxConflicts=-1;versioning=@{type='staggered';params=@{maxAge='0'}}}}
$global:ServerFolders=@([pscustomobject]@{name='Project';id='project';hasFiles=$true})
$global:Defaults=@{path=$base};$global:Pending=[pscustomobject]@{};$global:LocalChanges=3;$global:Calls=New-Object Collections.ArrayList;$global:Attaches=New-Object Collections.ArrayList
$progress=Join-Path $TestHome 'progress.jsonl';$env:REMOTEAGENTS_WIZARD_PROGRESS=$progress
function Get-Progress {if(Test-Path -LiteralPath $progress){[IO.File]::ReadAllText($progress)}else{''}}
$count=0
function Assert($Value,[string]$Label){if(-not $Value){throw ('FAIL: '+$Label)};$script:count++}
function Reject([scriptblock]$Run,[string]$Reason){$caught=$false;try{& $Run}catch{$caught=$_.Exception.Message -like ('*'+$Reason+'*')};Assert $caught ('reject '+$Reason)}
function Apply($Paths,$Directions=@{},$External=@()){
    $file=Join-Path $TestHome 'request.json'
    [IO.File]::WriteAllText($file,((@{schema=1;paths=@($Paths);directions=$Directions;external=@($External)}|ConvertTo-Json -Depth 20 -Compress)+"`r`n"))
    & (Join-Path $fixture 'Select-Disk.ps1') -Action Apply -SelectionFile $file | Out-Null
}
try{
    foreach($pair in @(@('send','sendonly'),@('receive','receiveonly'),@('both','sendreceive'))){
        Apply @('Project') @{Project=$pair[0]}
        Assert ($global:Folders.project.type -ceq $pair[1]) ('project type '+$pair[0])
        Assert ([IO.File]::ReadAllText((Join-Path $project 'local.txt')) -ceq 'unsent local version') ('type change keeps files '+$pair[0])
        $before=@($global:Calls|Where-Object {$_.method -eq 'PATCH' -and $_.body.ContainsKey('type')}).Count
        Apply @('Project') @{Project=$pair[0]}
        Assert (@($global:Calls|Where-Object {$_.method -eq 'PATCH' -and $_.body.ContainsKey('type')}).Count -eq $before) ('idempotent type '+$pair[0])
    }
    Apply @('Project') @{Project='receive'}
    $union=Get-DiskUnion (Invoke-DiskServer tree) $base
    Assert ($union.rows[0] -is [pscustomobject] -and -not $union.rows[0].PSObject.Properties['direction']) 'real tree row initially has no direction'
    Add-DiskTreeState $union $base
    Add-DiskTreeState $union $base
    Assert ($union.rows[0].direction -ceq 'receive' -and $union.rows[0].localChanges -eq 3) 'tree direction and local changes'
    $reply=Invoke-DiskRevert 'Project'
    Assert ($reply.ok -and @($global:Calls|Where-Object {$_.method -eq 'POST' -and $_.route -ceq 'db/revert?folder=project'}).Count -eq 1) 'revert POST correct folder'
    Reject {Invoke-DiskRevert '../Project'} 'Недопустимое имя'
    Apply @('Project') @{Project='send'}
    Reject {Invoke-DiskRevert 'Project'} 'только забирать'
    Assert (@($global:Calls|Where-Object {$_.method -eq 'DELETE'}).Count -eq 0) 'type changes never deregister'
    Apply @('Project/docs') @{Project='receive'}
    Assert ((Test-Path (Join-Path $project 'local.txt')) -and [IO.File]::ReadAllText((Join-Path $project '.stignore')).Contains('!/docs')) 'partial deselection keeps unselected files'
    $outside=Join-Path $TestHome 'Reports';[void][IO.Directory]::CreateDirectory($outside);[IO.File]::WriteAllText((Join-Path $outside 'report.txt'),'external local data')
    $global:ServerFolders+=@([pscustomobject]@{name='Reports';id='reports';hasFiles=$false})
    $entry=@{path=$outside;remote='Reports';direction='send'}
    [void][IO.Directory]::CreateDirectory((Join-Path $base 'Reports'))
    $attachBefore=$global:Attaches.Count
    Reject {Sync-DiskExternal @($entry) $base} 'уже занято имя'
    Assert ($global:Attaches.Count -eq $attachBefore -and @(Read-DiskExternal).Count -eq 0) 'occupied junction name rejected before changing engine or receipts'
    [IO.Directory]::Delete((Join-Path $base 'Reports'),$false)
    $brokenLink=Join-Path $base 'Reports';New-DiskExternalJunction $brokenLink (Join-Path $TestHome 'absent-target')
    Reject {Sync-DiskExternal @($entry) $base} 'уже занято имя'
    Assert ($global:Attaches.Count -eq $attachBefore) 'broken junction name is rejected before server mutation'
    Remove-DiskExternalJunction $brokenLink
    Apply @('Project') @{Project='receive'} @($entry)
    Assert ($global:Folders.reports.path -eq $outside -and $global:Folders.reports.type -ceq 'sendonly') 'external added noninteractively with direction'
    Assert ((Get-DiskExternalJunctionTarget (Join-Path $base 'Reports')) -eq $outside) 'external has a junction in Disk'
    Assert (@((Get-DiskUnion ([pscustomobject]@{entries=@()}) $base).rows|Where-Object {$_.path -eq 'Reports'}).Count -eq 0) 'external junction is not a second local project'
    $items=@(Get-DiskExternalList)
    Assert ($items.Count -eq 1 -and $items[0].remote -ceq 'Reports' -and $items[0].direction -ceq 'send' -and $items[0].state -ceq 'idle') 'external list'
    $put=@($global:Calls|Where-Object {$_.method -eq 'PUT'}).Count
    Apply @('Project') @{Project='receive'} @($entry)
    Assert (@($global:Calls|Where-Object {$_.method -eq 'PUT'}).Count -eq $put) 'external repeat does not reattach'
    $savedFolder=$global:Folders.reports;[void]$global:Folders.Remove('reports')
    $selectionFile=Join-Path $script:DiskHome 'selection.json';$savedSelection=[IO.File]::ReadAllText($selectionFile)
    Write-SelectionState $selectionFile (@{schema=1;paths=@('.')}|ConvertTo-Json -Compress)
    $global:Pending=[pscustomobject]@{reports=[pscustomobject]@{offeredBy=[pscustomobject]@{PEER=[pscustomobject]@{label='Reports'}}}}
    & (Join-Path $fixture 'Sync-RemoteDiskFolders.ps1')
    Assert (-not $global:Folders.ContainsKey('reports') -and (Get-DiskExternalJunctionTarget (Join-Path $base 'Reports')) -eq $outside) 'all never accepts detached external under Disk; its existing junction stays'
    Assert ((@(Get-DiskExternalList))[0].state -ceq 'detached') 'external list reports missing registration honestly'
    $global:Folders.reports=$savedFolder;$global:Pending=[pscustomobject]@{};Write-SelectionState $selectionFile $savedSelection
    $entry.direction='receive';Apply @('Project') @{Project='receive'} @($entry)
    Assert ($global:Folders.reports.type -ceq 'receiveonly' -and @($global:Calls|Where-Object {$_.method -eq 'PUT'}).Count -eq $put) 'external direction changes by patch'
    Apply @('Project') @{Project='receive'} @()
    Assert (-not $global:Folders.ContainsKey('reports') -and @(Read-DiskExternal).Count -eq 0 -and -not (Test-Path (Join-Path $base 'Reports'))) 'external removed from PC configuration and only its junction unlinked'
    Assert ([IO.File]::ReadAllText((Join-Path $outside 'report.txt')) -ceq 'external local data') 'external removal keeps files'
    $global:Pending=[pscustomobject]@{reports=[pscustomobject]@{offeredBy=[pscustomobject]@{PEER=[pscustomobject]@{label='Reports'}}}}
    Apply @('.') @{Project='receive'} @()
    Assert (-not $global:Folders.ContainsKey('reports') -and -not (Test-Path (Join-Path $base 'Reports'))) 'removed external stays excluded from all after its receipt is removed'
    & (Join-Path $fixture 'Sync-RemoteDiskFolders.ps1')
    Assert (-not $global:Folders.ContainsKey('reports')) 'removed external stays excluded on periodic sync'
    $global:Pending=[pscustomobject]@{}
    $entry.direction='both';$global:ServerFolders[1].hasFiles=$true
    Apply @('Project') @{} @($entry)
    Assert ($global:Folders.reports.path -eq $outside -and $global:Attaches[-1].merge -and [IO.File]::ReadAllText((Join-Path $outside 'report.txt')) -ceq 'external local data') 'occupied external is merged without a question and keeps files'
    Assert ((Get-Progress).Contains('Объединяю «Reports»') -and (Get-Progress).Contains('ничего не удаляется')) 'merge is announced in plain words'
    $put=@($global:Calls|Where-Object {$_.method -eq 'PUT' -and $_.body.label -ceq 'Reports'})[-1].body
    Assert (@($global:Calls|Where-Object {$_.method -eq 'PATCH' -and $_.body.Contains('paused')}).Count -and $put.maxConflicts -eq -1 -and $put.versioning.type -ceq 'staggered' -and [string]$put.versioning.params.maxAge -ceq '0') 'local side gets unlimited conflicts and versioning before the first sync'
    Reject {Sync-DiskExternal @(@{path=$project;remote='Project';direction='both'}) $base} 'пересекается с корнем Disk'
    $link=Join-Path $TestHome 'linked';[void](New-Item -ItemType SymbolicLink -Path $link -Target $outside)
    Reject {Sync-DiskExternal @(@{path=$link;remote='Linked';direction='both'}) $base} 'Ссылки в пути'
    Apply @() @{} @()
    Assert (-not $global:Folders.ContainsKey('project') -and (Test-Path (Join-Path $project 'local.txt'))) 'deselected project detached with files on disk'
    # Changed identity is not a reconnect: the folders are merged (announced), never refused.
    $global:ServerFolders[0].id='different-id';[IO.File]::WriteAllText($progress,'')
    Apply @('Project') @{Project='receive'} @()
    Assert ($global:Folders.ContainsKey('different-id') -and (Get-Progress).Contains('Объединяю «Project»')) 'changed server ID merges instead of refusing'
    [void]$global:Folders.Remove('different-id');$global:ServerFolders[0].id='project'
    [IO.File]::WriteAllText((Join-Path $script:DiskHome 'server.txt'),'OTHER-PEER');[IO.File]::WriteAllText($progress,'')
    Apply @('Project') @{Project='receive'} @()
    Assert ($global:Folders.ContainsKey('project') -and (Get-Progress).Contains('Объединяю «Project»')) 'changed peer merges instead of refusing'
    [void]$global:Folders.Remove('project')
    [IO.File]::WriteAllText((Join-Path $script:DiskHome 'server.txt'),'PEER');[IO.File]::WriteAllText($progress,'')
    Apply @('Project') @{Project='receive'} @()
    Assert ($global:Folders.project.path -eq $project -and $global:Folders.project.type -ceq 'receiveonly' -and -not (Get-Progress).Contains('Объединяю')) 'same project reattaches as a reconnect, not a merge'
    Assert ([IO.File]::ReadAllText((Join-Path $project 'local.txt')) -ceq 'unsent local version') 'reattach preserves existing local data'
    # One failing folder does not stop the others; the summary names it; only applied folders are saved.
    Apply @() @{} @()
    $broken=Join-Path $base 'Broken';[void][IO.Directory]::CreateDirectory($broken);[IO.File]::WriteAllText((Join-Path $broken 'mine.txt'),'local broken data')
    $global:ServerFolders+=@([pscustomobject]@{name='Broken';id='broken';hasFiles=$true});[IO.File]::WriteAllText($progress,'')
    $message='';try{Apply @('Broken','Project') @{} @()}catch{$message=$_.Exception.Message}
    Assert ($message.Contains('«Broken» — Сервер отказал: проверка') -and -not $message.Contains('«Project»')) ('summary lists the failed folder with its reason: '+$message)
    Assert ($global:Folders.ContainsKey('project') -and -not @($global:Folders.Values|Where-Object {$_.label -ceq 'Broken'}).Count) 'other folders are applied after a failure'
    Assert (@((Read-DiskSelection).paths) -ceq 'Project' -and [IO.File]::ReadAllText((Join-Path $broken 'mine.txt')) -ceq 'local broken data') 'only applied folders are saved; failed folder files kept'
    Assert ((Get-Progress).Contains('Не подключена папка «Broken»')) 'failure reaches the journal per folder'
    Remove-Item -LiteralPath $broken -Recurse -Force;$global:ServerFolders=@($global:ServerFolders|Where-Object {$_.name -cne 'Broken'})
    Apply @() @{} @()
    # Automatic accept of a new server folder merges into an existing local folder of the same name.
    $busy=Join-Path $base 'Busy';[void][IO.Directory]::CreateDirectory($busy);[IO.File]::WriteAllText((Join-Path $busy 'keep.txt'),'busy local')
    $savedSelection=[IO.File]::ReadAllText($selectionFile);Write-SelectionState $selectionFile (@{schema=1;paths=@('.')}|ConvertTo-Json -Compress)
    $global:Pending=[pscustomobject]@{busy=[pscustomobject]@{offeredBy=[pscustomobject]@{PEER=[pscustomobject]@{label='Busy'}}}}
    & (Join-Path $fixture 'Sync-RemoteDiskFolders.ps1')
    Assert ($global:Folders.busy.path -eq $busy -and $global:Folders.busy.maxConflicts -eq -1 -and [IO.File]::ReadAllText((Join-Path $busy 'keep.txt')) -ceq 'busy local') 'occupied local folder is merged on automatic accept'
    [void]$global:Folders.Remove('busy');Remove-Item -LiteralPath $busy -Recurse -Force;$global:Pending=[pscustomobject]@{};Write-SelectionState $selectionFile $savedSelection
    Assert ((Get-ProjectSelection 'Future' ([pscustomobject]@{paths=@('.')})) -ceq '.') 'all includes future projects'
    Assert (@(Get-ProjectSelection 'Future' ([pscustomobject]@{paths=@()})).Count -eq 0) 'none excludes future projects'
    $global:Pending=[pscustomobject]@{future=[pscustomobject]@{offeredBy=[pscustomobject]@{PEER=[pscustomobject]@{label='Future'}}}}
    $global:ServerFolders[0].hasFiles=$false
    $rootFile=Join-Path $base 'readme.txt';[IO.File]::WriteAllText($rootFile,'root file stays local')
    Reject {Apply @('readme.txt') @{} @()} 'Файлы в корне Disk'
    Apply @('.') @{} @()
    Assert ($global:Folders.future.type -ceq 'sendreceive' -and $global:Folders.future.path -eq (Join-Path $base 'Future')) 'all autoaccepts new project'
    Assert ((Read-DiskSelection).paths[0] -ceq '.') 'all policy persisted'
    Assert ([IO.File]::ReadAllText($rootFile) -ceq 'root file stays local' -and -not @($global:Folders.Values|Where-Object {$_.path -eq $base -or $_.path -eq $rootFile}).Count) 'all ignores root files and never registers Disk root'
    $global:Pending=[pscustomobject]@{reports=[pscustomobject]@{offeredBy=[pscustomobject]@{PEER=[pscustomobject]@{label='Reports'}}}}
    Apply @('Project','Reports') @{Reports='send'} @()
    Assert ($global:Folders.reports.path -eq (Join-Path $base 'Reports') -and $global:Folders.reports.type -ceq 'sendonly') 'explicit project choice can reconnect a removed external under Disk'
    Apply @('.') @{Reports='send'} @()
    Assert ($global:Folders.reports.type -ceq 'sendonly') 'explicit project choice clears exclusion for later all'
    Assert ([IO.File]::ReadAllText((Join-Path $outside 'report.txt')) -ceq 'external local data' -and [IO.File]::ReadAllText($rootFile) -ceq 'root file stays local') 'explicit reconnect and repeated all keep external and root files'

    Assert (@($global:Calls|Where-Object {$_.route -like '*override*' -or $_.route -like '*reset*'}).Count -eq 0) 'no override/reset APIs'
    Write-Output ('PASS: DiskChoice PowerShell: '+$count+' checks (fake API, actual Select/Add/Sync, direction, revert, external)')
}finally{$env:LOCALAPPDATA=$oldLocal;Remove-Item Env:REMOTEAGENTS_WIZARD_PROGRESS -ErrorAction SilentlyContinue}
