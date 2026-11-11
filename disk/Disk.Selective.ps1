#requires -Version 5.1
# Local selection belongs to the device; .stignore never syncs to the server.
function Assert-SelectionPath([string]$Value) {
    if(-not $Value -or $Value.Contains('\') -or $Value -match '[\x00-\x1f<>:"|?*]' -or $Value.StartsWith('/') -or @($Value.Split('/')|Where-Object {$_ -in @('','.','..') -or $_ -match '[ .]$|^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'}).Count){throw 'Недопустимый путь выбора'}
}
function Get-SelectionPaths($Selection) {
    $paths=@($Selection.paths|ForEach-Object {([string]$_).Replace("`r",'').TrimEnd('/') }|Sort-Object -Unique)
    foreach($p in $paths){Assert-SelectionPath $p};$paths
}
function Test-SelectionIncluded([string]$Path,$Paths) {
    foreach($p in @($Paths)){if($Path -ceq $p -or $Path.StartsWith($p+'/',[StringComparison]::Ordinal)){return $true}};return $false
}
# Cache once per process; a tree level must not reopen stignore for every entry.
$script:SelectionProtectedPatterns=@([IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'stignore.txt'))|Where-Object {$_.StartsWith('(?i)')}|ForEach-Object {$_.Substring(4)})
function Test-SelectionProtected([string]$Path) {
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
    if($null -eq $Selection){return @('.')}
    $out=@();foreach($p in @(Get-SelectionPaths $Selection)){if($p -ceq $Name){return @('.')};if($p.StartsWith($Name+'/',[StringComparison]::Ordinal)){$out+=@($p.Substring($Name.Length+1))}};$out
}
function Assert-SelectionSynced($Status) {
    if($Status.state -ne 'idle'){throw 'Папка ещё не синхронизирована'}
    foreach($k in @('needBytes','needTotalItems','pullErrors','receiveOnlyChangedBytes','receiveOnlyTotalItems')){
        if($null -eq $Status.$k -or [long]$Status.$k -ne 0){throw 'Есть несинхронизированные данные'}
    }
}
function Get-SelectionFiles([string]$Root,[string]$Relative='') {
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
    $remove=@()
    if('.' -notin $Paths){$remove=@(Get-SelectionFiles $root|Where-Object { -not (Test-SelectionIncluded $_ $Paths) -and $_ -cnotin $KeepLocal })}
    if($remove.Count){
        # Force a scan first; a stale idle status is not proof that current files reached the server.
        [void](Invoke-DiskApi ('db/scan?folder='+$id) POST)
        Assert-SelectionSynced (Invoke-DiskApi ('db/status?folder='+$id))
    }
    $route='config/folders/'+$id
    # The scheduled companion holds the same folders.lock. If PowerShell is killed,
    # it resumes only this previously running folder; old/new ignores are atomic.
    $pauseReceipt=(Get-SelectionPolicyFile $root)+'.paused.json'
    Write-SelectionState $pauseReceipt (@{id=$Folder.id;path=$root;paths=$remove}|ConvertTo-Json -Compress)
    [void](Invoke-DiskApi $route PATCH @{paused=$true})
    # Wait for actual engine suspension before touching files or ignores.
    $paused=$false
    for($i=0;$i -lt 30;$i++){
        $s=Invoke-DiskApi ('db/status?folder='+$id)
        if($s.state -eq '' -and (Invoke-DiskApi $route).paused){$paused=$true;break};Start-Sleep -Milliseconds 100
    }
    if(-not $paused){throw 'Пауза не подтверждена; файлы сохранены'}
    try{
        if($remove.Count){
            $device=(Invoke-DiskApi 'system/status').myID
            $receipt=Invoke-DiskServer verify-selection @{name=$Folder.label;id=$Folder.id;deviceId=$device;paths=$remove;allowMissing=$true}
            if(-not $receipt.ok){throw 'Серверная копия не подтверждена'}
            # Missing remote files are local-only. Keep them ignored, exactly as before lazy inventory.
            $remove=@($remove|Where-Object {$_ -cnotin @($receipt.missing)})
        }
        # Ignore first, delete second. A crash cannot publish a deletion to the server.
        # File handles deny writes; retain all handles until hashes match and ignores are installed.
        $handles=New-Object Collections.ArrayList
        try{
            foreach($rel in $remove){
                $file=Join-Path $root $rel
                $stream=[IO.File]::Open($file,'Open','Read',([IO.FileShare]::Read -bor [IO.FileShare]::Delete));[void]$handles.Add(@{stream=$stream;file=$file;relative=$rel})
                $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
                $remote=$receipt.hashes.PSObject.Properties[$rel]
                if(-not $remote -or $hash -cne [string]$remote.Value){throw 'Локальная версия ещё не подтверждена на сервере'}
            }
            if(Test-Path -LiteralPath $ignore){[IO.File]::SetAttributes($ignore,([IO.File]::GetAttributes($ignore) -band (-bnot [IO.FileAttributes]::Hidden)))}
            Save-SelectionPolicy $root $rules
            Write-SelectionAtomic $ignore $rules
            foreach($entry in $handles){
                # A writer may atomically replace the pathname while the verified
                # handle is open. Evacuate first, then verify the actual moved file.
                # Staging under .stfolder is never synchronized or touched by editors.
                Remove-SelectionVerified $entry.file $receipt.hashes.PSObject.Properties[$entry.relative].Value $root
            }
        }finally{foreach($entry in $handles){$entry.stream.Dispose()}}
        # Empty ancestors may be removed; protected files and selected empty directories remain.
        if('.' -notin $Paths){foreach($dir in @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Force|Sort-Object FullName -Descending)){
            $rel=$dir.FullName.Substring($root.TrimEnd('\','/').Length+1).Replace('\','/')
            if($dir.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
            if(-not (Test-SelectionProtected $rel) -and -not ('.' -in $Paths) -and -not (Test-SelectionIncluded $rel $Paths) -and @(Get-ChildItem -LiteralPath $dir.FullName -Force).Count -eq 0){[IO.Directory]::Delete($dir.FullName,$false)}
        }}
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
                else{Write-DiskLog ('Прерванный выбор: копия сохранена '+$staged)}
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
function Remove-SelectionVerified([string]$File,[string]$Hash,[string]$Root) {
    $marker=Join-Path $Root '.stfolder'
    if(-not [IO.Directory]::Exists($marker) -or ([IO.File]::GetAttributes($marker) -band [IO.FileAttributes]::ReparsePoint)){throw 'Нет безопасного маркера папки Syncthing'}
    $staged=Get-SelectionStagedFile $File $Root
    [IO.File]::Move($File,$staged)
    $verified=$false
    try{
        $stream=[IO.File]::Open($staged,'Open','Read','Read')
        try{
            $sha=[Security.Cryptography.SHA256]::Create()
            try{$actual=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
            if($actual -cne $Hash){throw 'Файл изменился после проверки; новая версия сохранена'}
            $verified=$true
        }finally{$stream.Dispose()}
        [IO.File]::Delete($staged)
    }finally{
        if(-not $verified -and [IO.File]::Exists($staged)){
            # Never overwrite a version concurrently recreated at the original path.
            if(-not (Test-Path -LiteralPath $File)){[IO.File]::Move($staged,$File)}
            else{Write-DiskLog ('Новая версия сохранена: '+$staged)}
        }
    }
}
