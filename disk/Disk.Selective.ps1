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
function Test-SelectionProtected([string]$Path) {
    foreach($part in $Path.Split('/')){
        if($part -in @('.stignore','.stfolder','.stversions')){return $true}
        foreach($line in [IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'stignore.txt'))){
            if($line.StartsWith('(?i)')){if($part -like $line.Substring(4)){return $true}}
        }
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
function Set-ProjectSelection($Folder,[string[]]$Paths) {
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
    $remove=@(Get-SelectionFiles $root|Where-Object { -not ('.' -in $Paths) -and -not (Test-SelectionIncluded $_ $Paths) })
    if($remove.Count){
        # Force a scan first; a stale idle status is not proof that current files reached the server.
        [void](Invoke-DiskApi ('db/scan?folder='+$id) POST)
        Assert-SelectionSynced (Invoke-DiskApi ('db/status?folder='+$id))
    }
    $route='config/folders/'+$id
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
            $receipt=Invoke-DiskServer verify-selection @{name=$Folder.label;id=$Folder.id;deviceId=$device;paths=$remove}
            if(-not $receipt.ok){throw 'Серверная копия не подтверждена'}
        }
        # Ignore first, delete second. A crash cannot publish a deletion to the server.
        # File handles deny writes; retain all handles until hashes match and ignores are installed.
        $handles=New-Object Collections.ArrayList
        try{
            foreach($rel in $remove){
                $file=Join-Path $root $rel
                $stream=[IO.File]::Open($file,'Open','Read',([IO.FileShare]::Read -bor [IO.FileShare]::Delete));[void]$handles.Add(@{stream=$stream;file=$file})
                $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
                $remote=$receipt.hashes.PSObject.Properties[$rel]
                if(-not $remote -or $hash -cne [string]$remote.Value){throw 'Локальная версия ещё не подтверждена на сервере'}
            }
            if(Test-Path -LiteralPath $ignore){[IO.File]::SetAttributes($ignore,([IO.File]::GetAttributes($ignore) -band (-bnot [IO.FileAttributes]::Hidden)))}
            Save-SelectionPolicy $root $rules
            Write-SelectionAtomic $ignore $rules
            foreach($entry in $handles){[IO.File]::Delete($entry.file)}
        }finally{foreach($entry in $handles){$entry.stream.Dispose()}}
        # Empty ancestors may be removed; protected files and selected empty directories remain.
        foreach($dir in @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Force|Sort-Object FullName -Descending)){
            $rel=$dir.FullName.Substring($root.TrimEnd('\','/').Length+1).Replace('\','/')
            if($dir.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
            if(-not (Test-SelectionProtected $rel) -and -not ('.' -in $Paths) -and -not (Test-SelectionIncluded $rel $Paths) -and @(Get-ChildItem -LiteralPath $dir.FullName -Force).Count -eq 0){[IO.Directory]::Delete($dir.FullName,$false)}
        }
    }finally{[void](Invoke-DiskApi $route PATCH @{paused=$false})}
}

function Get-SelectionPolicyFile([string]$Path) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$id=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Path).ToLowerInvariant())))).Replace('-','')}finally{$sha.Dispose()}
    Join-Path $script:DiskHome ('selection-policies/'+$id+'.txt')
}
function Save-SelectionPolicy([string]$Path,[string]$Rules) {
    $file=Get-SelectionPolicyFile $Path;[void][IO.Directory]::CreateDirectory((Split-Path $file -Parent))
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
