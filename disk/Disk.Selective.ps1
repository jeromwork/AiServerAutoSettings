#requires -Version 5.1
# Local selection belongs to the device; .stignore never syncs to the server.
function Assert-SelectionPath([string]$Value) {
    if(-not $Value -or $Value.Contains('\') -or $Value -match '[\x00-\x1f<>:"|?*]' -or $Value.StartsWith('/') -or @($Value.Split('/')|Where-Object {$_ -in @('','.','..') -or $_ -match '[ .]$|^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'}).Count){throw 'Недопустимый путь выбора'}
}
function Get-SelectionPaths($Selection) {
    $paths=@($Selection.paths|ForEach-Object {([string]$_).Replace("`r",'').TrimEnd('/') }|Sort-Object -Unique)
    foreach($p in $paths){if($p -cne '.'){Assert-SelectionPath $p}};$paths
}
function Test-SelectionIncluded([string]$Path,$Paths) {
    if('.' -cin @($Paths)){return $true}
    foreach($p in @($Paths)){if($Path -ceq $p -or $Path.StartsWith($p+'/',[StringComparison]::Ordinal)){return $true}};return $false
}
# Cache once per process; a tree level must not reopen stignore for every entry.
$script:SelectionProtectedPatterns=@([IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'stignore.txt'))|Where-Object {$_.StartsWith('(?i)')}|ForEach-Object {$_.Substring(4)})
function Test-SelectionProtected([string]$Path) {
    foreach($pattern in $script:SelectionProtectedPatterns){
        if($pattern.StartsWith('/')){
            $rootPattern=$pattern.Substring(1)
            if($Path -like $rootPattern -or $Path -like ($rootPattern+'/*')){return $true}
        }
    }
    foreach($part in $Path.Split('/')){
        if($part -in @('.stignore','.stfolder','.stversions')){return $true}
        foreach($pattern in $script:SelectionProtectedPatterns){if($part -like $pattern){return $true}}
    };return $false
}
function Escape-SelectionPattern([string]$Path) { [regex]::Replace($Path,'[\[\]{}!#]', {param($m) '\'+$m.Value}) }
function New-SelectionIgnores([string[]]$Paths) {
    $rules='#escape=\'+"`n"+[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'stignore.txt')).Replace("`r",'').TrimEnd("`n")+"`n// RemoteDisk selective v1`n"
    if('.' -in $Paths){return $rules}
    foreach($p in @($Paths|Sort-Object -Unique)){
        Assert-SelectionPath $p
        if(Test-SelectionProtected $p){throw 'Секреты и генерируемое не синхронизируются'}
        # Include only the selected subtree. Parents are traversable, siblings stay excluded.
        $rules+='!/'+(Escape-SelectionPattern $p)+"`n"
        $rules+='!/'+(Escape-SelectionPattern $p)+"/**`n"
    }
    $rules+"*`n"
}
function Read-DiskSelection {
    $file=Join-Path $script:DiskHome 'selection.json'
    if(Test-Path -LiteralPath $file){$value=[IO.File]::ReadAllText($file).Replace("`r",'')|ConvertFrom-Json;if($value.schema -ne 1){throw 'Неизвестный формат выбора'};return $value}
    return $null
}
function Get-ProjectSelection([string]$Name,$Selection) {
    if($null -eq $Selection -or '.' -cin @($Selection.paths)){
        # All is automatic; a removed external project requires an explicit path choice.
        if($Name -iin @(Read-DiskExternalExclusions)){return @()}
        return @('.')
    }
    $out=@();foreach($p in @(Get-SelectionPaths $Selection)){if($p -ceq $Name){return @('.')};if($p.StartsWith($Name+'/',[StringComparison]::Ordinal)){$out+=@($p.Substring($Name.Length+1))}};$out
}
function Assert-SelectionSynced($Status) {
    if($Status.state -ne 'idle'){throw 'Папка ещё не синхронизирована'}
    foreach($k in @('needBytes','needTotalItems','pullErrors','receiveOnlyChangedBytes','receiveOnlyTotalItems')){
        if($null -eq $Status.$k -or [long]$Status.$k -ne 0){throw 'Есть несинхронизированные данные'}
    }
}
function Get-SelectionFiles([string]$Root,[string]$Relative='') {
    Assert-DiskPlainPath (Join-Path $Root $Relative)
    foreach($entry in @(Get-ChildItem -LiteralPath (Join-Path $Root $Relative) -Force)){
        $rel=$entry.Name;if($Relative){$rel=$Relative+'/'+$entry.Name}
        if(Test-SelectionProtected $rel){continue}
        if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Ссылки в выборе запрещены'}
        if($entry.PSIsContainer){Get-SelectionFiles $Root $rel}else{$rel}
    }
}
function Set-ProjectSelection($Folder,[string[]]$Paths,[string[]]$KeepLocal=@()) {
    $id=[Uri]::EscapeDataString($Folder.id);$root=$Folder.path
    for($part=[IO.Path]::GetFullPath($root);$part;$part=[IO.Path]::GetDirectoryName($part)){
        if((Test-Path -LiteralPath $part) -and ([IO.File]::GetAttributes($part) -band [IO.FileAttributes]::ReparsePoint)){throw 'Ссылки в пути запрещены'}
    }
    $ignore=Join-Path $root '.stignore'
    if((Test-Path -LiteralPath $ignore) -and ([IO.File]::GetAttributes($ignore) -band [IO.FileAttributes]::ReparsePoint)){throw 'Ссылка .stignore запрещена'}
    if($Folder.paused){throw 'Сначала продолжите синхронизацию папки'}
    # Refuse foreign policies; known managed selection includes are checked against saved policy.
    $oldSelection=Read-DiskSelection;$oldPaths=@(Get-ProjectSelection $Folder.label $oldSelection)
    $expected=New-SelectionIgnores $oldPaths
    if(Test-Path -LiteralPath $ignore){
        $actual=[IO.File]::ReadAllText($ignore).Replace("`r",'')
        if($actual -cne $expected){Test-DiskIgnores $root}
    }
    $rules=New-SelectionIgnores $Paths
    if((Test-Path -LiteralPath $ignore) -and [IO.File]::ReadAllText($ignore).Replace("`r",'') -ceq $rules){return}
    $route='config/folders/'+$id
    $pauseReceipt=(Get-SelectionPolicyFile $root)+'.paused.json'
    Write-SelectionState $pauseReceipt (@{id=$Folder.id;path=$root;paths=@()}|ConvertTo-Json -Compress)
    [void](Invoke-DiskApi $route PATCH @{paused=$true})
    $paused=$false
    for($i=0;$i -lt 30;$i++){
        $status=Invoke-DiskApi ('db/status?folder='+$id)
        if($status.state -eq '' -and (Invoke-DiskApi $route).paused){$paused=$true;break};Start-Sleep -Milliseconds 100
    }
    if(-not $paused){throw 'Пауза не подтверждена; файлы сохранены'}
    try{
        # Deselecting changes ignores only. Local files and empty directories remain, even with unsent edits.
        if(Test-Path -LiteralPath $ignore){[IO.File]::SetAttributes($ignore,([IO.File]::GetAttributes($ignore) -band (-bnot [IO.FileAttributes]::Hidden)))}
        Save-SelectionPolicy $root $rules
        Write-SelectionAtomic $ignore $rules
    }finally{[void](Invoke-DiskApi $route PATCH @{paused=$false});[IO.File]::Delete($pauseReceipt)}
}

function Get-SelectionPolicyFile([string]$Path) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$id=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Path).ToLowerInvariant())))).Replace('-','')}finally{$sha.Dispose()}
    Join-Path $script:DiskHome ('selection-policies/'+$id+'.txt')
}
function Save-SelectionPolicy([string]$Path,[string]$Rules) {
    Write-SelectionState (Get-SelectionPolicyFile $Path) $Rules
}
# Device-local identity survives deselection; a policy receipt alone proves no folder identity.
function Save-DiskDetachedProject($Folder,[string]$Peer,[string]$Device) {
    $receipt=@{schema=1;path=[IO.Path]::GetFullPath($Folder.path);remote=[string]$Folder.label;id=[string]$Folder.id;peer=$Peer;device=$Device}
    Write-SelectionState ((Get-SelectionPolicyFile $Folder.path)+'.detached.json') ($receipt|ConvertTo-Json -Compress)
}
function Test-DiskProjectReconnect([string]$Path,[string]$Remote,[string]$Id,[string]$Peer,[string]$Device) {
    $file=(Get-SelectionPolicyFile $Path)+'.detached.json'
    if(-not (Test-Path -LiteralPath $file)){return $false}
    $saved=[IO.File]::ReadAllText($file).Replace("`r",'')|ConvertFrom-Json
    return $saved.schema -eq 1 -and $saved.remote -ceq $Remote -and $saved.id -ceq $Id -and $saved.peer -ceq $Peer -and $saved.device -ceq $Device -and [IO.Path]::GetFullPath($saved.path).TrimEnd('\','/') -ieq [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
}
function Resume-InterruptedSelection {
    $directory=Join-Path $script:DiskHome 'selection-policies'
    if(-not (Test-Path -LiteralPath $directory)){return}
    foreach($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.paused.json' -File)){
        $receipt=[IO.File]::ReadAllText($file.FullName).Replace("`r",'')|ConvertFrom-Json
        $folder=Invoke-DiskApi ('config/folders/'+[Uri]::EscapeDataString([string]$receipt.id))
        if([IO.Path]::GetFullPath($folder.path) -cne [IO.Path]::GetFullPath([string]$receipt.path)){throw 'Путь прерванного выбора изменился; проверьте журнал диска'}
        # A kill can interrupt the verification move. Return staged files before resuming;
        # if an editor recreated the source, keep both versions and log the recovery copy.
        foreach($relative in @($receipt.paths)){
            Assert-SelectionPath ([string]$relative)
            $source=Join-Path $receipt.path ([string]$relative);$staged=Get-SelectionStagedFile $source $receipt.path
            foreach($value in @($source,$staged)){
                for($p=$value;$p;$p=[IO.Path]::GetDirectoryName($p)){
                    if((Test-Path -LiteralPath $p) -and ([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint)){throw 'Ссылки в прерванном выборе запрещены'}
                }
            }
            if([IO.File]::Exists($staged)){
                if(-not (Test-Path -LiteralPath $source)){[IO.File]::Move($staged,$source)}
                else{[void](Save-SelectionRecoveryCopy $staged 'Прерванный выбор: копия сохранена ')}
            }
        }
        [void](Invoke-DiskApi ('config/folders/'+[Uri]::EscapeDataString([string]$receipt.id)) PATCH @{paused=$false})
        [IO.File]::Delete($file.FullName);Write-DiskLog 'Прерванный выбор: синхронизация продолжена'
    }
}
function Write-SelectionState([string]$file,[string]$Rules) {
    [void][IO.Directory]::CreateDirectory((Split-Path $file -Parent))
    $temp=$file+'.'+[guid]::NewGuid().ToString('N')+'.tmp';$backup=$temp+'.old'
    try{
        $stream=New-Object IO.FileStream($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$bytes=[Text.Encoding]::UTF8.GetBytes($Rules.Replace("`r",''));$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        if([IO.File]::Exists($file)){[IO.File]::Replace($temp,$file,$backup)}else{[IO.File]::Move($temp,$file)}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)};if([IO.File]::Exists($backup)){[IO.File]::Delete($backup)}}
}

function Write-SelectionAtomic([string]$File,[string]$Text) {
    # Native marker directory is never synchronized; staging remains on the same volume.
    $marker=Join-Path (Split-Path $File -Parent) '.stfolder'
    if(-not [IO.Directory]::Exists($marker) -or ([IO.File]::GetAttributes($marker) -band [IO.FileAttributes]::ReparsePoint)){throw 'Нет безопасного маркера папки Syncthing'}
    $temp=Join-Path $marker ([IO.Path]::GetRandomFileName());$backup=$temp+'.old'
    try{
        $stream=New-Object IO.FileStream($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$bytes=[Text.Encoding]::UTF8.GetBytes($Text.Replace("`r",''));$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        if([IO.File]::Exists($File)){[IO.File]::Replace($temp,$File,$backup)}else{[IO.File]::Move($temp,$File)}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)};if([IO.File]::Exists($backup)){[IO.File]::Delete($backup)}}
}

