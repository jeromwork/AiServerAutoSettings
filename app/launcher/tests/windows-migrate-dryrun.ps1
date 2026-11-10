#requires -Version 5.1
[CmdletBinding()]
param([string]$TestHome,[string]$Exe,[string]$Bundle,[switch]$KeepTasksOnFailure)
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Запустите в Windows PowerShell 5.1'}
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
if(-not $TestHome){$TestHome=Join-Path $env:TEMP ('RemoteAgents-Test-'+[guid]::NewGuid().ToString('N'))}
$root=[IO.Path]::GetFullPath($TestHome)
if(Test-Path -LiteralPath $root){throw 'TestHome должен быть новым каталогом'}
[void][IO.Directory]::CreateDirectory($root)
# build/ may be excluded by RemoteDisk. Read the embedded resource without running EXE Main.
if($Exe){
    $assembly=[Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($Exe))
    $stream=$assembly.GetManifestResourceStream('RemoteAgents.InitialBundle.zip')
    if(-not $stream){throw 'В EXE нет начального бандла'}
    $Bundle=Join-Path $root 'extracted-bundle';[void][IO.Directory]::CreateDirectory($Bundle)
    Add-Type -AssemblyName System.IO.Compression
    $archive=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Read)
    try{
        foreach($entry in $archive.Entries){
            $target=[IO.Path]::GetFullPath((Join-Path $Bundle $entry.FullName))
            if(-not $target.StartsWith($Bundle+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Недопустимый путь бандла'}
            if($entry.FullName.EndsWith('/')){[void][IO.Directory]::CreateDirectory($target);continue}
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            $input=$entry.Open();$output=[IO.File]::Create($target)
            try{$input.CopyTo($output)}finally{$input.Dispose();$output.Dispose()}
        }
    }finally{$archive.Dispose();$stream.Dispose()}
}
if(-not $Bundle){$Bundle=$repo}
$bundleRoot=[IO.Path]::GetFullPath($Bundle)
if(-not (Test-Path -LiteralPath (Join-Path $bundleRoot 'build/Migrate.Common.ps1'))){throw 'Нужен новый бандл: укажите -Exe <RemoteAgents.exe> или -Bundle <каталог бандла>'}
. (Join-Path $bundleRoot 'build/Migrate.Common.ps1')
$prefix='RemoteAgents-Test-'+[guid]::NewGuid().ToString('N')
$names=[pscustomobject]@{channelTask=($prefix+'-Channel');rollbackTask=($prefix+'-Rollback');diskRun=($prefix+'-Disk');controlRun=($prefix+'-Control');launcherRun=($prefix+'-Launcher')}
# Read only the presence/values for invariant checks; never print their contents.
$realBefore=@{};foreach($key in @('RemoteDisk','RemoteAgentsControl','RemoteAgents')){$realBefore[$key]=Get-MigrationRun $key}
$localBefore=$env:LOCALAPPDATA;$script:dryRoot=$root;$success=$false
try {
    $env:LOCALAPPDATA=Join-Path $root 'local';$disk=Join-Path $root 'RemoteDisk'
    [void][IO.Directory]::CreateDirectory((Join-Path $disk 'channel'))
    $ssh=Join-Path $root 'ssh-config';$original="Host example.invalid`r`n    User test`r`n    Port 22`r`n"
    [IO.File]::WriteAllText($ssh,$original,(New-Object Text.UTF8Encoding($false)))
    $profile=Join-Path $root 'ssh-transport.json'
    Write-TransportJson $profile @{serverAddress='example.invalid';login='test';configPath=$ssh;sshExecutable='unused';keyPath='unused';knownHostsPath='unused'}
    [IO.File]::WriteAllText((Join-Path $disk 'profile.txt'),($profile+"`r`n"))
    # Choose free non-production ports. No connection to real server or shared localhost services.
    $ports=@();$sockets=@()
    try{for($i=0;$i -lt 5;$i++){$s=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$s.Start();$sockets+=,$s;$ports+=([int]$s.LocalEndpoint.Port)}}finally{foreach($s in $sockets){$s.Stop()}}
    if(@($ports|Where-Object {$_ -in @(22,2222,22001,29090,26000,28000)}).Count){throw 'Порт пересекается с рабочим'}
    Write-TransportJson (Join-Path $disk 'channel/config.json') @{inbounds=@(@{tag='ssh';listen_port=$ports[0];override_port=22},@{tag='sync';listen_port=$ports[1];override_port=22000})}
    Write-TransportJson (Join-Path $root 'config.json') @{foreign=@{keep='yes'};transport=@{sshPort=$ports[0];apiPort=$ports[2]}}
    # Genuine, harmless registry values and task. No real application is registered or launched.
    Set-MigrationRun $names.diskRun 'cmd.exe /c exit 0';Set-MigrationRun $names.controlRun 'cmd.exe /c exit 0'
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -NonInteractive -Command Start-Sleep -Seconds 120'
    $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $names.channelTask -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries) -Force|Out-Null
    Start-ScheduledTask -TaskName $names.channelTask
    Start-Sleep -Seconds 2
    # These are the only mocked platform operations. Scheduler and HKCU adapters stay real.
    function Invoke-MigrationPreflight($Root,$Bundle,$Config){
        if($Root -ne $script:dryRoot){throw 'Isolation mismatch'}
        $probe=Join-Path $Root 'state/migration-probe';$copy=Copy-TransportObject $Config
        $copy.transport.sshPort=$ports[3];$copy.transport.syncPort=$ports[4];Write-TransportJson (Join-Path $probe 'config.json') $copy
        Write-MigrationLog $Root 'dryrun.synthetic-preflight'
    }
    function Stop-MigrationLauncher($Root){if($Root -ne $script:dryRoot){throw 'Isolation mismatch'}}
    function Start-MigrationDetached($Exe,$Arguments){
        if($Exe -ne (Join-Path $script:dryRoot 'RemoteAgents.exe')){throw 'Isolation mismatch'}
        foreach($name in @('transport','disk','control')){Write-TransportJson (Join-Path $script:dryRoot ('status/'+$name+'.json')) @{ok=$true;connected=$true;summary='DRY RUN: synthetic';updatedAt=[DateTime]::UtcNow.ToString('o')}}
    }
    function Test-MigrationSsh($Root,$Port){if($Root -ne $script:dryRoot -or $Port -in @(22,2222,22001)){throw 'Isolation mismatch'};$true}
    function Test-MigrationBridge($Root){if($Root -ne $script:dryRoot){throw 'Isolation mismatch'};$true}
    function Start-MigrationControl($Root,$Bundle,$State){Set-MigrationRun $State.names.controlRun 'cmd.exe /c exit 0'}
    function Stop-MigrationControl($Root){if($Root -ne $script:dryRoot){throw 'Isolation mismatch'}}
    Write-Host 'DRY RUN: сетевые доказательства синтетические; Run и ScheduledTasks настоящие, изолированные.'
    Invoke-MigrationTransition $root $bundleRoot $disk $names $true
    $state=Read-TransportJson (Get-MigrationStatePath $root)
    if($state.phase -ne 'pending' -or -not (Get-MigrationTask $names.rollbackTask).exists -or (Get-MigrationTask $names.channelTask).enabled){throw 'Переход/задача отката не подтверждены'}
    if(-not [IO.File]::ReadAllText($ssh).Contains('HostName 127.0.0.1')){throw 'Блок SSH отсутствует'}
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32/cmd.exe') -Destination (Join-Path $root 'RemoteAgents.exe')
    # Production Migrate.ps1 normally refuses automatic acceptance of synthetic dry-run state.
    Confirm-Migration $root -Explicit
    if((Read-TransportJson (Get-MigrationStatePath $root)).phase -ne 'accepted' -or (Get-MigrationTask $names.rollbackTask).exists){throw 'Подтверждение не сняло задачу'}
    Invoke-MigrationRollback $root -Force
    if([IO.File]::ReadAllText($ssh) -cne $original -or (Get-MigrationRun $names.diskRun) -ne 'cmd.exe /c exit 0' -or -not (Get-MigrationTask $names.channelTask).enabled){throw 'Откат не восстановил прежнее состояние'}
    # Repeat and let the REAL independent rollback task fire in a separate PS5.1 process.
    Invoke-MigrationTransition $root $bundleRoot $disk $names $true
    Stop-ScheduledTask -TaskName $names.rollbackTask
    $state=Read-TransportJson (Get-MigrationStatePath $root);$state.startedAt=[DateTime]::UtcNow.AddSeconds(-601).ToString('o');Write-TransportJson (Get-MigrationStatePath $root) $state
    Set-ScheduledTask -TaskName $names.rollbackTask -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5))|Out-Null
    $deadline=[DateTime]::UtcNow.AddSeconds(60)
    do{Start-Sleep -Seconds 1;$state=Read-TransportJson (Get-MigrationStatePath $root)}while($state.phase -ne 'rolled-back' -and [DateTime]::UtcNow -lt $deadline)
    if($state.phase -ne 'rolled-back'){throw 'Независимая задача не выполнила откат за 60 с'}
    if((Read-TransportJson (Join-Path $root 'config.json')).foreign.keep -ne 'yes'){throw 'Потеря чужого config'}
    foreach($key in $realBefore.Keys){if((Get-MigrationRun $key) -cne $realBefore[$key]){throw 'Рабочий Run изменился'}}
    $success=$true
    Write-TransportJson (Join-Path $root 'dryrun-result.json') @{ok=$true;syntheticNetwork=$true;realScheduler=$true;realRegistry=$true;home=$root;taskPrefix=$prefix}
    Write-Host ('PASS: импорт, слияние, переход, подтверждение, uninstall, независимый scheduled rollback. Результат: '+$root)
}finally{
    $env:LOCALAPPDATA=$localBefore
    if($success -or -not $KeepTasksOnFailure){
        foreach($name in @($names.rollbackTask,$names.channelTask,(Get-MigrationRecoveryTaskName $root ([pscustomobject]@{names=$names})))){Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue}
        foreach($key in @($names.diskRun,$names.controlRun,$names.launcherRun)){Set-MigrationRun $key $null}
    }
}
