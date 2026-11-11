#requires -Version 5.1
# A pure one-level inventory: never follows junctions or modifies user content.
function Get-DiskUnion($ServerTree,[string]$BasePath,[string]$RelativePath='',[int]$Limit=2000) {
    if($RelativePath){Assert-SelectionPath $RelativePath;if(Test-SelectionProtected $RelativePath){throw 'Защищённый путь'}}
    $rows=@{};$caseNames=@{};$truncated=[bool]$ServerTree.truncated
    function Add-UnionRow([string]$Path,[string]$Kind,[string]$Side,[bool]$HasChildren) {
        Assert-SelectionPath $Path
        if(Test-SelectionProtected $Path){return}
        $slash=$Path.LastIndexOf('/');$parent='';if($slash -ge 0){$parent=$Path.Substring(0,$slash)}
        if($parent -cne $RelativePath){throw 'Сервер вернул другой уровень дерева; обновите помощник диска'}
        $fold=$Path.ToLowerInvariant()
        if($caseNames.ContainsKey($fold) -and $caseNames[$fold] -cne $Path){throw 'Имена различаются только регистром; переименуйте перед синхронизацией'}
        $caseNames[$fold]=$Path
        if(-not $rows.ContainsKey($Path)){$rows[$Path]=@{path=$Path;kind=$Kind;server=$false;local=$false;hasChildren=$false}}
        if($rows[$Path].kind -ne $Kind){throw 'Файл и папка имеют один путь; переименуйте перед синхронизацией'}
        $rows[$Path][$Side]=$true;$rows[$Path].hasChildren=$rows[$Path].hasChildren -or $HasChildren
    }
    foreach($f in @($ServerTree.folders)){if($null -ne $f){Add-UnionRow ([string]$f.name) 'directory' 'server' ([bool]$f.hasChildren)}}
    foreach($e in @($ServerTree.entries)){if($null -ne $e){$kind='file';if($e.directory){$kind='directory'};Add-UnionRow ([string]$e.path) $kind 'server' ([bool]$e.hasChildren)}}
    $directory=$BasePath;if($RelativePath){$directory=Join-Path $BasePath $RelativePath}
    for($p=[IO.Path]::GetFullPath($directory);$p;$p=[IO.Path]::GetDirectoryName($p)){
        if((Test-Path -LiteralPath $p) -and ([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint)){throw 'Ссылки в корне Disk запрещены'}
    }
    if(Test-Path -LiteralPath $directory){
        $count=0
        # Do not collect the directory before applying the cap (PS 5.1).
        foreach($item in (New-Object IO.DirectoryInfo($directory)).EnumerateFileSystemInfos()){
            $rel=$item.Name;if($RelativePath){$rel=$RelativePath+'/'+$item.Name}
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Test-SelectionProtected $rel)){continue}
            try{Assert-SelectionPath $rel}catch{continue}
            if($count -ge $Limit){$truncated=$true;break};$count++
            $kind='file';$hasChildren=$false
            if($item -is [IO.DirectoryInfo]){
                $kind='directory'
                foreach($child in $item.EnumerateFileSystemInfos()){
                    $childPath=$rel+'/'+$child.Name
                    if(($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Test-SelectionProtected $childPath)){continue}
                    try{Assert-SelectionPath $childPath}catch{continue}
                    $hasChildren=$true;break
                }
            }
            Add-UnionRow $rel $kind 'local' $hasChildren
        }
    }
    $result=@(foreach($key in @($rows.Keys|Sort-Object -CaseSensitive)){
        $row=$rows[$key];$presence='server';if($row.local){$presence='local';if($row.server){$presence='both'}}
        [pscustomobject]@{path=$row.path;kind=$row.kind;presence=$presence;hasChildren=$row.hasChildren}
    })
    [pscustomobject]@{schema=1;parent=$RelativePath;rows=$result;truncated=$truncated}
}
