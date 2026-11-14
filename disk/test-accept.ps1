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
    $initial=@{folders=@(@{id='Keep';path=$keepPath;type='receiveonly';paused=$true;maxConflicts=17;devices=@(@{deviceID='OTHER'})});devices=@(@{deviceID='PEER';addresses=@('tcp://127.0.0.1:22123');autoAcceptFolders=$false;name='Personal name'});writes=0;patches=0;defaults=@{fsWatcherDelayS=10;rescanIntervalS=777;fsWatcherEnabled=$false};polls=0;noOffer=$false;race=$false}
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
        'config/defaults/folder' {
            if($Method -eq 'GET'){$result=$data.defaults}else{
                if($Method -cne 'PATCH' -or $Body.Keys.Count -ne 1 -or $Body.fsWatcherDelayS -ne 2){throw 'Expected only the watcher delay patch'}
                $data.defaults.fsWatcherDelayS=2;$data.patches++
            }
        }
        {$_ -like 'config/folders/*'} {
            if($Method -cne 'PATCH' -or $Body.Keys.Count -ne 1 -or $Body.fsWatcherDelayS -ne 2){throw 'Expected only the watcher delay patch'}
            $id=[Uri]::UnescapeDataString($Route.Substring('config/folders/'.Length))
            $folder=@($data.folders|Where-Object {$_.id -ceq $id})[0]
            $folder|Add-Member -Force fsWatcherDelayS 2;$data.patches++
        }
        'cluster/pending/folders' {
            $data.polls++
            if($data.race -and -not @($data.folders|Where-Object {$_.id -ceq 'Race'}).Count){$data.folders=@($data.folders)+@(@{id='Race';path=(Join-Path $env:USERPROFILE 'Disk/Race');type='receiveonly'})}
            if($data.noOffer){$result=@{Fallback=@{offeredBy=@{OTHER=@{label='wrong device'}}}}}
            elseif($data.polls -eq 1){$result=@{Default=@{offeredBy=@{OTHER=@{label='wrong device'}}}}}
            else{$result=@{'disk-0123456789abcdef01234567'=@{offeredBy=@{PEER=@{label='Default'}}};Custom=@{offeredBy=@{PEER=@{label='custom'}}};Race=@{offeredBy=@{PEER=@{label='race'}}}}}
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
    $default=@($data.folders|Where-Object {$_.id -ceq 'disk-0123456789abcdef01234567'})[0]
    $explicit=@($data.folders|Where-Object {$_.id -ceq 'Custom'})[0]
    Assert ($default.path -ceq (Join-Path $base 'Default') -and $explicit.path -ceq $custom) 'AcceptFile supports default and explicit absolute paths'
    Assert ($default.label -ceq 'Default' -and $default.type -ceq 'sendreceive' -and 'PEER' -cin @($default.devices|ForEach-Object {$_.deviceID}) -and 'LOCAL' -cin @($default.devices|ForEach-Object {$_.deviceID})) 'accepted folder uses server ID and sendreceive with both devices'
    Assert ([IO.File]::ReadAllText($ignore) -ceq "my own rules`n#include .stignore-remoteagents`n") 'existing user rules are preserved and include appended after a missing newline'
    foreach($folder in @($default,$explicit)){
        Assert ($folder.fsWatcherDelayS -eq 2) 'new folders detect filesystem changes after two seconds'
        Assert ($folder.maxConflicts -eq -1 -and $folder.versioning.type -ceq 'staggered' -and $folder.versioning.params.maxAge -ceq '0' -and $folder.versioning.params.cleanInterval -ceq '3600') 'new folders retain all conflicts and staggered versions forever'
        Assert ([IO.File]::ReadAllText((Join-Path $folder.path '.stignore-remoteagents')) -ceq [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'stignore.txt')).Replace("`r",'')) 'accepted default and external folders receive the managed ignore template'
    }
    $keep=@($data.folders|Where-Object {$_.id -ceq 'Keep'})[0]
    Assert ($keep.path -ceq $keepPath -and $keep.type -ceq 'receiveonly' -and $keep.paused -and $keep.maxConflicts -eq 17) 'existing folder path and options are preserved'
    Assert ($keep.fsWatcherDelayS -eq 2 -and $data.patches -eq 2 -and $data.defaults.fsWatcherDelayS -eq 2 -and $data.defaults.rescanIntervalS -eq 777 -and -not $data.defaults.fsWatcherEnabled) 'installation patches only watcher delay in existing folders and defaults'
    $snapshot=ConvertTo-Json -InputObject $data.folders -Depth 20 -Compress
    $null=Invoke-DiskFixture $bundle @('-AcceptFile',$accept)
    $null=Invoke-DiskFixture $bundle @()
    $data=[IO.File]::ReadAllText($api)|ConvertFrom-Json
    Assert ($data.writes -eq 2 -and $data.patches -eq 2 -and $data.polls -eq 2 -and (ConvertTo-Json -InputObject $data.folders -Depth 20 -Compress) -ceq $snapshot) 'repeated installation and missing AcceptFile perform no folder/default writes or pending polling'
    Assert ((Get-FileHash -LiteralPath $xml).Hash -ceq $before -and [IO.File]::ReadAllText($userFile) -ceq 'local data') 'installation preserves config.xml bytes and user files'
    Assert ([IO.File]::ReadAllText((Join-Path $script:DiskHome 'tray/syncthingtray.exe')) -ceq 'existing engine' -and [IO.File]::ReadAllText((Join-Path $script:DiskHome 'tray/syncthingtray.ini')) -ceq 'existing tray settings') 'installed engine and Tray settings remain intact'
    $data.race=$true;Write-DiskUtf8 $api ($data|ConvertTo-Json -Depth 30)
    Write-DiskUtf8 $accept '{"folders":[{"id":"Race"}]}'
    $null=Invoke-DiskFixture $bundle @('-AcceptFile',$accept)
    $data=[IO.File]::ReadAllText($api)|ConvertFrom-Json
    Assert ($data.writes -eq 2 -and @($data.folders|Where-Object {$_.id -ceq 'Race'})[0].type -ceq 'receiveonly') 'acceptance in Tray during wait is preserved'
    $data.noOffer=$true;Write-DiskUtf8 $api ($data|ConvertTo-Json -Depth 30)
    Write-DiskUtf8 $accept '{"folders":[{"id":"Fallback"}]}'
    $watch=[Diagnostics.Stopwatch]::StartNew();$fallbackOutput=Invoke-DiskFixture $bundle @('-AcceptFile',$accept)
    $data=[IO.File]::ReadAllText($api)|ConvertFrom-Json
    Assert ($watch.Elapsed.TotalSeconds -ge 29 -and $watch.Elapsed.TotalSeconds -lt 40 -and @($data.folders|Where-Object {$_.id -ceq 'Fallback'}).Count -eq 1) 'without a server offer the same ID is created after about 30 seconds'
    Assert ($fallbackOutput.Contains('Сервер не предложил папку Fallback') -and [IO.File]::ReadAllText((Join-Path $script:DiskHome 'install.log')).Contains('Сервер не предложил папку Fallback')) 'missing offer is reported in output and journal'
    # Laptop update: all four accepted folders have opaque server IDs and custom paths/options.
    $data.noOffer=$false;$data.race=$false;$data.folders=@();$laptop=@()
    foreach($n in 1..4){
        $name='Проект '+$n;$id='disk-'+($n.ToString('x24'));$path=Join-Path $TestHome ('Laptop/'+$n)
        $data.folders+=@(@{id=$id;label=$name;path=$path;devices=@(@{deviceID='PEER'});type='receiveonly';paused=$true;maxConflicts=17})
        $laptop+=@(@{id=$name})
    }
    Write-DiskUtf8 $api ($data|ConvertTo-Json -Depth 30);$patches=$data.patches
    $expected=ConvertFrom-Json (ConvertTo-Json -InputObject $data.folders -Depth 30)
    foreach($folder in $expected){$folder|Add-Member -Force fsWatcherDelayS 2}
    $snapshot=ConvertTo-Json -InputObject @($expected) -Depth 30 -Compress
    Write-DiskUtf8 $accept (@{folders=$laptop}|ConvertTo-Json -Depth 10)
    $null=Invoke-DiskFixture $bundle @('-AcceptFile',$accept)
    $data=[IO.File]::ReadAllText($api)|ConvertFrom-Json
    Assert ($data.patches -eq $patches+4 -and (ConvertTo-Json -InputObject $data.folders -Depth 30 -Compress) -ceq $snapshot -and (Get-FileHash -LiteralPath $xml).Hash -ceq $before) 'four existing disk-hex folders retain every setting except the two-second watcher delay'
    $snapshot=[IO.File]::ReadAllText($api);$null=Invoke-DiskFixture $bundle @()
    Assert ([IO.File]::ReadAllText($api) -ceq $snapshot) 'install without AcceptFile is idempotent after migrating accepted folders'
    $data.folders[0].fsWatcherDelayS=10;Write-DiskUtf8 $api ($data|ConvertTo-Json -Depth 30)
    $null=Invoke-DiskFixture $bundle @();$data=[IO.File]::ReadAllText($api)|ConvertFrom-Json
    Assert ($data.folders[0].fsWatcherDelayS -eq 2 -and $data.patches -eq $patches+5) 'install without AcceptFile also migrates a previously accepted folder'
    Assert (Test-DiskFolderAccepted @{id='Other name';path=$data.folders[0].path} $data.folders 'PEER') 'the same path is already accepted regardless of ID'
    Assert (-not (Test-DiskFolderAccepted @{id='Проект 1';path=(Join-Path $base 'Elsewhere')} $data.folders 'OTHER')) 'label match requires the server device'
    $pending=[pscustomobject]@{'disk-abcdefabcdefabcdefabcdef'=[pscustomobject]@{offeredBy=[pscustomobject]@{PEER=[pscustomobject]@{label='Русское имя'}}}}
    Assert ((Get-DiskPendingFolderId $pending 'Русское имя' 'PEER') -ceq 'disk-abcdefabcdefabcdefabcdef') 'pending REST object is searched by server label'
    Assert (-not (Get-DiskPendingFolderId $pending 'Русское имя' 'OTHER')) 'pending label from another device is ignored'
    $migration=Join-Path $script:DiskHome 'legacy-cleanup-v1';[IO.File]::Delete($migration)
    $broken=Join-Path $script:DiskHome 'cleanup-broken';Write-DiskUtf8 $broken '1'
    Add-DiskFixtureCode $bundle @'
