#requires -Version 5.1
[CmdletBinding()]
param([string]$BasePath)
. (Join-Path $PSScriptRoot 'Disk.Common.ps1')
$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'
$lock=$null
try {
    $lock=[IO.File]::Open((Join-Path $script:DiskHome 'folders.lock'),'OpenOrCreate','ReadWrite','None')
    Read-DiskState
    if(-not $BasePath){$BasePath=Get-DiskBase};$BasePath=[IO.Path]::GetFullPath($BasePath);[void][IO.Directory]::CreateDirectory($BasePath)
    # Manual accept in the tray offers the same base.
    $defaults=Invoke-DiskApi 'config/defaults/folder';if($defaults.path -cne $BasePath){[void](Invoke-DiskApi 'config/defaults/folder' PATCH @{path=$BasePath})}
    $peer=[IO.File]::ReadAllText((Join-Path $script:DiskHome 'server.txt')).Trim()
    # Native auto-accept cannot enforce the occupied-directory policy.
    $device=Invoke-DiskApi ('config/devices/'+$peer)
    if($device.autoAcceptFolders){[void](Invoke-DiskApi ('config/devices/'+$peer) PATCH @{autoAcceptFolders=$false})}
    $pending=Invoke-DiskApi 'cluster/pending/folders'
    foreach($entry in $pending.PSObject.Properties){
        $offer=$entry.Value.offeredBy.PSObject.Properties|Where-Object {$_.Name -ceq $peer}
        if(-not $offer){continue}
        $name=[string]$offer.Value.label;$id=$entry.Name
        try {
            if($name.Length -gt 128 -or $name -notmatch '^[\p{L}\p{N}_][\p{L}\p{N}_. -]*$' -or $name.Contains('..') -or $name -match '[ .]$|^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){throw 'Недопустимое имя папки'}
            $target=[IO.Path]::GetFullPath((Join-Path $BasePath $name))
            $folders=@(Invoke-DiskApi 'config/folders')
            if(@($folders|Where-Object {$_.id -ceq $id}).Count){continue}
            Assert-DiskFreePath $target $folders
            [void][IO.Directory]::CreateDirectory($target)
            # Recheck immediately before writing policy/configuration.
            Assert-DiskFreePath $target $folders
            Test-DiskIgnores $target -Write
            $folder=Invoke-DiskApi 'config/defaults/folder'
            $folder.id=$id;$folder.label=$name;$folder.path=$target;$folder.type='sendreceive';$folder.paused=$true
            $folder.devices=@(@{deviceID=$peer});$folder.maxConflicts=10
            [void](Invoke-DiskApi ('config/folders/'+[Uri]::EscapeDataString($id)) PUT $folder)
            [void](Invoke-DiskApi ('config/folders/'+[Uri]::EscapeDataString($id)) PATCH @{paused=$false})
            Write-DiskLog ('Автоподключение: '+$name)
        }catch{Write-DiskLog ('Автоподключение: '+$name) $_;Write-Warning ($name+': '+$_.Exception.Message)}
    }
}catch{Write-DiskLog 'Проверка новых папок' $_;Write-Error $_.Exception.Message;exit 1}finally{if($lock){$lock.Dispose()}}
