#requires -Version 5.1
# A pure inventory: never follows junctions and never creates/deletes user content.
function Get-DiskUnion($ServerTree,[string]$BasePath) {
    $rows=@{};$caseNames=@{}
    function Add-UnionRow([string]$Path,[string]$Kind,[string]$Side) {
        Assert-SelectionPath $Path
        if(Test-SelectionProtected $Path){return}
        $fold=$Path.ToLowerInvariant()
        if($caseNames.ContainsKey($fold) -and $caseNames[$fold] -cne $Path){throw 'Имена различаются только регистром; переименуйте перед синхронизацией'}
        $caseNames[$fold]=$Path
        if(-not $rows.ContainsKey($Path)){$rows[$Path]=@{path=$Path;kind=$Kind;server=$false;local=$false}}
        if($rows[$Path].kind -ne $Kind){throw 'Файл и папка имеют один путь; переименуйте перед синхронизацией'}
        $rows[$Path][$Side]=$true
    }
    foreach($f in @($ServerTree.folders)){Add-UnionRow ([string]$f.name) 'directory' 'server'}
    foreach($e in @($ServerTree.entries)){$kind='file';if($e.directory){$kind='directory'};Add-UnionRow ([string]$e.path) $kind 'server'}
    function Visit-UnionDirectory([string]$Directory,[string]$Prefix) {
        foreach($item in @(Get-ChildItem -LiteralPath $Directory -Force)){
            $rel=$item.Name;if($Prefix){$rel=$Prefix+'/'+$item.Name}
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Test-SelectionProtected $rel)){continue}
            $kind='file';if($item.PSIsContainer){$kind='directory'}
            Add-UnionRow $rel $kind 'local'
            if($item.PSIsContainer){Visit-UnionDirectory $item.FullName $rel}
        }
    }
    if(Test-Path -LiteralPath $BasePath){
        for($p=[IO.Path]::GetFullPath($BasePath);$p;$p=[IO.Path]::GetDirectoryName($p)){if((Test-Path -LiteralPath $p) -and ([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint)){throw 'Ссылки в корне Disk запрещены'}}
        Visit-UnionDirectory $BasePath ''
    }
    $result=@(foreach($key in @($rows.Keys|Sort-Object -CaseSensitive)){
        $row=$rows[$key];$presence='server';if($row.local){$presence='local';if($row.server){$presence='both'}}
        [pscustomobject]@{path=$row.path;kind=$row.kind;presence=$presence}
    })
    [pscustomobject]@{schema=1;rows=$result}
}
