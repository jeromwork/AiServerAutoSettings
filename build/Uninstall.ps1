#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][Alias('Home')][string]$LauncherHome)
. (Join-Path $PSScriptRoot 'Setup.Common.ps1')
# The tray and its Run value are removed by the launcher; user files and settings stay in place.
# C# Uninstall.Run performs LegacyDiskMigration before this helper.
Write-SetupLog $LauncherHome 'uninstall.complete'
