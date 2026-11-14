#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
if(-not $TestHome){$TestHome=Join-Path ([IO.Path]::GetTempPath()) ('disk-cleanup-'+[guid]::NewGuid().ToString('N'))}
[void][IO.Directory]::CreateDirectory($TestHome)
. (Join-Path $PSScriptRoot 'Disk.Common.ps1')
. (Join-Path $PSScriptRoot 'test-fixture.ps1')
$oldLocal=$env:LOCALAPPDATA;$oldUser=$env:USERPROFILE
$env:LOCALAPPDATA=Join-Path $TestHome 'local';$env:USERPROFILE=Join-Path $TestHome 'user'
$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'
$count=0
function Assert($Value,[string]$Label){if(-not $Value){throw ('FAIL: '+$Label)};$script:count++}
try{
    $bundle=New-DiskInstallFixture $TestHome
    [void][IO.Directory]::CreateDirectory((Join-Path $script:DiskHome 'state'))
    $xml=Join-Path $script:DiskHome 'state/config.xml';Write-DiskUtf8 $xml 'not parsed by cleanup'
    $xmlHash=(Get-FileHash -LiteralPath $xml).Hash
    $base=Join-Path $env:USERPROFILE 'Disk';$owned=Join-Path $base 'Owned';$original=Join-Path $base 'OriginalReadOnly'
    $empty=Join-Path $base 'Empty';$preexisting=Join-Path $base 'Preexisting';$foreign=Join-Path $base 'Foreign'
    $external=Join-Path $TestHome 'External';$linkTarget=Join-Path $TestHome 'Link target'
    foreach($path in @($owned,$original,$empty,$preexisting,$foreign,$external,$linkTarget)){[void][IO.Directory]::CreateDirectory($path)}
    $ini="[.ShellClassInfo]`r`nInfoTip=Disk`r`n[RemoteAgents]`r`nOwner=RemoteAgents.Disk.v1`r`nOriginalReadOnly=0`r`nPlaceholder=1`r`nCreatedDirectory=1`r`n"
    Write-DiskUtf8 (Join-Path $owned 'mine.txt') 'keep user content'
    Write-DiskUtf8 (Join-Path $owned '.stignore') 'keep user rules'
    Write-DiskUtf8 (Join-Path $external 'external.txt') 'keep external content'
    Write-DiskUtf8 (Join-Path $original 'keep.txt') 'original readonly folder'
    foreach($path in @($owned,$empty,$original,$preexisting,$external,$linkTarget)){
        $text=$ini
        if($path -ceq $original){$text=$text.Replace('OriginalReadOnly=0','OriginalReadOnly=1')}
        if($path -ceq $preexisting){$text=$text.Replace('CreatedDirectory=1','CreatedDirectory=0')}
        [IO.File]::WriteAllText((Join-Path $path 'desktop.ini'),$text,(New-Object Text.UTF8Encoding($true)))
        [IO.File]::SetAttributes($path,([IO.File]::GetAttributes($path) -bor [IO.FileAttributes]::ReadOnly))
    }
    Write-DiskUtf8 (Join-Path $foreign 'desktop.ini') 'foreign customization'
    $link=Join-Path $base 'Link';$kind='SymbolicLink';if($env:OS -eq 'Windows_NT'){$kind='Junction'}
    [void](New-Item -ItemType $kind -Path $link -Target $linkTarget)
    Write-DiskUtf8 (Join-Path $script:DiskHome 'external.json') (@{schema=1;items=@(@{path=$external;remote='External'})}|ConvertTo-Json -Depth 10)
    $icons=Join-Path $env:LOCALAPPDATA 'RemoteAgents/icons';[void][IO.Directory]::CreateDirectory($icons)
    Write-DiskUtf8 (Join-Path $icons 'RemoteAgents.Disk.v1.Synced.ico') 'own'
    Write-DiskUtf8 (Join-Path $icons 'foreign.ico') 'foreign'
    $regFile=Join-Path $script:DiskHome 'registry.json'
    $verb='Software\Classes\Directory\shell\RemoteAgents.Disk.download'
    $other='Software\Classes\Directory\shell\RemoteAgents.Disk.add'
    $pin='Software\Classes\CLSID\'+$script:DiskNavPaneGuid
    $registry=@{}
    $registry[$verb+'|RemoteAgentsOwner']='RemoteAgents.Disk.v1'
    $registry[$verb+'\command|']='owned command'
    $registry[$other+'|RemoteAgentsOwner']='Other.Application'
    $registry[$pin+'|System.IsPinnedToNameSpaceTree']=1
    $registry[$pin+'\Instance\InitPropertyBag|TargetFolderPath']=$base
    Write-DiskUtf8 $regFile ($registry|ConvertTo-Json)
    $mock=@'
function Read-FixtureRegistry {
    $data=[IO.File]::ReadAllText((Join-Path $script:DiskHome 'registry.json'))|ConvertFrom-Json
    $values=@{};foreach($p in $data.PSObject.Properties){$values[$p.Name]=$p.Value};$values
}
function Get-DiskNavPaneValue([string]$Key,[string]$Name){$values=Read-FixtureRegistry;$values[$Key+'|'+$Name]}
function Remove-DiskNavPaneKey([string]$Key){
    $values=Read-FixtureRegistry
    foreach($name in @($values.Keys)){if($name.StartsWith($Key+'|') -or $name.StartsWith($Key+'\')){$values.Remove($name)}}
    Write-DiskUtf8 (Join-Path $script:DiskHome 'registry.json') ($values|ConvertTo-Json)
}
function Remove-DiskNavPaneValue([string]$Key,[string]$Name){
    $values=Read-FixtureRegistry;$values.Remove($Key+'|'+$Name)
    Write-DiskUtf8 (Join-Path $script:DiskHome 'registry.json') ($values|ConvertTo-Json)
}
function Update-DiskNavPaneShell {}
function Update-DiskLegacyItem {}
function Read-DiskState {throw 'Cleanup must not read config.xml'}
function Invoke-DiskApi {throw 'Cleanup must not call Syncthing REST'}
function Invoke-DiskSsh {throw 'Cleanup must not call SSH'}
'@
    Add-DiskFixtureCode $bundle $mock
    $null=Invoke-DiskFixture $bundle @('-CleanupLegacy')
    $reg=[IO.File]::ReadAllText($regFile)|ConvertFrom-Json
    Assert ($null -eq $reg.PSObject.Properties[$verb+'|RemoteAgentsOwner'] -and $null -eq $reg.PSObject.Properties[$verb+'\command|']) 'CleanupLegacy removes owned shell verbs and command subkeys'
    Assert ($reg.($other+'|RemoteAgentsOwner') -ceq 'Other.Application') 'foreign shell verb survives'
    Assert ($reg.($pin+'|System.IsPinnedToNameSpaceTree') -eq 1 -and $reg.($pin+'\Instance\InitPropertyBag|TargetFolderPath') -ceq $base) 'CleanupLegacy preserves Disk NavPane registration'
    Assert (-not [IO.File]::Exists((Join-Path $owned 'desktop.ini')) -and -not ([IO.File]::GetAttributes($owned) -band [IO.FileAttributes]::ReadOnly)) 'owned desktop.ini removed and original writable attribute restored'
    Assert ([IO.File]::GetAttributes($original) -band [IO.FileAttributes]::ReadOnly) 'original ReadOnly restored'
    Assert (-not [IO.Directory]::Exists($empty) -and [IO.Directory]::Exists($preexisting) -and [IO.Directory]::Exists($owned)) 'only empty product-created placeholders are removed'
    Assert ([IO.File]::ReadAllText((Join-Path $owned 'mine.txt')) -ceq 'keep user content' -and [IO.File]::ReadAllText((Join-Path $owned '.stignore')) -ceq 'keep user rules') 'user content and ignore rules survive'
    Assert ([IO.File]::ReadAllText((Join-Path $foreign 'desktop.ini')) -ceq 'foreign customization') 'foreign desktop.ini survives'
    Assert (-not [IO.File]::Exists((Join-Path $external 'desktop.ini')) -and [IO.File]::ReadAllText((Join-Path $external 'external.txt')) -ceq 'keep external content') 'explicit external metadata cleaned without changing source files'
    Assert (([IO.File]::GetAttributes($link) -band [IO.FileAttributes]::ReparsePoint) -and [IO.File]::Exists((Join-Path $linkTarget 'desktop.ini'))) 'junctions and their targets are left intact'
    Assert (-not [IO.File]::Exists((Join-Path $icons 'RemoteAgents.Disk.v1.Synced.ico')) -and [IO.File]::ReadAllText((Join-Path $icons 'foreign.ico')) -ceq 'foreign') 'only product icon files removed'
    Assert ((Get-FileHash -LiteralPath $xml).Hash -ceq $xmlHash) 'CleanupLegacy never reads or changes Syncthing config.xml'
    $before=[IO.File]::ReadAllText($regFile)
    $null=Invoke-DiskFixture $bundle @('-CleanupLegacy')
    Assert ([IO.File]::ReadAllText($regFile) -ceq $before -and (Get-FileHash -LiteralPath $xml).Hash -ceq $xmlHash) 'repeated cleanup is idempotent'
    $null=Invoke-DiskFixture $bundle @('-Uninstall')
    $reg=[IO.File]::ReadAllText($regFile)|ConvertFrom-Json
    Assert ($null -eq $reg.PSObject.Properties[$pin+'|System.IsPinnedToNameSpaceTree'] -and $reg.($other+'|RemoteAgentsOwner') -ceq 'Other.Application') 'Uninstall additionally removes only the Disk navigation entry'
    Assert ([IO.File]::ReadAllText((Join-Path $owned 'mine.txt')) -ceq 'keep user content' -and (Get-FileHash -LiteralPath $xml).Hash -ceq $xmlHash) 'Uninstall preserves user data and Syncthing configuration'
    Write-Output ('PASS: '+$count+' CleanupLegacy/Uninstall checks (real installer children, CRLF metadata, mocked HKCU)')
}finally{$env:LOCALAPPDATA=$oldLocal;$env:USERPROFILE=$oldUser}
