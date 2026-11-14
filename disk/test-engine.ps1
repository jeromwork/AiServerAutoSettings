#requires -Version 5.1
param([string]$TestHome,[string]$Syncthing)
$ErrorActionPreference='Stop'
if(-not $TestHome){$TestHome=Join-Path ([IO.Path]::GetTempPath()) ('disk-engine-'+[guid]::NewGuid().ToString('N'))}
[void][IO.Directory]::CreateDirectory($TestHome)
. (Join-Path $PSScriptRoot 'Disk.Common.ps1')
. (Join-Path $PSScriptRoot 'Disk.Engine.ps1')
. (Join-Path $PSScriptRoot 'test-fixture.ps1')
$oldLocal=$env:LOCALAPPDATA;$oldUser=$env:USERPROFILE;$oldMonitored=$env:STMONITORED
$env:LOCALAPPDATA=Join-Path $TestHome 'local';$env:USERPROFILE=Join-Path $TestHome 'user'
$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'
$count=0;$children=@();$lease=$null
function Assert($Value,[string]$Label){if(-not $Value){throw ('FAIL: '+$Label)};$script:count++}
function Alive([int]$Id){try{$p=[Diagnostics.Process]::GetProcessById($Id);try{return -not $p.HasExited}finally{$p.Dispose()}}catch [ArgumentException]{return $false}}
function Wait-File([string]$File){$watch=[Diagnostics.Stopwatch]::StartNew();while(-not (Test-Path -LiteralPath $File)){if($watch.Elapsed.TotalSeconds -gt 15){throw ('No file: '+$File)};Start-Sleep -Milliseconds 25}}
function Start-Child([string]$File,$Arguments){
    $si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=(Get-Process -Id $PID).Path
    $si.Arguments=(@('-NoProfile','-NonInteractive','-File',$File)+@($Arguments)|ForEach-Object {Quote-Disk $_}) -join ' '
    $si.UseShellExecute=$false;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    $p=[Diagnostics.Process]::Start($si)
    return @{Process=$p;Out=$p.StandardOutput.ReadToEndAsync();Err=$p.StandardError.ReadToEndAsync()}
}
function Finish-Child($Child,[int]$Code=0){
    Assert ($Child.Process.WaitForExit(20000)) 'child finishes within its budget'
    Assert ($Child.Process.ExitCode -eq $Code) ('child exit '+$Child.Process.ExitCode+': '+$Child.Err.GetAwaiter().GetResult())
    return $Child.Out.GetAwaiter().GetResult()
}
try{
    $bundle=New-DiskInstallFixture $TestHome
    $state=Join-Path $script:DiskHome 'state';$tray=Join-Path $script:DiskHome 'tray/syncthingtray.exe'
    [void][IO.Directory]::CreateDirectory($state);[void][IO.Directory]::CreateDirectory((Split-Path $tray -Parent))
    Write-DiskUtf8 (Join-Path $state 'config.xml') '<configuration><gui><address>127.0.0.1:8384</address><apikey>fixture</apikey></gui><folder id="keep" path="untouched"/></configuration>'
    Write-DiskUtf8 (Join-Path $script:DiskHome 'server.txt') 'PEER'
    Write-DiskUtf8 (Join-Path $script:DiskHome 'legacy-cleanup-v1') '1'
    # A single real OS process; records the child-only environment before exec.
    $shell=@'
#!/bin/sh
printf '%s' "$STMONITORED" > "${0%/*}/monitored"
exec sleep 60
'@
    Write-DiskUtf8 $tray $shell
    & chmod +x $tray
    function Get-CimInstance {param($ClassName,$Filter,$ErrorAction)}
    $foreign=[Diagnostics.Process]::Start('sleep','60');$children+=@{Process=$foreign}
    Start-DiskHeadless;$owned=$script:DiskEngine;$ownedId=$owned.Id
    Start-DiskHeadless
    Assert ($script:DiskEngine.Id -eq $ownedId) 'repeated start reuses the same owned engine'
    Wait-File (Join-Path $script:DiskHome 'tray/monitored')
    Assert ([IO.File]::ReadAllText((Join-Path $script:DiskHome 'tray/monitored')) -ceq 'yes') 'temporary engine bypasses the Syncthing monitor'
    Assert ($env:STMONITORED -ceq $oldMonitored) 'monitor environment is not changed in the installer'
    Stop-DiskHeadless;Stop-DiskHeadless
    Assert (-not (Alive $ownedId) -and $null -eq $script:DiskEngine -and -not $foreign.HasExited) 'only our pinned process is stopped; cleanup is idempotent'
    Start-DiskHeadless;$ownedId=$script:DiskEngine.Id;$script:DiskEngine.Kill();$script:DiskEngine.WaitForExit()
    Stop-DiskHeadless
    Assert (-not (Alive $ownedId) -and -not $foreign.HasExited) 'already exited owned process cannot target a replacement or borrowed engine'

    # Exact installer children; only the REST and Windows inventory boundaries are fixtures.
    $mock=@'
function Get-CimInstance {param($ClassName,$Filter,$ErrorAction)}
function Invoke-DiskApi($Route,$Method='GET',$Body=$null){
    if($Method -ceq 'GET' -and $Route -ceq 'config/defaults/folder'){return @{fsWatcherDelayS=2}}
    if($Method -ceq 'GET' -and $Route -ceq 'config/folders'){return}
    if($Route -cne 'system/status'){throw ('Unexpected REST: '+$Route)}
    $borrow=Join-Path $script:DiskHome 'borrow'
    if(Test-Path -LiteralPath $borrow){return @{myID='LOCAL'}}
    if(-not $script:DiskEngine -or $script:DiskEngine.HasExited){throw 'Not running yet'}
    Write-DiskUtf8 (Join-Path $script:DiskHome 'owned-pid') ([string]$script:DiskEngine.Id)
    return @{myID='LOCAL'}
}
function Set-DiskServerDevice {
    Write-DiskUtf8 (Join-Path $script:DiskHome 'ready') '1'
    if(Test-Path -LiteralPath (Join-Path $script:DiskHome 'fail')){throw 'Тест: приём не выполнен'}
    if(Test-Path -LiteralPath (Join-Path $script:DiskHome 'gate')){
        $watch=[Diagnostics.Stopwatch]::StartNew()
        while(-not (Test-Path -LiteralPath (Join-Path $script:DiskHome 'release'))){if($watch.Elapsed.TotalSeconds -gt 15){throw 'gate timeout'};Start-Sleep -Milliseconds 25}
    }
}
function Ensure-DiskNavPane {$true}
function Sync-DiskServerAddress {}
function Start-DiskComponent($StartupLease){
    $file=Join-Path $script:DiskHome 'owned-pid'
    if(Test-Path -LiteralPath $file){
        $id=[int][IO.File]::ReadAllText($file)
        try{$p=[Diagnostics.Process]::GetProcessById($id);if(-not $p.HasExited){throw 'Temporary engine still running at Tray startup'}}catch [ArgumentException]{}
    }
    Write-DiskUtf8 (Join-Path $script:DiskHome 'tray-started') '1'
    return 0
}
'@
    Add-DiskFixtureCode $bundle $mock
    $ini=Join-Path $script:DiskHome 'tray/syncthingtray.ini';Write-DiskUtf8 $ini 'user settings'
    $config=Join-Path $state 'config.xml';$before=(Get-FileHash -LiteralPath $config).Hash
    $output=Invoke-DiskFixture $bundle @()
    $ownedId=[int][IO.File]::ReadAllText((Join-Path $script:DiskHome 'owned-pid'))
    Assert (-not (Alive $ownedId) -and $output.Contains('RemoteDisk установлен')) 'successful installation leaves no temporary engine'
    Assert ((Get-FileHash -LiteralPath $config).Hash -ceq $before -and [IO.File]::ReadAllText($ini) -ceq 'user settings') 'engine cleanup preserves accepted folders and user configuration'
    Write-DiskUtf8 (Join-Path $script:DiskHome 'fail') '1'
    $failed=$false;try{Invoke-DiskFixture $bundle @()}catch{$failed=$true}
    $ownedId=[int][IO.File]::ReadAllText((Join-Path $script:DiskHome 'owned-pid'))
    Assert ($failed -and -not (Alive $ownedId)) 'failed installation also stops its own engine'
    Assert ([IO.File]::ReadAllText((Join-Path $script:DiskHome 'install.log')).Contains('Тест: приём не выполнен')) 'original installation failure is preserved in the journal'
    Write-DiskUtf8 (Join-Path $script:DiskHome 'borrow') '1'
    $failed=$false;try{Invoke-DiskFixture $bundle @()}catch{$failed=$true}
    Assert ($failed -and -not $foreign.HasExited) 'failure while borrowing REST does not stop a foreign engine'
    Remove-Item -LiteralPath (Join-Path $script:DiskHome 'fail')
    $null=Invoke-DiskFixture $bundle @()
    Assert (-not $foreign.HasExited) 'successful installation does not stop a borrowed Tray engine'
    Remove-Item -LiteralPath (Join-Path $script:DiskHome 'borrow'),(Join-Path $script:DiskHome 'ready')

    # A cleanup failure must not be reported as a completed installation.
    $brokenBundle=New-DiskInstallFixture (Join-Path $TestHome 'cleanup-failure')
    Add-DiskFixtureCode $brokenBundle $mock
    $stopFailure=@'
$script:OriginalStopDiskHeadless=${function:Stop-DiskHeadless}
function Stop-DiskHeadless {& $script:OriginalStopDiskHeadless;throw 'Тест: ошибка остановки'}
'@
    [IO.File]::AppendAllText((Join-Path $brokenBundle 'disk/Disk.Engine.ps1'),("`n"+$stopFailure),(New-Object Text.UTF8Encoding($false)))
    $child=Start-Child (Join-Path $brokenBundle 'disk/Install-RemoteDisk.ps1') @();$children+=$child
    $output=Finish-Child $child 1
    $ownedId=[int][IO.File]::ReadAllText((Join-Path $script:DiskHome 'owned-pid'))
    Assert (-not (Alive $ownedId) -and -not $output.Contains('RemoteDisk установлен') -and [IO.File]::ReadAllText((Join-Path $script:DiskHome 'install.log')).Contains('[Остановка временного движка]')) 'cleanup error returns failure without a false success message'
    Remove-Item -LiteralPath (Join-Path $script:DiskHome 'ready')

    # Hold the installer while the actual component entry point attempts startup.
    Write-DiskUtf8 (Join-Path $script:DiskHome 'gate') '1'
    $install=Start-Child (Join-Path $bundle 'disk/Install-RemoteDisk.ps1') @();$children+=$install
    Wait-File (Join-Path $script:DiskHome 'ready')
    $ownedId=[int][IO.File]::ReadAllText((Join-Path $script:DiskHome 'owned-pid'))
    $component=Start-Child (Join-Path $bundle 'disk/Disk.Engine.ps1') @('-StartEngine');$children+=$component
    Start-Sleep -Milliseconds 700
    Assert (-not (Test-Path -LiteralPath (Join-Path $script:DiskHome 'tray-started')) -and (Alive $ownedId) -and -not $component.Process.HasExited) 'component waits for the in-progress installer instead of starting a second engine'
    Write-DiskUtf8 (Join-Path $script:DiskHome 'release') '1'
    $null=Finish-Child $install;$null=Finish-Child $component
    Assert ((Test-Path -LiteralPath (Join-Path $script:DiskHome 'tray-started')) -and -not (Alive $ownedId)) 'headless component startup follows temporary engine exit'
    $lease=Enter-DiskEngineLock $script:DiskHome -TimeoutMilliseconds 100
    Exit-DiskEngineLock $lease;$lease=$null
    Assert $true 'installer and component both release the lifecycle mutex'

    # Upgrade inventory: previous orphan monitor + worker + GUI, plus a foreign state.
    $legacy=@();foreach($n in 1..5){$p=[Diagnostics.Process]::Start('sleep','60');$children+=@{Process=$p};$legacy+=@($p)}
    $rows=@();foreach($n in 0..4){
        $line=if($n -eq 0){(Quote-Disk $tray)}elseif($n -eq 4){(Quote-Disk $tray)+' --windowed --single-instance --trigger'}else{(Quote-Disk $tray)+' syncthing serve --home '+(Quote-Disk $(if($n -eq 3){Join-Path $TestHome 'foreign-state'}else{$state}))}
        $rows+=@{ProcessId=$legacy[$n].Id;ExecutablePath=$tray;CommandLine=$line;CreationDate='fixture'}
    }
    Write-DiskUtf8 (Join-Path $script:DiskHome 'inventory.json') (ConvertTo-Json -InputObject @($rows))
    Add-DiskFixtureCode $bundle @'
function Get-CimInstance($ClassName,$Filter,$ErrorAction){
    $rows=[IO.File]::ReadAllText((Join-Path $script:DiskHome 'inventory.json'))|ConvertFrom-Json
    foreach($row in $rows){
        if($Filter -and $Filter -cne ('ProcessId='+$row.ProcessId)){continue}
        try{$p=[Diagnostics.Process]::GetProcessById($row.ProcessId);try{if(-not $p.HasExited){$row}}finally{$p.Dispose()}}catch [ArgumentException]{}
    }
}
'@
    Remove-Item -LiteralPath (Join-Path $script:DiskHome 'tray-started')
    $component=Start-Child (Join-Path $bundle 'disk/Disk.Engine.ps1') @('-StartEngine');$children+=$component
    $null=Finish-Child $component
    Assert ($legacy[0].HasExited -and $legacy[1].HasExited -and $legacy[2].HasExited -and -not $legacy[3].HasExited -and -not $legacy[4].HasExited) 'upgrade removes old GUI and both orphan processes, preserving another state and engine-independent window'
    Assert (Test-Path -LiteralPath (Join-Path $script:DiskHome 'tray-started')) 'component starts the headless hook after the old engine is completely gone'
    Assert ((Get-FileHash -LiteralPath $config).Hash -ceq $before) 'upgrade preserves config.xml including accepted folders'

    # The production component hook owns a real worker, drops the lock after
    # readiness, stays alive until worker exit, then lets restart=always act.
    $managedBundle=New-DiskInstallFixture (Join-Path $TestHome 'managed-component')
    Add-DiskFixtureCode $managedBundle @'
function Get-CimInstance {param($ClassName,$Filter,$ErrorAction)}
function Sync-DiskServerAddress {}
function Wait-DiskEngineReady {
    Write-DiskUtf8 (Join-Path $script:DiskHome 'managed-pid') ([string]$script:DiskEngine.Id)
    return @{myID='LOCAL'}
}
'@
    $managed=Start-Child (Join-Path $managedBundle 'disk/Disk.Engine.ps1') @('-StartEngine');$children+=$managed
    Wait-File (Join-Path $script:DiskHome 'managed-pid')
    $managedId=[int][IO.File]::ReadAllText((Join-Path $script:DiskHome 'managed-pid'))
    $lease=Enter-DiskEngineLock $script:DiskHome -TimeoutMilliseconds 2000
    Exit-DiskEngineLock $lease;$lease=$null
    Assert ((Alive $managedId) -and -not $managed.Process.HasExited) 'headless component remains alive with its worker and releases mutex for installers'
    Stop-Process -Id $managedId -Force
    $null=Finish-Child $managed 137
    Assert (-not (Alive $managedId)) 'worker crash finishes the supervised component for restart'
    Remove-Item -LiteralPath (Join-Path $script:DiskHome 'managed-pid')
    $managed=Start-Child (Join-Path $managedBundle 'disk/Disk.Engine.ps1') @('-StartTray');$children+=$managed
    Wait-File (Join-Path $script:DiskHome 'managed-pid')
    $nextId=[int][IO.File]::ReadAllText((Join-Path $script:DiskHome 'managed-pid'))
    Assert ($nextId -ne $managedId -and (Alive $nextId)) 'legacy StartTray alias now launches a fresh headless worker'

    $oldIni="[tray]`r`nuserOption=keep`r`n[startup]`r`nsyncthingAutostart=true`r`nuseLibSyncthing=true`r`n"
    Write-DiskUtf8 $ini $oldIni;Set-DiskTrayExternalEngine
    $iniHash=(Get-FileHash -LiteralPath $ini).Hash;Set-DiskTrayExternalEngine
    $safeIni=[IO.File]::ReadAllText($ini)
    Assert ($safeIni.Contains('userOption=keep') -and $safeIni.Contains('syncthingAutostart=false') -and $safeIni.Contains('useLibSyncthing=false') -and (Get-FileHash -LiteralPath $ini).Hash -ceq $iniHash) 'CRLF legacy ini keeps user settings, disables engine launch and migrates idempotently'
    # Simulate only the GUI boundary. Actual CLI switches/ini were additionally
    # checked with release 2.1.9 on Linux; this fixture verifies our launch wiring.
    Write-DiskUtf8 $tray @'
#!/bin/sh
printf '%s\n' "$PWD" "$@" > "${0%/*}/window-arguments"
exit 37
'@
    & chmod +x $tray
    Assert ((Open-DiskSyncWindow) -eq 37) 'window exit code is separate from the engine component'
    $windowArgs=[IO.File]::ReadAllText((Join-Path $script:DiskHome 'tray/window-arguments')).Replace("`r",'')
    $windowIni=[IO.File]::ReadAllText((Join-Path $script:DiskHome 'tray/window/syncthingtray.ini'))
    Assert ($windowArgs -ceq ((Join-Path $script:DiskHome 'tray/window')+"`n--windowed`n--single-instance`n--trigger`n")) 'window uses isolated working directory and the three checked GUI switches'
    Assert ($windowIni.Contains('syncthingAutostart=false') -and $windowIni.Contains('useLibSyncthing=false') -and $windowIni.Contains('considerLauncherForReconnect=false') -and -not $windowArgs.Contains('fixture')) 'window config cannot auto-start a second engine; API key stays out of argv'
    Assert ((Alive $nextId) -and -not $managed.Process.HasExited) 'closing synchronization window leaves the headless worker running'
    Stop-Process -Id $nextId -Force;$null=Finish-Child $managed 137

    if($Syncthing){
        # Optional real Syncthing 2.1.7: same engine as Tray 2.1.9, no mocked REST.
        $real=Join-Path $TestHome 'real';$script:DiskHome=$real;$realState=Join-Path $real 'state'
        [void][IO.Directory]::CreateDirectory((Join-Path $real 'tray'))
        $null=Invoke-DiskProcess $Syncthing @('generate','--home',$realState)
        $socket=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$socket.Start();$port=$socket.LocalEndpoint.Port;$socket.Stop()
        Read-DiskState;$script:Engine.configuration.gui.address='127.0.0.1:'+$port
        foreach($folder in @($script:Engine.configuration.SelectNodes('folder'))){[void]$script:Engine.configuration.RemoveChild($folder)}
        Save-DiskState @{globalAnnounceEnabled=$false;localAnnounceEnabled=$false;relaysEnabled=$false;natEnabled=$false;listenAddresses=@('tcp://127.0.0.1:0');startBrowser=$false;autoUpgradeIntervalH=0}
        $realExe=Join-Path $real 'tray/syncthingtray.exe'
        Write-DiskUtf8 $realExe ('#!/bin/sh'+"`n"+'shift'+"`n"+"exec '"+$Syncthing.Replace("'",("'"+[char]34+"'"+[char]34+"'"))+"' "+[char]34+'$@'+[char]34+' > '+[char]34+'$(dirname "$0")/engine.log'+[char]34+' 2>&1'+"`n")
        & chmod +x $realExe
        Start-DiskHeadless;$realId=$script:DiskEngine.Id
        Read-DiskState;$status=Wait-DiskEngineReady
        Assert ($status.myID -and $script:DiskEngine.MainModule.FileName -ceq [IO.Path]::GetFullPath($Syncthing)) 'real Syncthing worker is running at the owned PID and serves REST'
        $procChildren='/proc/'+$realId+'/task/'+$realId+'/children'
        Assert ([IO.File]::ReadAllText($procChildren).Trim().Length -eq 0) 'real Syncthing has no orphanable child processes'
        Stop-DiskHeadless
        Assert (-not (Alive $realId)) 'real Syncthing exits on owned cleanup'
    }
    Write-Output ('PASS: '+$count+' engine lifecycle checks (real OS children and mutex; Windows inventory/Tray fixtures'+$(if($Syncthing){'; real Syncthing REST'})+')')
}finally{
    Stop-DiskHeadless;Exit-DiskEngineLock $lease
    foreach($child in $children){$p=$child.Process;try{if(-not $p.HasExited){$p.Kill();$p.WaitForExit()}}finally{$p.Dispose()}}
    $env:LOCALAPPDATA=$oldLocal;$env:USERPROFILE=$oldUser
}
