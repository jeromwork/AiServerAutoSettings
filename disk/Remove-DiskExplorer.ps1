#requires -Version 5.1
[CmdletBinding()]
param([string]$Base='',[string]$DiskHome='',[switch]$KeepJunctions)
. (Join-Path $PSScriptRoot 'Disk.Common.ps1')
$script:DiskHome=$DiskHome;if(-not $script:DiskHome){$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'}
try{Remove-DiskExplorer $Base -KeepJunctions:$KeepJunctions;Write-DiskLog 'Оформление Disk в Проводнике удалено'}catch{Write-DiskLog 'Удаление оформления Disk в Проводнике' $_;throw}
