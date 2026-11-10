#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][Alias('Home')][string]$LauncherHome,[string]$DiskHome=(Join-Path $env:LOCALAPPDATA 'RemoteDisk'),
      [switch]$Check,[switch]$Confirm,[string]$Observer,[switch]$DryRun,[string]$AdapterFile,
      [string]$ChannelTask='RemoteDiskChannel',[string]$RollbackTask='RemoteAgents rollback',
      [string]$DiskRun='RemoteDisk',[string]$ControlRun='RemoteAgentsControl',[string]$LauncherRun='RemoteAgents')
. (Join-Path $PSScriptRoot 'Migrate.Common.ps1')
$root=(Get-TransportHome $LauncherHome);$bundle=Split-Path $PSScriptRoot -Parent
$defaultHome=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'RemoteAgents'))
if(-not $DryRun -and -not $Check -and -not $Confirm -and -not $root.TrimEnd('\','/').Equals($defaultHome.TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)){throw 'Рабочий переход разрешён только в основном Home; для изолированной проверки используйте windows-migrate-dryrun.ps1'}
if($DryRun){
    foreach($name in @($ChannelTask,$RollbackTask,$DiskRun,$ControlRun,$LauncherRun)){if($name -notmatch '^RemoteAgents-Test-'){throw 'DryRun требует изолированные имена'}}
    if(-not [IO.Path]::GetFullPath($DiskHome).StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'DryRun требует DiskHome внутри Home'}
    if($AdapterFile){. ([IO.Path]::GetFullPath($AdapterFile))}
}elseif($AdapterFile){throw 'Подмена функций разрешена только DryRun'}
try{
    Invoke-MigrationLock $root {
        if($Check -or $Confirm){
            $stateFile=Get-MigrationStatePath $root
            if((Test-Path $stateFile) -and (Read-TransportJson $stateFile).dryRun -and -not $DryRun){return}
            Confirm-Migration $root -Explicit:$Confirm -Observer $Observer
        }else{
            $names=[pscustomobject]@{channelTask=$ChannelTask;rollbackTask=$RollbackTask;diskRun=$DiskRun;controlRun=$ControlRun;launcherRun=$LauncherRun}
            Invoke-MigrationTransition $root $bundle $DiskHome $names ([bool]$DryRun)
        }
    }
}catch{Write-MigrationLog $root 'command.failed';Write-Error 'Переход не выполнен; см. logs/migration.log (без секретов).';exit 1}
