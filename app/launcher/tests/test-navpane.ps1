#requires -Version 5.1
# Explorer Disk entry against an in-memory HKCU; the live registry is checked on Windows only.
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'disk/Disk.Common.ps1')
$script:DiskHome=Join-Path $TestHome 'RemoteDisk';[void][IO.Directory]::CreateDirectory($script:DiskHome)
$env:USERPROFILE=$TestHome
$script:count=0
function Assert($ok,$name){if(-not $ok){throw ('FAIL '+$name)};$script:count++;Write-Output ('PASS '+$name)}

Assert ((Get-Command Install-DiskNavPane -ErrorAction SilentlyContinue) -and (Get-Command Remove-DiskNavPane -ErrorAction SilentlyContinue)) 'Disk.Common loads the nav pane module'
# Off Windows the real adapters touch nothing and installing is refused, not faked.
Assert (-not (Test-DiskNavPane (Join-Path $TestHome 'x')).installed) 'non-Windows reports not installed'
$refused=$false;try{Install-DiskNavPane (Join-Path $TestHome 'x')}catch{$refused=$true};Assert $refused 'non-Windows install refused'
Remove-DiskNavPane;Assert $true 'non-Windows remove is a no-op'

$script:reg=@{};$script:notify=0;$script:kinds=@{}
function Test-DiskNavPaneWindows {$true}
function Get-DiskNavPaneValue([string]$Key,[string]$Name){$script:reg[$Key+'|'+$Name]}
function Set-DiskNavPaneValue([string]$Key,[string]$Name,$Value,[string]$Kind){$script:reg[$Key+'|'+$Name]=$Value;$script:kinds[$Key+'|'+$Name]=$Kind}
function Remove-DiskNavPaneKey([string]$Key){foreach($k in @($script:reg.Keys)){if($k.StartsWith($Key+'|') -or $k.StartsWith($Key+'\')){$script:reg.Remove($k)}}}
function Remove-DiskNavPaneValue([string]$Key,[string]$Name){$script:reg.Remove($Key+'|'+$Name)}
function Update-DiskNavPaneShell {$script:notify++}
function Snapshot {($script:reg.Keys|Sort-Object|ForEach-Object {$_+'='+$script:reg[$_]}) -join "`n"}

$guid='{5D8A825B-EDEA-4B5E-97FC-96ABDC8A78E9}';$cls='Software\Classes\CLSID\'+$guid
$base=Join-Path $TestHome 'Disk';[void][IO.Directory]::CreateDirectory($base)
$missing=$false;try{Install-DiskNavPane (Join-Path $TestHome 'absent')}catch{$missing=$true};Assert ($missing -and $script:reg.Count -eq 0) 'missing Disk root refused before any write'
$relative=$false;try{Install-DiskNavPane 'Disk'}catch{$relative=$true};Assert $relative 'relative root refused'

Install-DiskNavPane ($base+[IO.Path]::DirectorySeparatorChar)
$expect=@{
    ($cls+'|')='Disk'
    ($cls+'|System.IsPinnedToNameSpaceTree')=1
    ($cls+'|SortOrderIndex')=0x42
    ($cls+'\DefaultIcon|')='%SystemRoot%\system32\imageres.dll,-3'
    ($cls+'\InProcServer32|')='%SystemRoot%\system32\shell32.dll'
    ($cls+'\Instance|CLSID')='{0E5AAE11-A475-4c5b-AB00-C66DE400274E}'
    ($cls+'\Instance\InitPropertyBag|Attributes')=0x11
    ($cls+'\Instance\InitPropertyBag|TargetFolderPath')=$base
    ($cls+'\ShellFolder|FolderValueFlags')=0x28
    ('Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\'+$guid+'|')='Disk'
    ('Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel|'+$guid)=1
}
$bad=@($expect.Keys|Where-Object {[string]$script:reg[$_] -cne [string]$expect[$_]});Assert ($bad.Count -eq 0) ('expected keys and values ('+($bad -join ', ')+')')
Assert ([uint32]('0x{0:X8}' -f $script:reg[$cls+'\ShellFolder|Attributes']) -eq [uint32]4034920525 -and $script:kinds[$cls+'\ShellFolder|Attributes'] -eq 'DWord') 'ShellFolder Attributes is DWORD 0xF080004D'
Assert (@($script:kinds.Keys|Where-Object {$script:kinds[$_] -eq 'DWord' -and $script:reg[$_] -isnot [int]}).Count -eq 0) 'every DWORD value is an Int32, not a string'
Assert ($script:kinds[$cls+'\InProcServer32|'] -eq 'ExpandString' -and $script:kinds[$cls+'\DefaultIcon|'] -eq 'ExpandString' -and $script:kinds[$cls+'|System.IsPinnedToNameSpaceTree'] -eq 'DWord') 'value kinds'
Assert ($script:reg[('Software\Classes\Wow6432Node\CLSID\'+$guid+'\Instance\InitPropertyBag|TargetFolderPath')] -eq $base) '32-bit dialogs get the same entry on 64-bit OS'
Assert (@($script:reg.Keys|Where-Object {$_ -notmatch '^Software\\(Classes\\(Wow6432Node\\)?CLSID\\|Microsoft\\Windows\\CurrentVersion\\Explorer\\)'}).Count -eq 0) 'only per-user Classes and Explorer keys are written'
Assert ($script:notify -eq 1) 'shell notified once'
$t=Test-DiskNavPane $base;Assert ($t.installed -and $t.ok -and $t.target -eq $base) 'status ok after install'

$first=Snapshot;Install-DiskNavPane $base;Assert ((Snapshot) -ceq $first) 'install is idempotent'

$moved=Join-Path $TestHome 'Moved Disk';[void][IO.Directory]::CreateDirectory($moved)
Assert (-not (Test-DiskNavPane $moved).ok) 'status not ok for a different root'
Set-DiskBase $moved
Assert ($script:reg[$cls+'\Instance\InitPropertyBag|TargetFolderPath'] -eq $moved -and $script:reg[$cls+'|'] -eq 'Moved Disk') 'Disk root change updates target and label'
Assert ((Test-DiskNavPane $moved).ok) 'status ok after root change'
$script:reg[$cls+'\ShellFolder|FolderValueFlags']=0;Assert (-not (Test-DiskNavPane $moved).ok) 'tampered value reported, not hidden'

$script:reg['Software\Classes\CLSID\{OTHER}|']='keep';$script:reg['Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel|{OTHER}']=1
Remove-DiskNavPane
$left=@($script:reg.Keys|Where-Object {$_.Contains($guid)});Assert ($left.Count -eq 0) ('remove cleans every key and value ('+($left -join ', ')+')')
Assert ($script:reg.Count -eq 2) 'remove leaves foreign entries'
$t=Test-DiskNavPane $moved;Assert (-not $t.installed -and -not $t.ok) 'status after remove'
Remove-DiskNavPane;Assert ($script:reg.Count -eq 2) 'remove is idempotent'

$other=Join-Path $TestHome 'Third';[void][IO.Directory]::CreateDirectory($other);Set-DiskBase $other
Assert (@($script:reg.Keys|Where-Object {$_.Contains($guid)}).Count -eq 0) 'root change does not install a removed entry'

$script:fail=$true
function Set-DiskNavPaneValue([string]$Key,[string]$Name,$Value,[string]$Kind){if($script:fail -and $Name -eq 'TargetFolderPath'){return};$script:reg[$Key+'|'+$Name]=$Value}
$partial=$false;try{Install-DiskNavPane $other}catch{$partial=$true};Assert $partial 'incomplete write is reported as failure'
Remove-DiskNavPane
Write-Output ('navpane: '+$script:count+' passed')
