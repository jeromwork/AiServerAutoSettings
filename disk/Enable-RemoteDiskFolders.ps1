#requires -Version 5.1
[CmdletBinding()]
param([string]$BasePath,[switch]$Disable)
$ErrorActionPreference='Stop'
if($Disable){Unregister-ScheduledTask -TaskName RemoteDiskFolders -Confirm:$false -ErrorAction SilentlyContinue;return}
$app=Join-Path $env:LOCALAPPDATA 'RemoteDisk\app'
[void][IO.Directory]::CreateDirectory($app)
foreach($name in @('Disk.Common.ps1','Sync-RemoteDiskFolders.ps1','Move-RemoteDiskFolder.ps1','Enable-RemoteDiskFolders.ps1','stignore.txt','legacy-ignores.sha256')){
    $source=Join-Path $PSScriptRoot $name;$target=Join-Path $app $name
    if([IO.Path]::GetFullPath($source) -ine [IO.Path]::GetFullPath($target)){Copy-Item -LiteralPath $source -Destination $target -Force}
}
. (Join-Path $app 'Disk.Common.ps1')
$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk';if(-not $BasePath){$BasePath=Get-DiskBase}
$lock=[IO.File]::Open((Join-Path $script:DiskHome 'folders.lock'),'OpenOrCreate','ReadWrite','None')
try{Set-DiskBase $BasePath}finally{$lock.Dispose()}
$action=New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') -Argument ('--headless powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File '+(Quote-Disk (Join-Path $app 'Sync-RemoteDiskFolders.ps1')))
$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
$triggers=@((New-ScheduledTaskTrigger -AtLogOn -User $user),(New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)))
$settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName RemoteDiskFolders -Action $action -Trigger $triggers -Settings $settings -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName RemoteDiskFolders
