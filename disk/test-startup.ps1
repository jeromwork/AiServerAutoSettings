#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
if(-not $TestHome){$TestHome=Join-Path ([IO.Path]::GetTempPath()) ('disk-startup-'+[guid]::NewGuid().ToString('N'))}
[void][IO.Directory]::CreateDirectory($TestHome)
. (Join-Path $PSScriptRoot 'Disk.Common.ps1')
. (Join-Path $PSScriptRoot 'Disk.Engine.ps1')
. (Join-Path $PSScriptRoot 'test-fixture.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'transport/Transport.Common.ps1')
$oldLocal=$env:LOCALAPPDATA;$env:LOCALAPPDATA=Join-Path $TestHome 'local'
$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk';$launcher=Join-Path $TestHome 'custom-launcher'
$count=0
function Assert($Value,[string]$Text){if(-not $Value){throw ('FAIL: '+$Text)};$script:count++}
try{
    [void][IO.Directory]::CreateDirectory((Join-Path $script:DiskHome 'state'))
    [void][IO.Directory]::CreateDirectory($launcher)
    Write-TransportJson (Join-Path $launcher 'config.json') @{transport=@{syncPort=22123}}
    $configured=Get-TransportConfiguredPorts (Read-TransportJson (Join-Path $launcher 'config.json')).transport $null
    $effective=Copy-TransportObject $configured;$effective.syncPort=22133
    Write-TransportJson (Join-Path $launcher 'state/transport-ports.json') @{schema=1;configured=$configured;effective=$effective}
    Assert ((Get-TransportEffectivePort $launcher 'syncPort') -eq 22133) 'test uses a relocated effective sync port from the actual transport reader'
    Write-DiskUtf8 (Join-Path $script:DiskHome 'server.txt') "PEER`r`n"
    $xml=Join-Path $script:DiskHome 'state/config.xml'
    Write-DiskUtf8 $xml '<configuration><!--keep--><device id="OTHER"><address>dynamic</address></device><device id="PEER" name="Personal" autoAcceptFolders="true"><address>tcp://127.0.0.1:22123</address><compression>always</compression></device><folder id="disk-keep" path="keep"/><gui><address>127.0.0.1:8384</address><apikey>fixture</apikey></gui></configuration>'
    $script:apiDevice=[pscustomobject]@{addresses=@('tcp://127.0.0.1:22123');name='Personal';autoAcceptFolders=$true};$script:patches=0
    function Invoke-DiskSsh {throw 'Startup must never use SSH'}
    function Invoke-DiskApi($Route,$Method='GET',$Body=$null){
        Assert ($Route -ceq 'config/devices/PEER') 'startup only touches the server device REST route'
        if($Method -ceq 'GET'){return $script:apiDevice}
        Assert ($Method -ceq 'PATCH' -and $Body.Keys.Count -eq 1 -and $Body.ContainsKey('addresses')) 'live device receives only the address patch'
        $script:apiDevice.addresses=$Body.addresses;$script:patches++
    }
    $before=(Get-FileHash -LiteralPath $xml).Hash
    Assert (Sync-DiskServerAddress $launcher) 'live REST address is updated before engine startup'
    Assert (-not (Sync-DiskServerAddress $launcher)) 'matching REST address is unchanged'
    Assert ($script:patches -eq 1 -and $script:apiDevice.addresses[0] -ceq 'tcp://127.0.0.1:22133' -and $script:apiDevice.name -ceq 'Personal' -and $script:apiDevice.autoAcceptFolders -and (Get-FileHash -LiteralPath $xml).Hash -ceq $before) 'REST preserves all other settings and config.xml bytes'
    function Invoke-DiskApi {throw 'Engine stopped'}
    function Get-DiskEngineProcesses {}
    Assert (Sync-DiskServerAddress $launcher) 'stopped engine address is updated through config.xml'
    [xml]$saved=[IO.File]::ReadAllText($xml)
    Assert ($saved.configuration.device[1].address -ceq 'tcp://127.0.0.1:22133' -and $saved.configuration.device[1].compression -ceq 'always' -and $saved.configuration.device[1].name -ceq 'Personal' -and $saved.configuration.device[1].autoAcceptFolders -ceq 'true' -and $saved.configuration.device[0].address -ceq 'dynamic' -and $saved.configuration.folder.id -ceq 'disk-keep') 'XML update preserves folders, other devices and server options'
    $before=(Get-FileHash -LiteralPath $xml).Hash
    Assert (-not (Sync-DiskServerAddress $launcher) -and (Get-FileHash -LiteralPath $xml).Hash -ceq $before) 'matching XML address is byte-for-byte unchanged'
    $effective.syncPort=22143;Write-TransportJson (Join-Path $launcher 'state/transport-ports.json') @{schema=1;configured=$configured;effective=$effective}
    function Get-DiskEngineProcesses {@{ProcessId=123}}
    $failed=$false;try{Sync-DiskServerAddress $launcher}catch{$failed=$_.Exception.Message -like 'Syncthing работает, но REST*'}
    Assert ($failed -and (Get-FileHash -LiteralPath $xml).Hash -ceq $before) 'starting engine owns XML; unavailable REST cannot cause an offline overwrite'
    # Run the exact component entry point in a child; injected local boundaries record ordering.
    $bundle=New-DiskInstallFixture (Join-Path $TestHome 'component')
    $mock=@'
function Stop-DiskEngineProcesses {Write-DiskUtf8 (Join-Path $script:DiskHome 'startup-order') 'cleanup|'}
function Sync-DiskServerAddress([string]$LauncherRoot){
    [IO.File]::AppendAllText((Join-Path $script:DiskHome 'startup-order'),('address:'+ $LauncherRoot))
    if(Test-Path -LiteralPath (Join-Path $script:DiskHome 'startup-fail')){throw 'Тест: адрес не обновлён'}
}
function Start-DiskComponent {
    [IO.File]::AppendAllText((Join-Path $script:DiskHome 'startup-order'),'|engine')
    return 0
}
'@
    Add-DiskFixtureCode $bundle $mock
    $repo=Split-Path $PSScriptRoot -Parent
    $component=@(([IO.File]::ReadAllText((Join-Path $repo 'build/components.json'))|ConvertFrom-Json).components|Where-Object {$_.name -ceq 'disk'})[0]
    Assert ($component.exe -ceq 'powershell.exe' -and $component.args -contains '-StartEngine' -and $component.restart -ceq 'always' -and $component.cwd -ceq '{bundle}') 'disk component supervises headless engine and can start before tray directory exists'
    $arguments=@($component.args|ForEach-Object {$_.Replace('{bundle}',$bundle).Replace('{home}',$launcher).Replace('\',[IO.Path]::DirectorySeparatorChar)})
    $null=Invoke-DiskProcess ((Get-Process -Id $PID).Path) $arguments
    Assert ([IO.File]::ReadAllText((Join-Path $script:DiskHome 'startup-order')) -ceq ('cleanup|address:'+$launcher+'|engine')) 'component removes old owners and checks the effective address before starting the headless engine'
    Write-DiskUtf8 (Join-Path $script:DiskHome 'startup-fail') '1'
    $failed=$false;try{Invoke-DiskProcess ((Get-Process -Id $PID).Path) $arguments}catch{$failed=$true}
    Assert ($failed -and [IO.File]::ReadAllText((Join-Path $script:DiskHome 'startup-order')) -ceq ('cleanup|address:'+$launcher)) 'address failure does not start the engine and exits nonzero for supervisor retry'
    $custom=Join-Path $TestHome 'custom-disk';[void][IO.Directory]::CreateDirectory($custom)
    Write-TransportJson (Join-Path $launcher 'config.json') @{disk=@{home=$custom}}
    $null=Invoke-DiskProcess ((Get-Process -Id $PID).Path) $arguments
    Assert ([IO.File]::ReadAllText((Join-Path $custom 'startup-order')) -ceq ('cleanup|address:'+$launcher+'|engine')) 'component honors configured disk.home for engine and UI state'
    Write-Output ('PASS: '+$count+' startup/address checks (actual effective-port reader and component entry point; local fixtures)')
}finally{$env:LOCALAPPDATA=$oldLocal}
