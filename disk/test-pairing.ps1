#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
if(-not $TestHome){$TestHome=Join-Path ([IO.Path]::GetTempPath()) ('disk-pairing-'+[guid]::NewGuid().ToString('N'))}
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
    $mock=@'
function Read-DiskProfile {param($Profile) $script:ProfilePath=$Profile}
function Invoke-DiskSsh {
    param($Command,[switch]$Direct,$InputText)
    if(-not $Direct -or $InputText -notlike '*server-disk.sh*bootstrap*'){throw 'Expected one bootstrap via the configured SSH route'}
    [IO.File]::AppendAllText((Join-Path $script:DiskHome 'bootstrap-count'),'1')
    if([IO.File]::ReadAllText((Join-Path $script:DiskHome 'bootstrap-count')).Length -lt 3){throw 'Тест: разрыв bootstrap'}
    '{"deviceId":"PEER"}'
}
function Invoke-DiskServer {
    param($Action,$Data,[switch]$Direct)
    if($Action -cne 'add-device' -or -not $Direct -or $Data.deviceId -cne 'LOCAL'){throw 'Expected one device registration'}
    [IO.File]::AppendAllText((Join-Path $script:DiskHome 'pair-count'),'1')
    if([IO.File]::ReadAllText((Join-Path $script:DiskHome 'pair-count')).Length -lt 3){throw 'Тест: разрыв add-device'}
}
function Invoke-DiskProcess($Exe,$Arguments) {
    if($Arguments[0] -cne 'syncthing' -or $Arguments[1] -cne 'generate'){throw 'Only initial state generation is allowed'}
    [void][IO.Directory]::CreateDirectory((Join-Path $script:DiskHome 'state'))
    Write-DiskUtf8 (Join-Path $script:DiskHome 'state/config.xml') '<configuration><folder id="default" path="unused"/><gui><address>127.0.0.1:8384</address><apikey>fixture</apikey></gui><options><natEnabled>true</natEnabled></options></configuration>'
}
function Invoke-DiskApi($Route,$Method='GET',$Body=$null) {
    if($Route -eq 'system/status'){
        if(-not (Test-Path -LiteralPath (Join-Path $script:DiskHome 'running'))){throw 'Not started yet'}
        return @{myID='LOCAL'}
    }
    $file=Join-Path $script:DiskHome 'device.json'
    if($Route -eq 'config/folders' -and $Method -eq 'GET'){return}
    if($Route -eq 'config/defaults/folder'){
        $defaults=Join-Path $script:DiskHome 'defaults.json'
        if($Method -eq 'GET'){if(Test-Path -LiteralPath $defaults){[IO.File]::ReadAllText($defaults)|ConvertFrom-Json}else{@{fsWatcherDelayS=10}};return}
        if($Method -ne 'PATCH' -or $Body.fsWatcherDelayS -ne 2){throw 'Expected watcher defaults patch'}
        Write-DiskUtf8 $defaults ($Body|ConvertTo-Json);return
    }
    if($Route -eq 'config/devices'){if(Test-Path -LiteralPath $file){[IO.File]::ReadAllText($file)|ConvertFrom-Json};return}
    if($Route -eq 'config/devices/PEER' -and $Method -eq 'PUT'){
        Write-DiskUtf8 $file ($Body|ConvertTo-Json -Depth 20);return
    }
    throw ('No folder REST calls expected without AcceptFile: '+$Route)
}
'@
    Add-DiskFixtureCode $bundle $mock
    $binary=@'
function Install-DiskBinary($Url,$Hash,$Directory,$Name) {
    $target=Join-Path $script:DiskHome ($Directory+'/'+$Name)
    [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
    Write-DiskUtf8 $target 'installed engine'
    [IO.File]::AppendAllText((Join-Path $script:DiskHome 'binary-count'),'1')
}
'@
    [IO.File]::AppendAllText((Join-Path $bundle 'disk/Disk.Binary.ps1'),("`n"+$binary),(New-Object Text.UTF8Encoding($false)))
    $engine=@'
function Start-DiskHeadless {
    Write-DiskUtf8 (Join-Path $script:DiskHome 'running') '1'
    [IO.File]::AppendAllText((Join-Path $script:DiskHome 'start-count'),'1')
}
function Wait-DiskTransport {Write-DiskUtf8 (Join-Path $script:DiskHome 'banner-checked') '1'}
'@
    [IO.File]::AppendAllText((Join-Path $bundle 'disk/Disk.Engine.ps1'),("`n"+$engine),(New-Object Text.UTF8Encoding($false)))
    $null=Invoke-DiskFixture $bundle @('-Profile','fixture-profile','-HelpersReady')
    $file=Join-Path $script:DiskHome 'state/config.xml';[xml]$xml=[IO.File]::ReadAllText($file)
    Assert ($xml.configuration.SelectNodes('folder').Count -eq 0) 'fresh install removes only the generated default folder and accepts nothing implicitly'
    Assert ($xml.configuration.gui.address -match '^127\.0\.0\.1:[0-9]+$' -and $xml.configuration.options.listenAddress -match '^tcp://127\.0\.0\.1:[0-9]+$') 'fresh engine binds GUI and sync listener to loopback'
    Assert ($xml.configuration.options.natEnabled -ceq 'false' -and $xml.configuration.options.globalAnnounceEnabled -ceq 'false') 'fresh engine uses the transport channel'
    $device=[IO.File]::ReadAllText((Join-Path $script:DiskHome 'device.json'))|ConvertFrom-Json
    Assert ($device.deviceID -ceq 'PEER' -and -not $device.autoAcceptFolders -and $device.addresses[0] -ceq 'tcp://127.0.0.1:22123') 'server device added with autoAcceptFolders=false'
    Assert ([IO.File]::ReadAllText((Join-Path $script:DiskHome 'server.txt')) -ceq 'PEER' -and (Test-Path (Join-Path $script:DiskHome 'banner-checked'))) 'pairing receipt saved after device exchange and transport checked'
    Assert (Test-Path -LiteralPath (Join-Path $script:DiskHome 'legacy-cleanup-v1')) 'ordinary installation performs the one-time legacy migration'
    Assert (([IO.File]::ReadAllText((Join-Path $script:DiskHome 'defaults.json'))|ConvertFrom-Json).fsWatcherDelayS -eq 2) 'fresh installation sets two-second defaults for manual Tray acceptance'
    $before=(Get-FileHash -LiteralPath $file).Hash
    $null=Invoke-DiskFixture $bundle @('-Profile','fixture-profile','-HelpersReady')
    foreach($name in @('bootstrap-count','pair-count')){Assert ([IO.File]::ReadAllText((Join-Path $script:DiskHome $name)) -ceq '111') 'SSH bootstrap and add-device each succeed on the third attempt and are skipped on repeat install'}
    foreach($name in @('binary-count','start-count')){Assert ([IO.File]::ReadAllText((Join-Path $script:DiskHome $name)) -ceq '1') 'repeat install does not repeat download or engine start'}
    $log=[IO.File]::ReadAllText((Join-Path $script:DiskHome 'install.log'));Assert ($log.Contains('Тест: разрыв bootstrap') -and $log.Contains('Тест: разрыв add-device')) 'both SSH retry failures are logged'
    Assert ((Get-FileHash -LiteralPath $file).Hash -ceq $before) 'repeat install preserves generated state byte for byte'
    Write-Output ('PASS: '+$count+' first installation/pairing checks (real installer children, offline engine/SSH fixtures)')
}finally{$env:LOCALAPPDATA=$oldLocal;$env:USERPROFILE=$oldUser}