function Remove-DiskLegacy {
    [IO.File]::AppendAllText((Join-Path $script:DiskHome 'cleanup-attempts'),'1')
    if(Test-Path -LiteralPath (Join-Path $script:DiskHome 'cleanup-broken')){throw 'Тест: оформление занято'}
}
'@
    $output=Invoke-DiskFixture $bundle @()
    Assert ($output.Contains('установка продолжается') -and -not (Test-Path -LiteralPath $migration)) 'automatic cleanup failure does not fail installation or save the migration flag'
    Assert ([IO.File]::ReadAllText((Join-Path $script:DiskHome 'install.log')).Contains('Тест: оформление занято')) 'automatic cleanup failure is logged'
    Assert (Refuses {Invoke-DiskFixture $bundle @('-CleanupLegacy')}) 'explicit CleanupLegacy propagates cleanup errors'
    Assert (Refuses {Invoke-DiskFixture $bundle @('-Uninstall')}) 'explicit Uninstall propagates cleanup errors'
    [IO.File]::Delete($broken);$null=Invoke-DiskFixture $bundle @();$null=Invoke-DiskFixture $bundle @()
    Assert ((Test-Path -LiteralPath $migration) -and [IO.File]::ReadAllText((Join-Path $script:DiskHome 'cleanup-attempts')) -ceq '1111') 'successful retry saves the flag and later installation skips cleanup'
    foreach($bad in @('{"folders":{}}','{"folders":[{"id":"../escape"}]}','{"folders":[{"id":"A"},{"id":"a"}]}','{"folders":[{"id":"A","path":"relative"}]}','{"folders":[{"id":"A","path":0}]}','{}','{"folders":[{"id":"A\n"}]}','{"folders":[{"id":"A","path":"\\\\?\\C:\\folder"}]}','{"folders":[{"id":"A","path":"\\\\.\\C:\\folder"}]}')){
        Write-DiskUtf8 $accept $bad;Assert (Refuses {Read-DiskAcceptFile $accept}) 'invalid AcceptFile rejected before accepting folders'
    }
    foreach($path in @($base,$env:USERPROFILE,[IO.Path]::GetPathRoot($base))){
        Write-DiskUtf8 $accept (@{folders=@(@{id='Root';path=$path})}|ConvertTo-Json -Depth 10)
        Assert (Refuses {Read-DiskAcceptFile $accept}) 'Disk root and its parents are refused'
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
    $ignoreFolder=Join-Path $TestHome 'Ignore CRLF';[void][IO.Directory]::CreateDirectory($ignoreFolder)
    $ignoreFile=Join-Path $ignoreFolder '.stignore';$original="Правила пользователя`r`n*.mine`r`n"
    [IO.File]::WriteAllText($ignoreFile,$original,(New-Object Text.UTF8Encoding($true)))
    $originalBytes=[IO.File]::ReadAllBytes($ignoreFile)
    Set-DiskFolderIgnores $ignoreFolder;$once=[IO.File]::ReadAllBytes($ignoreFile);Set-DiskFolderIgnores $ignoreFolder
    Assert ([Convert]::ToBase64String($once,0,$originalBytes.Length) -ceq [Convert]::ToBase64String($originalBytes) -and [IO.File]::ReadAllText($ignoreFile) -ceq ($original+"#include .stignore-remoteagents`r`n")) 'CRLF user rules and UTF-8 BOM bytes are preserved'
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($ignoreFile)) -ceq [Convert]::ToBase64String($once)) 'ignore include is idempotent'
    $managed=Join-Path $ignoreFolder '.stignore-remoteagents';[IO.File]::Delete($managed)
    [void](New-Item -ItemType $kind -Path $managed -Target $custom)
    Assert (Refuses {Set-DiskFolderIgnores $ignoreFolder}) 'ignore template does not follow links'
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
