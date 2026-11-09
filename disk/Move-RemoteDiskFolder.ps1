#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$FolderId,[Parameter(Mandatory=$true)][string]$Destination,[switch]$Copy)
. (Join-Path $PSScriptRoot 'Disk.Common.ps1')
$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk';$lock=$null
try {
    $lock=[IO.File]::Open((Join-Path $script:DiskHome 'folders.lock'),'OpenOrCreate','ReadWrite','None')
    Read-DiskState;Write-Output (Move-DiskFolder $FolderId $Destination -Copy:$Copy)
    Write-DiskLog ('Перенос: '+$FolderId)
}catch{Write-DiskLog 'Перенос папки' $_;Write-Error $_.Exception.Message;exit 1}finally{if($lock){$lock.Dispose()}}
