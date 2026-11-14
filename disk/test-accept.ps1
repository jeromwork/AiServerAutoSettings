#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
if(-not $TestHome){$TestHome=Join-Path ([IO.Path]::GetTempPath()) ('disk-accept-'+[guid]::NewGuid().ToString('N'))}
[void][IO.Directory]::CreateDirectory($TestHome)
. (Join-Path $PSScriptRoot 'Disk.Common.ps1')
. (Join-Path $PSScriptRoot 'test-fixture.ps1')
$oldLocal=$env:LOCALAPPDATA;$oldUser=$env:USERPROFILE
$env:LOCALAPPDATA=Join-Path $TestHome 'local';$env:USERPROFILE=Join-Path $TestHome 'user'
$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'
$count=0
function Assert($Value,[string]$Label){if(-not $Value){throw ('FAIL: '+$Label)};$script:count++}
function Refuses([scriptblock]$Action){try{& $Action|Out-Null;return $false}catch{return $true}}
try{
    $bundle=New-DiskInstallFixture $TestHome
    [void][IO.Directory]::CreateDirectory((Join-Path $script:DiskHome 'state'))
    [void][IO.Directory]::CreateDirectory((Join-Path $script:DiskHome 'tray'))
    $xml=Join-Path $script:DiskHome 'state/config.xml'
    $xmlText='<configuration><!-- preserve byte for byte --><gui><address>127.0.0.1:8384</address><apikey>fixture</apikey></gui><folder id="Keep" path="untouched"/><options><natEnabled>true</natEnabled></options></configuration>'+"`r`n"
    [IO.File]::WriteAllText($xml,$xmlText,(New-Object Text.UTF8Encoding($true)))
    Write-DiskUtf8 (Join-Path $script:DiskHome 'tray/syncthingtray.exe') 'existing engine'
    Write-DiskUtf8 (Join-Path $script:DiskHome 'tray/syncthingtray.ini') 'existing tray settings'
    Write-DiskUtf8 (Join-Path $script:DiskHome 'server.txt') "PEER`r`n"
    $base=Join-Path $env:USERPROFILE 'Disk'
    $keepPath=Join-Path $base 'Keep';[void][IO.Directory]::CreateDirectory($keepPath)
    $userFile=Join-Path $keepPath 'mine.txt';Write-DiskUtf8 $userFile 'local data'
    $custom=Join-Path $TestHome 'Custom folder';[void][IO.Directory]::CreateDirectory($custom)
    $ignore=Join-Path $custom '.stignore';Write-DiskUtf8 $ignore 'my own rules'
    $api=Join-Path $script:DiskHome 'fixture-api.json'
    $initial=@{folders=@(@{id='Keep';path=$keepPath;type='receiveonly';paused=$true;maxConflicts=17;devices=@(@{deviceID='OTHER'})});devices=@(@{deviceID='PEER';addresses=@('tcp://127.0.0.1:22123');autoAcceptFolders=$false;name='Personal name'});writes=0;polls=0;noOffer=$false;race=$false}
    Write-DiskUtf8 $api ($initial|ConvertTo-Json -Depth 20)
    $mock=@'
function Invoke-DiskSsh {throw 'Повторное знакомство через SSH запрещено тестом'}
function Invoke-DiskServer {throw 'Повторная регистрация на сервере запрещена тестом'}
function Invoke-DiskApi($Route,$Method='GET',$Body=$null) {
    $file=Join-Path $script:DiskHome 'fixture-api.json';$data=[IO.File]::ReadAllText($file)|ConvertFrom-Json
    $result=$null
    switch($Route){
        'system/status' {$result=@{myID='LOCAL'}}
        'config/devices' {$result=$data.devices}
        'config/folders' {
            if($Method -eq 'GET'){$result=$data.folders}else{
                if($Method -ne 'POST'){throw 'Expected collection POST'}
                $data.folders=@($data.folders)+@($Body);$data.writes++
            }
        }
        'cluster/pending/folders' {
            $data.polls++
            if($data.race -and -not @($data.folders|Where-Object {$_.id -ceq 'Race'}).Count){$data.folders=@($data.folders)+@(@{id='Race';path=(Join-Path $env:USERPROFILE 'Disk/Race');type='receiveonly'})}
            if($data.noOffer){$result=@{Fallback=@{offeredBy=@{OTHER=@{label='wrong device'}}}}}
            elseif($data.polls -eq 1){$result=@{Default=@{offeredBy=@{OTHER=@{label='wrong device'}}}}}
            else{$result=@{Default=@{offeredBy=@{PEER=@{label='default'}}};Custom=@{offeredBy=@{PEER=@{label='custom'}}};Race=@{offeredBy=@{PEER=@{label='race'}}}}}
        }
        default {throw ('Unexpected local REST '+$Method+' '+$Route)}
    }
    Write-DiskUtf8 $file ($data|ConvertTo-Json -Depth 30)
    foreach($item in $result){$item}
}
'@
    Add-DiskFixtureCode $bundle $mock
    $accept=Join-Path $TestHome 'accept.json'
    $json=@{folders=@(@{id='Default'},@{id='Custom';path=$custom},@{id='Keep';path=(Join-Path $TestHome 'do-not-move')})}|ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($accept,$json.Replace("`n","`r`n"),(New-Object Text.UTF8Encoding($true)))
    $before=(Get-FileHash -LiteralPath $xml).Hash
    $null=Invoke-DiskFixture $bundle @('-AcceptFile',$accept)
    $data=[IO.File]::ReadAllText($api)|ConvertFrom-Json
    Assert ($data.writes -eq 2 -and $data.polls -eq 2) 'AcceptFile waits for offers from the server and accepts only missing IDs'
    $default=@($data.folders|Where-Object {$_.id -ceq 'Default'})[0]
    $explicit=@($data.folders|Where-Object {$_.id -ceq 'Custom'})[0]
    Assert ($default.path -ceq (Join-Path $base 'Default') -and $explicit.path -ceq $custom) 'AcceptFile supports default and explicit absolute paths'
    Assert ($default.type -ceq 'sendreceive' -and 'PEER' -cin @($default.devices|ForEach-Object {$_.deviceID}) -and 'LOCAL' -cin @($default.devices|ForEach-Object {$_.deviceID})) 'accepted folder uses server ID and sendreceive with both devices'
    Assert ([IO.File]::ReadAllText($ignore) -ceq 'my own rules') 'existing user ignore rules are preserved'
    $keep=@($data.folders|Where-Object {$_.id -ceq 'Keep'})[0]
    Assert ($keep.path -ceq $keepPath -and $keep.type -ceq 'receiveonly' -and $keep.paused -and $keep.maxConflicts -eq 17) 'existing folder path and options are preserved'
    $snapshot=ConvertTo-Json -InputObject $data.folders -Depth 20 -Compress
    $null=Invoke-DiskFixture $bundle @('-AcceptFile',$accept)
    $null=Invoke-DiskFixture $bundle @()
    $data=[IO.File]::ReadAllText($api)|ConvertFrom-Json
    Assert ($data.writes -eq 2 -and $data.polls -eq 2 -and (ConvertTo-Json -InputObject $data.folders -Depth 20 -Compress) -ceq $snapshot) 'repeated installation and missing AcceptFile perform no folder writes or polling'
    Assert ((Get-FileHash -LiteralPath $xml).Hash -ceq $before -and [IO.File]::ReadAllText($userFile) -ceq 'local data') 'installation preserves config.xml bytes and user files'
    Assert ([IO.File]::ReadAllText((Join-Path $script:DiskHome 'tray/syncthingtray.exe')) -ceq 'existing engine' -and [IO.File]::ReadAllText((Join-Path $script:DiskHome 'tray/syncthingtray.ini')) -ceq 'existing tray settings') 'installed engine and Tray settings remain intact'
    $data.race=$true;Write-DiskUtf8 $api ($data|ConvertTo-Json -Depth 30)
    Write-DiskUtf8 $accept '{"folders":[{"id":"Race"}]}'
    $null=Invoke-DiskFixture $bundle @('-AcceptFile',$accept)
    $data=[IO.File]::ReadAllText($api)|ConvertFrom-Json
    Assert ($data.writes -eq 2 -and @($data.folders|Where-Object {$_.id -ceq 'Race'})[0].type -ceq 'receiveonly') 'acceptance in Tray during wait is preserved'
    $data.noOffer=$true;Write-DiskUtf8 $api ($data|ConvertTo-Json -Depth 30)
    Write-DiskUtf8 $accept '{"folders":[{"id":"Fallback"}]}'
    $watch=[Diagnostics.Stopwatch]::StartNew();$null=Invoke-DiskFixture $bundle @('-AcceptFile',$accept)
    $data=[IO.File]::ReadAllText($api)|ConvertFrom-Json
    Assert ($watch.Elapsed.TotalSeconds -ge 29 -and $watch.Elapsed.TotalSeconds -lt 40 -and @($data.folders|Where-Object {$_.id -ceq 'Fallback'}).Count -eq 1) 'without a server offer the same ID is created after about 30 seconds'
    foreach($bad in @('{"folders":{}}','{"folders":[{"id":"../escape"}]}','{"folders":[{"id":"A"},{"id":"a"}]}','{"folders":[{"id":"A","path":"relative"}]}','{"folders":[{"id":"A","path":0}]}','{}')){
        Write-DiskUtf8 $accept $bad;Assert (Refuses {Read-DiskAcceptFile $accept}) 'invalid AcceptFile rejected before accepting folders'
    }
    $script:preflightCalls=0
    function Invoke-DiskApi($Route,$Method='GET',$Body=$null){
        if($Route -ceq 'config/folders' -and $Method -ceq 'GET'){return @{id='Keep';path=$keepPath}}
        $script:preflightCalls++;throw 'Path validation must finish before polling or mutation'
    }
    Assert (Refuses {Accept-DiskFolders @(@{id='Nested';path=(Join-Path $keepPath 'nested')}) 'PEER' 'LOCAL'}) 'overlap with an existing folder is refused'
    Assert (Refuses {Accept-DiskFolders @(@{id='One';path=$custom},@{id='Two';path=(Join-Path $custom 'nested')}) 'PEER' 'LOCAL'}) 'overlapping requested paths are refused before any folder is accepted'
    Assert (Refuses {Accept-DiskFolders @(@{id='File';path=$userFile}) 'PEER' 'LOCAL'}) 'a file cannot become a Syncthing folder'
    $link=Join-Path $TestHome 'link';$kind='SymbolicLink';if($env:OS -eq 'Windows_NT'){$kind='Junction'}
    [void](New-Item -ItemType $kind -Path $link -Target $custom)
    Assert (Refuses {Accept-DiskFolders @(@{id='Link';path=(Join-Path $link 'child')}) 'PEER' 'LOCAL'}) 'acceptance cannot follow a junction'
    Assert ($script:preflightCalls -eq 0 -and [IO.File]::ReadAllText($userFile) -ceq 'local data') 'invalid batches perform no polling or writes and preserve files'
    # Device updates preserve unrelated settings and are idempotent.
    function Get-TransportEffectivePort {22123}
    $script:device=[pscustomobject]@{deviceID='PEER';addresses=@('dynamic');autoAcceptFolders=$true;name='User name'};$script:patches=0
    function Invoke-DiskApi($Route,$Method='GET',$Body=$null){
        if($Route -eq 'config/devices'){return $script:device}
        $script:patches++;Assert ($Method -ceq 'PATCH' -and $Body.Keys.Count -eq 2) 'existing server device receives only the required patch'
        $script:device.addresses=$Body.addresses;$script:device.autoAcceptFolders=$Body.autoAcceptFolders
    }
    Set-DiskServerDevice 'PEER';Set-DiskServerDevice 'PEER'
    Assert ($script:patches -eq 1 -and -not $script:device.autoAcceptFolders -and $script:device.name -ceq 'User name') 'autoAcceptFolders is false and unrelated device settings survive'
    $script:device=$null
    function Invoke-DiskApi($Route,$Method='GET',$Body=$null){if($Route -eq 'config/devices'){return};$script:newDevice=$Body;Assert ($Method -ceq 'PUT') 'new server device is registered once'}
    Set-DiskServerDevice 'NEW'
    Assert (-not $script:newDevice.autoAcceptFolders -and $script:newDevice.deviceID -ceq 'NEW') 'new device never accepts unsolicited folders automatically'
    Write-Output ('PASS: '+$count+' AcceptFile/update/device checks (offline REST fixtures; real installer children and 30-second wait)')
}finally{$env:LOCALAPPDATA=$oldLocal;$env:USERPROFILE=$oldUser}
