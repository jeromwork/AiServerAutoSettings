#requires -Version 5.1
[CmdletBinding()]
param([string]$Base='',[string]$DiskHome='',[string]$OutputFile='')
. (Join-Path $PSScriptRoot 'Disk.Common.ps1')
$script:DiskHome=$DiskHome;if(-not $script:DiskHome){$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'}
try{$confirmed=@(Ensure-DiskExplorerIgnores $Base -Proofs);if($OutputFile){Write-SelectionState $OutputFile (@{paths=@($confirmed|ForEach-Object {$_.path});proofs=@($confirmed)}|ConvertTo-Json -Depth 5 -Compress)}}catch{Write-DiskLog 'Подготовка исключений оформления Проводника' $_;throw}
