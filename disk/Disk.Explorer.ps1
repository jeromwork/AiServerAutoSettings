#requires -Version 5.1
# Uninstall also runs without the WinForms process. Windows provides the shell/FS APIs;
# this small adapter only removes metadata that carries this product's ownership mark.
function Get-DiskExplorerMetadata([string]$File) {
    if(-not [IO.File]::Exists($File) -or ([IO.File]::GetAttributes($File) -band [IO.FileAttributes]::ReparsePoint)){return $null}
    $values=@{};$section=''
    foreach($line in ([IO.File]::ReadAllText($File).Replace("`r",'') -split "`n")){
        if($line -match '^\s*\[([^]]+)\]\s*$'){$section=$Matches[1];continue}
        if($section -ieq 'RemoteAgents' -and $line -match '^\s*([^=]+?)\s*=\s*(.*?)\s*$'){$values[$Matches[1]]=$Matches[2]}
    }
    if($values.Owner -cne 'RemoteAgents.Disk.v1'){return $null}
    $values
}
function Update-DiskExplorerItem([string]$Path) {
    if(-not (Test-DiskNavPaneWindows)){return}
    if(-not ('RemoteDisk.ExplorerCleanup' -as [type])){
        Add-Type -Namespace RemoteDisk -Name ExplorerCleanup -MemberDefinition '[DllImport("shell32.dll", CharSet=CharSet.Unicode)] public static extern void SHChangeNotify(int eventId, uint flags, string item1, IntPtr item2);'
    }
    [RemoteDisk.ExplorerCleanup]::SHChangeNotify(0x2000,0x5,$Path,[IntPtr]::Zero) # SHCNE_UPDATEITEM, SHCNF_PATHW
}
function Remove-DiskExplorerFolderMetadata([string]$Path) {
    Assert-DiskPlainPath $Path
    $file=Join-Path $Path 'desktop.ini';$owned=Get-DiskExplorerMetadata $file
    if(-not $owned){return}
    $attributes=[IO.File]::GetAttributes($Path);$removed=$false
    try{
        [IO.File]::SetAttributes($Path,($attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
        [IO.File]::SetAttributes($file,[IO.FileAttributes]::Normal)
        [IO.File]::Delete($file);$removed=$true
    }finally{
        if($removed){
            if($owned.OriginalReadOnly -ceq '0'){$attributes=$attributes -band (-bnot [IO.FileAttributes]::ReadOnly)}
            elseif($owned.OriginalReadOnly -ceq '1'){$attributes=$attributes -bor [IO.FileAttributes]::ReadOnly}
        }
        [IO.File]::SetAttributes($Path,$attributes)
    }
    Update-DiskExplorerItem $Path
}
function Remove-DiskExplorer([string]$Base='',[switch]$KeepJunctions) {
    if(-not $script:DiskHome){$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'}
    $owner='RemoteAgents.Disk.v1'
    foreach($action in @('download','sync','keep-server','add','progress')){
        $key='Software\Classes\Directory\shell\RemoteAgents.Disk.'+$action
        if((Get-DiskNavPaneValue $key 'RemoteAgentsOwner') -ceq $owner){Remove-DiskNavPaneKey $key}
    }
    if(-not $Base){$Base=Get-DiskBase}
    if([IO.Directory]::Exists($Base)){
        Assert-DiskPlainPath $Base
        foreach($item in (New-Object IO.DirectoryInfo($Base)).EnumerateDirectories()){
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
            Remove-DiskExplorerFolderMetadata $item.FullName
        }
    }
    foreach($external in @(Read-DiskExternal)){
            # An explicit receipt identifies the configured source; never walk through the junction.
            if($external.path -and -not (Test-DiskPathWithin $Base ([string]$external.path)) -and -not (Test-DiskPathWithin ([string]$external.path) $Base)){
                try{
                    if([IO.Directory]::Exists([string]$external.path)){Remove-DiskExplorerFolderMetadata ([string]$external.path)}
                }catch{Write-DiskLog ('Удаление оформления внешней папки: '+$external.remote) $_}
            }
            if(-not $KeepJunctions){Remove-DiskOwnedExternalJunction $external $Base}
    }
    $icons=Join-Path $env:LOCALAPPDATA 'RemoteAgents/icons'
    if([IO.Directory]::Exists($icons)){
        Assert-DiskPlainPath $icons
        foreach($state in @('Local','ServerOnly','Pending','Syncing','Synced','Paused','Error','Offline','Unavailable')){
            $file=Join-Path $icons ($owner+'.'+$state+'.ico')
            if([IO.File]::Exists($file) -and -not ([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::ReparsePoint)){[IO.File]::Delete($file)}
        }
    }
    Update-DiskNavPaneShell
}

# Upgrade only the shipped base or an exact, trusted selective policy. Syncthing's
# own db/ignores endpoint writes and loads the file; no second sync engine is added.
function Get-DiskExplorerUpgradedPolicy([string]$Policy) {
    $old=$Policy.Replace("`r",'');$header='#escape=\'+"`n";$marker="// RemoteDisk selective v1`n"
    if(-not $old.StartsWith($header,[StringComparison]::Ordinal)){throw 'Неизвестный заголовок политики Disk'}
    $offset=$old.IndexOf($marker,[StringComparison]::Ordinal)
    if($offset -lt $header.Length){throw 'Неизвестная политика Disk'}
    $base=$old.Substring($header.Length,$offset-$header.Length).TrimEnd("`n")+"`n"
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($base)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    if($hash -cnotin @(Get-DiskKnownIgnoreHashes)){throw 'Неизвестный базовый шаблон политики Disk'}
    $header+[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'stignore.txt')).Replace("`r",'').TrimEnd("`n")+"`n"+$old.Substring($offset)
}
function Get-DiskExplorerProofHash([string]$Text) {
    $normalized=$Text.Replace("`r",'').TrimEnd("`n")+"`n";$sha=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Ensure-DiskExplorerFolderIgnores($Folder) {
    $path=[string]$Folder.path;Assert-DiskPlainPath $path
    $file=Join-Path $path '.stignore'
    if([IO.File]::Exists($file) -and ([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::ReparsePoint)){throw 'Ссылка .stignore запрещена'}
    $actual='';if([IO.File]::Exists($file)){$actual=[IO.File]::ReadAllText($file).Replace("`r",'')}
    $policyFile=Get-SelectionPolicyFile $path;$managed='';$desired=''
    if([IO.File]::Exists($policyFile)){
        $managed=[IO.File]::ReadAllText($policyFile).Replace("`r",'')
        $desired=Get-DiskExplorerUpgradedPolicy $managed
        # Also recognize an interruption after Syncthing wrote the new policy but before its receipt.
        if($actual -cne $managed -and $actual -cne $desired){Test-DiskIgnores $path;throw 'Файл .stignore не совпадает с политикой Disk'}
    }else{
        Test-DiskIgnores $path
        $desired=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'stignore.txt')).Replace("`r",'').TrimEnd("`n")+"`n"
    }
    $route='db/ignores?folder='+[Uri]::EscapeDataString([string]$Folder.id)
    $loaded=Invoke-DiskApi $route
    $loadedText=(@($loaded.ignore)|ForEach-Object {([string]$_).Replace("`r",'')}) -join "`n"
    if($actual -cne $desired -or $loadedText.TrimEnd("`n") -cne $desired.TrimEnd("`n")){
        [void](Invoke-DiskApi $route POST @{ignore=@($desired.TrimEnd("`n") -split "`n")})
    }
    $confirmed=Invoke-DiskApi $route
    $confirmedText=(@($confirmed.ignore)|ForEach-Object {([string]$_).Replace("`r",'')}) -join "`n"
    if($confirmedText.TrimEnd("`n") -cne $desired.TrimEnd("`n") -or @($confirmed.ignore|Where-Object {([string]$_).Replace("`r",'') -ceq '(?i)/desktop.ini'}).Count -ne 1){throw 'Syncthing не подтвердил исключение desktop.ini; оформление пропущено'}
    if(-not [IO.File]::Exists($file) -or [IO.File]::ReadAllText($file).Replace("`r",'').TrimEnd("`n") -cne $desired.TrimEnd("`n")){throw 'Syncthing не сохранил исключения в .stignore; оформление пропущено'}
    if($managed -and $managed -cne $desired){Save-SelectionPolicy $path $desired}
    # Hash the trusted desired policy, not a later disk read that could observe an editor's change.
    [pscustomobject]@{path=[IO.Path]::GetFullPath($path).TrimEnd('\','/');sha256=(Get-DiskExplorerProofHash $desired)}
}
function Ensure-DiskExplorerIgnores([string]$Base='',[switch]$Proofs) {
    if(-not $Base){$Base=Get-DiskBase}
    Assert-DiskPlainPath $Base
    Read-DiskState
    $peerFile=Join-Path $script:DiskHome 'server.txt';if(-not [IO.File]::Exists($peerFile)){return}
    $peer=[IO.File]::ReadAllText($peerFile).Replace("`r",'').Trim()
    $external=@(Read-DiskExternal)
    foreach($folder in @(Invoke-DiskApi 'config/folders')){
        $path=[IO.Path]::GetFullPath([string]$folder.path).TrimEnd('\','/')
        $inBase=[IO.Path]::GetDirectoryName($path) -ieq [IO.Path]::GetFullPath($Base).TrimEnd('\','/')
        $explicit=@($external|Where-Object {$_.remote -ceq $folder.label -and [IO.Path]::GetFullPath([string]$_.path).TrimEnd('\','/') -ieq $path})
        if((-not $inBase -and -not $explicit.Count) -or -not @($folder.devices|Where-Object {$_.deviceID -ceq $peer}).Count){continue}
        try{$proof=Ensure-DiskExplorerFolderIgnores $folder;if($Proofs){$proof}else{$proof.path}}catch{Write-DiskLog ('Исключение desktop.ini: '+$folder.label) $_}
    }
}