function Initialize-ProjectSelection([string]$Root,[string[]]$Paths) {
    # Validate the old trusted policy BEFORE replacing its receipt. A detached
    # project may already carry a different, valid selective policy from J.
    Test-DiskIgnores $Root
    $rules=New-SelectionIgnores $Paths
    $marker=Join-Path $Root '.stfolder';[void][IO.Directory]::CreateDirectory($marker)
    Save-SelectionPolicy $Root $rules
    $ignore=Join-Path $Root '.stignore'
    if(Test-Path -LiteralPath $ignore){[IO.File]::SetAttributes($ignore,([IO.File]::GetAttributes($ignore) -band (-bnot [IO.FileAttributes]::Hidden)))}
    Write-SelectionAtomic $ignore $rules
    [IO.File]::SetAttributes($ignore,([IO.File]::GetAttributes($ignore) -bor [IO.FileAttributes]::Hidden))
}

function Get-SelectionStagedFile([string]$File,[string]$Root) {
    Join-Path (Join-Path $Root '.stfolder') ('deselected-'+[IO.Path]::GetFileNameWithoutExtension((Get-SelectionPolicyFile $File)))
}
function Save-SelectionRecoveryCopy([string]$Staged,[string]$Message) {
    # The staged name is deterministic so an interrupted move can be found again. A kept
    # version gets its own unique name, so it never blocks a later staging of the same path.
    $keep=$Staged+'.recovered-'+[DateTime]::UtcNow.ToString('yyyyMMddHHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    [IO.File]::Move($Staged,$keep);Write-DiskLog ($Message+$keep);return $keep
}

# Device-only choices. Caller holds folders.lock for every mutation.
function Get-DiskDirection($Selection,[string]$Project) {
    $value=''
    if($Selection -and $Selection.directions){
        if($Selection.directions -is [Collections.IDictionary]){$value=[string]$Selection.directions[$Project]}
        else{$property=$Selection.directions.PSObject.Properties[$Project];if($property){$value=[string]$property.Value}}
    }
    if(-not $value){return 'both'}
    if($value -cnotin @('both','send','receive')){throw ('Недопустимое направление проекта '+$Project)}
    $value
}
function Get-DiskFolderType([string]$Direction) {
    switch -CaseSensitive ($Direction){'both' {'sendreceive'} 'send' {'sendonly'} 'receive' {'receiveonly'} default {throw 'Недопустимое направление Disk'}}
}
function Get-DiskTypeDirection([string]$Type) {
    switch($Type){'sendreceive' {'both'} 'sendonly' {'send'} 'receiveonly' {'receive'} default {throw ('Неизвестный тип папки Syncthing: '+$Type)}}
}
function Set-DiskFolderDirection($Folder,[string]$Direction) {
    $type=Get-DiskFolderType $Direction
    if($Folder.type -cne $type){
        # PATCH changes only the type. No deregistration, reset, override or data removal.
        [void](Invoke-DiskApi ('config/folders/'+[Uri]::EscapeDataString([string]$Folder.id)) PATCH @{type=$type})
        $Folder.type=$type
    }
}
function Assert-DiskProjectName([string]$Name) {
    if($Name.Length -gt 128 -or $Name -notmatch '^[\p{L}\p{N}_][\p{L}\p{N}_. -]*$' -or $Name.Contains('..') -or $Name -match '[ .]$|^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)'){throw ('Недопустимое имя серверной папки: '+$Name)}
}
function Test-DiskPathWithin([string]$Parent,[string]$Child) {
    $p=[IO.Path]::GetFullPath($Parent).TrimEnd('\','/');$c=[IO.Path]::GetFullPath($Child).TrimEnd('\','/')
    $c -ieq $p -or $c.StartsWith($p+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
}
function Assert-DiskPlainPath([string]$Path) {
    for($part=[IO.Path]::GetFullPath($Path);$part;$part=[IO.Path]::GetDirectoryName($part)){
        if((Test-Path -LiteralPath $part) -and ([IO.File]::GetAttributes($part) -band [IO.FileAttributes]::ReparsePoint)){throw ('Ссылки в пути запрещены: '+$Path)}
    }
}
function Read-DiskExternalExclusions {
    $file=Join-Path $script:DiskHome 'external-exclusions.json'
    if(-not (Test-Path -LiteralPath $file)){return}
    $saved=[IO.File]::ReadAllText($file).Replace("`r",'')|ConvertFrom-Json
    if($saved.schema -ne 1){throw 'Неизвестный формат исключений внешних папок'}
    $peer=[IO.File]::ReadAllText((Join-Path $script:DiskHome 'server.txt')).Trim()
    if($saved.peer -ceq $peer){@($saved.names)}
}
function Write-DiskExternalExclusions($Names) {
    $peer=[IO.File]::ReadAllText((Join-Path $script:DiskHome 'server.txt')).Trim()
    Write-SelectionState (Join-Path $script:DiskHome 'external-exclusions.json') (@{schema=1;peer=$peer;names=@($Names|Sort-Object -Unique)}|ConvertTo-Json -Compress)
}
function Read-DiskExternal {
    $file=Join-Path $script:DiskHome 'external.json'
    if(Test-Path -LiteralPath $file){
        $saved=[IO.File]::ReadAllText($file).Replace("`r",'')|ConvertFrom-Json
        if($saved.schema -ne 1){throw 'Неизвестный формат внешних папок'}
        @($saved.items)
    }
}
function Write-DiskExternal($Items) {
    Write-SelectionState (Join-Path $script:DiskHome 'external.json') (@{schema=1;items=@($Items)}|ConvertTo-Json -Depth 20 -Compress)
}
function Assert-DiskExternalChoices($Items,[string]$Base) {
    $paths=@();$remotes=@()
    foreach($item in @($Items)){
        if($null -eq $item){continue}
        Assert-DiskProjectName ([string]$item.remote)
        [void](Get-DiskFolderType $(if($item.direction){[string]$item.direction}else{'both'}))
        if(-not [IO.Path]::IsPathRooted([string]$item.path) -or ($env:OS -eq 'Windows_NT' -and [string]$item.path -notmatch '^(?:[a-zA-Z]:[\\/]|\\\\[^\\]+\\[^\\]+)')){throw 'Внешняя папка: нужен абсолютный путь Windows'}
        $path=[IO.Path]::GetFullPath([string]$item.path)
        if((Test-DiskPathWithin $Base $path) -or (Test-DiskPathWithin $path $Base)){throw 'Внешняя папка пересекается с корнем Disk'}
        Assert-DiskPlainPath $path
        foreach($other in $paths){if((Test-DiskPathWithin $other $path) -or (Test-DiskPathWithin $path $other)){throw 'Пересекающиеся внешние папки'}}
        if([string]$item.remote -iin $remotes){throw 'Серверная папка внешнего выбора повторяется'}
        $paths+=@($path);$remotes+=@([string]$item.remote)
    }
}
function Add-DiskManagedExternal($Item) {
    & (Join-Path $PSScriptRoot 'Add-RemoteDiskFolder.ps1') -Path ([string]$Item.path) -Remote ([string]$Item.remote) -ManagedSelection -Direction ([string]$Item.direction)
    if(-not $?){throw ('Не удалось подключить внешнюю папку '+$Item.remote)}
}
# Native junctions expose an external choice in Disk; these thin wrappers can be replaced in tests.
# Syncthing still watches the original path, and inventory never follows the junction.
function Get-DiskExternalJunctionTarget([string]$Link) {
    if(-not (Test-Path -LiteralPath $Link)){return ''}
    $item=Get-Item -LiteralPath $Link -Force
    if(-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not $item.PSIsContainer){return ''}
    $target=@($item.Target)
    if($target.Count -ne 1 -or -not $target[0]){return ''}
    $value=[string]$target[0]
    if(-not [IO.Path]::IsPathRooted($value)){$value=Join-Path (Split-Path $Link -Parent) $value}
    [IO.Path]::GetFullPath($value).TrimEnd('\','/')
}
function New-DiskExternalJunction([string]$Link,[string]$Target) {
    if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Соединение каталога Disk поддерживается только в Windows'}
    [void](New-Item -ItemType Junction -Path $Link -Target $Target -ErrorAction Stop)
}
function Remove-DiskExternalJunction([string]$Link) {
    # Never use recursive Remove-Item: only the link itself belongs to Disk.
    [IO.Directory]::Delete($Link,$false)
}
function Assert-DiskExternalJunction($Item,[string]$Base,$Saved) {
    Assert-DiskPlainPath $Base
    $link=Join-Path $Base ([string]$Item.remote)
    if(-not (Test-Path -LiteralPath $link)){return}
    $target=Get-DiskExternalJunctionTarget $link
    $owned=@($Saved|Where-Object {$_.junction -and [IO.Path]::GetFullPath([string]$_.junction) -ieq [IO.Path]::GetFullPath($link) -and $_.remote -ceq $Item.remote -and [IO.Path]::GetFullPath([string]$_.path).TrimEnd('\','/') -ieq [IO.Path]::GetFullPath([string]$Item.path).TrimEnd('\','/')})
    if(-not $owned.Count -or -not $target -or $target -ine [IO.Path]::GetFullPath([string]$Item.path).TrimEnd('\','/')){throw ('В Диске уже занято имя «'+$Item.remote+'». Переименуйте папку или выберите другое имя проекта')}
}
function Ensure-DiskExternalJunction($Item,[string]$Base) {
    $link=Join-Path $Base ([string]$Item.remote)
    if(-not (Test-Path -LiteralPath $link)){
        Assert-DiskPlainPath $Base
        [void][IO.Directory]::CreateDirectory($Base)
        New-DiskExternalJunction $link ([string]$Item.path)
    }
    if((Get-DiskExternalJunctionTarget $link) -ine [IO.Path]::GetFullPath([string]$Item.path).TrimEnd('\','/')){throw ('Не подтверждено соединение каталога: '+$Item.remote)}
}
function Remove-DiskOwnedExternalJunction($Item,[string]$Base) {
    if(-not $Item.junction){return}
    $link=Join-Path $Base ([string]$Item.remote)
    if([IO.Path]::GetFullPath([string]$Item.junction) -ine [IO.Path]::GetFullPath($link)){return}
    if(-not (Test-Path -LiteralPath $link)){return}
    if((Get-DiskExternalJunctionTarget $link) -ieq [IO.Path]::GetFullPath([string]$Item.path).TrimEnd('\','/')){Remove-DiskExternalJunction $link}
    else{Write-DiskLog ('Соединение каталога изменено пользователем; сохранено: '+$link)}
}
function Sync-DiskExternal($Desired,[string]$Base) {
    $desiredItems=@($Desired|Where-Object {$null -ne $_})
    Assert-DiskExternalChoices $desiredItems $Base
    $saved=@(Read-DiskExternal);$folders=@(Invoke-DiskApi 'config/folders')
    # Preflight identities and intersections before detaching anything.
    foreach($item in $desiredItems){
        Assert-DiskExternalJunction $item $Base $saved
        foreach($folder in $folders){
            $same=[IO.Path]::GetFullPath([string]$item.path).TrimEnd('\','/') -ieq [IO.Path]::GetFullPath([string]$folder.path).TrimEnd('\','/')
            if($same -and $folder.label -cne [string]$item.remote){throw 'Внешняя папка уже связана с другим проектом'}
            if(-not $same -and ((Test-DiskPathWithin $folder.path $item.path) -or (Test-DiskPathWithin $item.path $folder.path) -or $folder.label -ieq [string]$item.remote)){throw 'Серверная папка уже подключена в другом месте или пересекается с Syncthing'}
        }
    }
    foreach($old in $saved){
        $keep=@($desiredItems|Where-Object {$_.remote -ceq $old.remote -and [IO.Path]::GetFullPath($_.path).TrimEnd('\','/') -ieq [IO.Path]::GetFullPath($old.path).TrimEnd('\','/')})
        if($keep.Count){continue}
        # Save the exclusion BEFORE dropping the registration or external ownership receipt.
        Write-DiskExternalExclusions (@(Read-DiskExternalExclusions)+@([string]$old.remote))
        foreach($folder in $folders|Where-Object {$_.label -ceq $old.remote -and [IO.Path]::GetFullPath($_.path).TrimEnd('\','/') -ieq [IO.Path]::GetFullPath($old.path).TrimEnd('\','/')}){
            [void](Invoke-DiskApi ('config/folders/'+[Uri]::EscapeDataString([string]$folder.id)) DELETE)
        }
        Remove-DiskOwnedExternalJunction $old $Base
        $saved=@($saved|Where-Object {$_ -ne $old});Write-DiskExternal $saved
    }
    foreach($item in $desiredItems){
        $direction='both';if($item.direction){$direction=[string]$item.direction}
        $entry=[pscustomobject]@{path=[IO.Path]::GetFullPath([string]$item.path);remote=[string]$item.remote;direction=$direction;junction=(Join-Path $Base ([string]$item.remote))}
        $match=@(Invoke-DiskApi 'config/folders'|Where-Object {$_.label -ceq $entry.remote -and [IO.Path]::GetFullPath($_.path).TrimEnd('\','/') -ieq $entry.path.TrimEnd('\','/')})
        if(-not $match.Count){
            [void][IO.Directory]::CreateDirectory($entry.path)
            Assert-DiskPlainPath $entry.path
            # Journal ownership first: an interruption after Add must leave the folder removable.
            $saved=@($saved|Where-Object {$_.remote -cne $entry.remote})+@($entry);Write-DiskExternal $saved
            # Add validates identity conflicts before touching policy or server state; occupied folders are merged without deleting.
            [void](Add-DiskManagedExternal $entry)
            $match=@(Invoke-DiskApi 'config/folders'|Where-Object {$_.label -ceq $entry.remote -and [IO.Path]::GetFullPath($_.path).TrimEnd('\','/') -ieq $entry.path.TrimEnd('\','/')})
            if($match.Count -ne 1){throw ('Syncthing не подтвердил внешнюю папку '+$entry.remote)}
        }
        # Receipt before policy/type updates makes interrupted additions removable on the next apply.
        $saved=@($saved|Where-Object {$_.remote -cne $entry.remote})+@($entry);Write-DiskExternal $saved
        Initialize-ProjectSelection $entry.path @('.')
        Set-DiskFolderDirection $match[0] $direction
        Ensure-DiskExternalJunction $entry $Base
    }
}
function Get-DiskExternalList {
    $saved=@(Read-DiskExternal);if(-not $saved.Count){return}
    Read-DiskState;$folders=@(Invoke-DiskApi 'config/folders')
    foreach($item in $saved){
        $match=@($folders|Where-Object {$_.label -ceq $item.remote -and [IO.Path]::GetFullPath($_.path).TrimEnd('\','/') -ieq [IO.Path]::GetFullPath($item.path).TrimEnd('\','/')})
        $state='detached';$direction=[string]$item.direction
        if($match.Count -eq 1){
            $direction=Get-DiskTypeDirection $match[0].type
            if($match[0].paused){$state='paused'}else{
                $status=Invoke-DiskApi ('db/status?folder='+[Uri]::EscapeDataString([string]$match[0].id))
                $state=[string]$status.state;if(-not $state){$state='unknown'}
            }
        }
        @{path=[string]$item.path;remote=[string]$item.remote;direction=$direction;state=$state}
    }
}
function Add-DiskTreeState($Union,[string]$Base) {
    if($Union.parent){return}
    if(-not (Test-Path -LiteralPath (Join-Path $script:DiskHome 'state/config.xml'))){return}
    Read-DiskState;$folders=@(Invoke-DiskApi 'config/folders')
    foreach($row in @($Union.rows|Where-Object {$_.kind -eq 'directory'})){
        $expected=Join-Path $Base ([string]$row.path)
        $match=@($folders|Where-Object {[IO.Path]::GetFullPath($_.path).TrimEnd('\','/') -ieq [IO.Path]::GetFullPath($expected).TrimEnd('\','/')})
        if($match.Count -ne 1){continue}
        $row|Add-Member -Force -NotePropertyName direction -NotePropertyValue (Get-DiskTypeDirection $match[0].type)
        $row|Add-Member -Force -NotePropertyName localChanges -NotePropertyValue 0
        if($row.direction -eq 'receive'){
            $status=Invoke-DiskApi ('db/status?folder='+[Uri]::EscapeDataString([string]$match[0].id))
            if($null -eq $status.receiveOnlyTotalItems){throw 'Syncthing не вернул число локальных правок receive-папки'}
            $row.localChanges=[long]$status.receiveOnlyTotalItems
        }
    }
}
function Invoke-DiskRevert([string]$Project) {
    Assert-DiskProjectName $Project
    Read-DiskState;$expected=Join-Path (Get-DiskBase) $Project
    $match=@(Invoke-DiskApi 'config/folders'|Where-Object {[IO.Path]::GetFullPath($_.path).TrimEnd('\','/') -ieq [IO.Path]::GetFullPath($expected).TrimEnd('\','/')})
    if($match.Count -ne 1 -or $match[0].type -cne 'receiveonly'){throw 'Откат доступен только подключённой папке «только забирать»'}
    [void](Invoke-DiskApi ('db/revert?folder='+[Uri]::EscapeDataString([string]$match[0].id)) POST)
    @{ok=$true;summary='Запрошен возврат локальных правок к серверной версии; обработка продолжается в фоне'}
}
