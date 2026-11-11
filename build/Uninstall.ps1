#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][Alias('Home')][string]$LauncherHome)
. (Join-Path $PSScriptRoot 'Setup.Common.ps1')
# The tray and its Run value are removed by the launcher; user files and settings stay in place.
try{Remove-ExplorerNavPane;Write-SetupLog $LauncherHome 'uninstall.navpane.removed'}catch{Write-SetupLog $LauncherHome 'uninstall.failed';exit 1}
