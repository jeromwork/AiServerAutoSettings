#requires -Version 5.1
# Explorer navigation pane entry for the Disk root, like Yandex.Disk / OneDrive.
# Own code is needed: Windows has no CLI for a pinned shell folder; this is the documented
# per-user registration (HKCU only, no admin rights). Registry access goes through the four
# small Get/Set/Remove functions below so tests replace them with an in-memory store.
$script:DiskNavPaneGuid='{5D8A825B-EDEA-4B5E-97FC-96ABDC8A78E9}' # fixed product id, not owner-specific
$script:DiskNavPaneDesktop='Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\'+$script:DiskNavPaneGuid
$script:DiskNavPaneHidden='Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'

function Test-DiskNavPaneWindows {[Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT}
# 64-bit view: Explorer is 64-bit even if this PowerShell is a 32-bit child.
function Open-DiskNavPaneHive {
    $view=[Microsoft.Win32.RegistryView]::Default;if([Environment]::Is64BitOperatingSystem){$view=[Microsoft.Win32.RegistryView]::Registry64}
    [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,$view)
}
function Get-DiskNavPaneValue([string]$Key,[string]$Name) {
    if(-not (Test-DiskNavPaneWindows)){return $null}
    $hive=Open-DiskNavPaneHive;try{$k=$hive.OpenSubKey($Key);if($null -eq $k){return $null};try{$k.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}finally{$k.Dispose()}}finally{$hive.Dispose()}
}
function Set-DiskNavPaneValue([string]$Key,[string]$Name,$Value,[string]$Kind) {
    $hive=Open-DiskNavPaneHive;try{$k=$hive.CreateSubKey($Key);try{$k.SetValue($Name,$Value,[Microsoft.Win32.RegistryValueKind]$Kind)}finally{$k.Dispose()}}finally{$hive.Dispose()}
}
function Remove-DiskNavPaneKey([string]$Key) {
    if(-not (Test-DiskNavPaneWindows)){return}
    $hive=Open-DiskNavPaneHive;try{$hive.DeleteSubKeyTree($Key,$false)}finally{$hive.Dispose()}
}
function Remove-DiskNavPaneValue([string]$Key,[string]$Name) {
    if(-not (Test-DiskNavPaneWindows)){return}
    $hive=Open-DiskNavPaneHive;try{$k=$hive.OpenSubKey($Key,$true);if($k){try{$k.DeleteValue($Name,$false)}finally{$k.Dispose()}}}finally{$hive.Dispose()}
}
# Explorer re-reads the namespace on this notification; no Explorer restart is needed.
function Update-DiskNavPaneShell {
    if(-not (Test-DiskNavPaneWindows)){return}
    if(-not ('RemoteDisk.NavPaneShell' -as [type])){Add-Type -Namespace RemoteDisk -Name NavPaneShell -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);'}
    [RemoteDisk.NavPaneShell]::SHChangeNotify(0x08000000,0,[IntPtr]::Zero,[IntPtr]::Zero) # SHCNE_ASSOCCHANGED
}

# 32-bit file dialogs read the Wow6432Node copy, as with OneDrive.
function Get-DiskNavPaneClassKeys {
    $keys=@('Software\Classes\CLSID\'+$script:DiskNavPaneGuid)
    if([Environment]::Is64BitOperatingSystem){$keys+='Software\Classes\Wow6432Node\CLSID\'+$script:DiskNavPaneGuid}
    $keys
}
function Get-DiskNavPaneBase([string]$Base) {
    if(-not $Base -and (Get-Command Get-DiskBase -ErrorAction SilentlyContinue)){$Base=Get-DiskBase}
    if(-not $Base -or -not [IO.Path]::IsPathRooted($Base)){throw 'Нужен полный путь к корню Disk'}
    $full=[IO.Path]::GetFullPath($Base);$root=[IO.Path]::GetPathRoot($full)
    if($full.Length -gt $root.Length){$full=$full.TrimEnd('\','/')};$full
}
# Desired state: rows of key/name/value/kind. Install writes them all, Test compares them all.
function Get-DiskNavPaneSpec([string]$Base) {
    $Base=Get-DiskNavPaneBase $Base;$label=[IO.Path]::GetFileName($Base);if(-not $label){$label='Disk'}
    $rows=New-Object Collections.ArrayList
    function Add-Row($Key,$Name,$Value,$Kind){[void]$rows.Add([pscustomobject]@{key=$Key;name=$Name;value=$Value;kind=$Kind})}
    foreach($c in Get-DiskNavPaneClassKeys){
        Add-Row $c '' $label String
        Add-Row $c 'System.IsPinnedToNameSpaceTree' ([int]1) DWord
        Add-Row $c 'SortOrderIndex' ([int]0x42) DWord
        Add-Row ($c+'\DefaultIcon') '' '%SystemRoot%\system32\imageres.dll,-3' ExpandString
        Add-Row ($c+'\InProcServer32') '' '%SystemRoot%\system32\shell32.dll' ExpandString
        Add-Row ($c+'\Instance') 'CLSID' '{0E5AAE11-A475-4c5b-AB00-C66DE400274E}' String
        Add-Row ($c+'\Instance\InitPropertyBag') 'Attributes' ([int]0x11) DWord
        Add-Row ($c+'\Instance\InitPropertyBag') 'TargetFolderPath' $Base String
        Add-Row ($c+'\ShellFolder') 'FolderValueFlags' ([int]0x28) DWord
        Add-Row ($c+'\ShellFolder') 'Attributes' ([BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]4034920525),0)) DWord # 0xF080004D
    }
    Add-Row $script:DiskNavPaneDesktop '' $label String
    Add-Row $script:DiskNavPaneHidden $script:DiskNavPaneGuid ([int]1) DWord
    $rows
}
# Idempotent: rewriting every value also moves the entry to a new Disk root.
function Install-DiskNavPane([string]$Base) {
    if(-not (Test-DiskNavPaneWindows)){throw 'Значок Disk в Проводнике есть только в Windows'}
    $Base=Get-DiskNavPaneBase $Base
    if(-not [IO.Directory]::Exists($Base)){throw ('Нет папки Disk: '+$Base)}
    foreach($row in Get-DiskNavPaneSpec $Base){Set-DiskNavPaneValue $row.key $row.name $row.value $row.kind}
    Update-DiskNavPaneShell
    if(-not (Test-DiskNavPane $Base).ok){throw 'Значок Disk в Проводнике записан не полностью'}
}
function Remove-DiskNavPane {
    # Both class copies regardless of OS bitness: removal must not depend on how it was installed.
    foreach($c in @(('Software\Classes\CLSID\'+$script:DiskNavPaneGuid),('Software\Classes\Wow6432Node\CLSID\'+$script:DiskNavPaneGuid),$script:DiskNavPaneDesktop)){Remove-DiskNavPaneKey $c}
    Remove-DiskNavPaneValue $script:DiskNavPaneHidden $script:DiskNavPaneGuid
    Update-DiskNavPaneShell
}
# Honest status: installed = our CLSID exists; ok = every value matches the expected Disk root.
function Test-DiskNavPane([string]$Base) {
    $class='Software\Classes\CLSID\'+$script:DiskNavPaneGuid
    $target=Get-DiskNavPaneValue ($class+'\Instance\InitPropertyBag') 'TargetFolderPath'
    $installed=$null -ne (Get-DiskNavPaneValue $class 'System.IsPinnedToNameSpaceTree')
    $ok=$false
    if($installed){
        try{$spec=Get-DiskNavPaneSpec $Base}catch{$spec=$null}
        if($spec){$ok=$true;foreach($row in $spec){$v=Get-DiskNavPaneValue $row.key $row.name;if($null -eq $v -or [string]$v -cne [string]$row.value){$ok=$false;break}}}
    }
    [pscustomobject]@{installed=$installed;target=[string]$target;ok=$ok}
}
