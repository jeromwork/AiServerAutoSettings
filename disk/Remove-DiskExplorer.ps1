#requires -Version 5.1
[CmdletBinding()]
param([string]$Base='')
. (Join-Path $PSScriptRoot 'Disk.Common.ps1')
$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'
try{Remove-DiskExplorer $Base;Write-DiskLog 'Оформление Disk в Проводнике удалено'}catch{Write-DiskLog 'Удаление оформления Disk в Проводнике' $_;throw}
