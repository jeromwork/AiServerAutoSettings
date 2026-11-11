#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][Alias('Home')][string]$LauncherHome,[string]$Session,[switch]$Uninstall,[switch]$Watchdog)
. (Join-Path $PSScriptRoot 'Migrate.Common.ps1')
try{
    if($Watchdog -and -not (Wait-MigrationDeadline $LauncherHome $Session)){return}
    Invoke-MigrationLock $LauncherHome {Invoke-MigrationRollback $LauncherHome $Session -Force:$Uninstall} -TimeoutMs 30000
    if($Uninstall){Remove-MigrationNavPane} # also without migration state (clean install)
}catch{Write-MigrationLog $LauncherHome 'rollback.failed';exit 1}
