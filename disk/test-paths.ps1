#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
if(-not $TestHome){$TestHome=Join-Path ([IO.Path]::GetTempPath()) ('disk-paths-'+[guid]::NewGuid().ToString('N'))}
[void][IO.Directory]::CreateDirectory($TestHome)
. (Join-Path $PSScriptRoot 'Disk.Common.ps1')
$count=0
function Assert($Value,[string]$Text){if(-not $Value){throw ('FAIL: '+$Text)};$script:count++}
function Refuses([scriptblock]$Action){try{& $Action|Out-Null;return $false}catch{return $true}}
foreach($pair in @(
    @('C:/Работа/Проект/','C:\Работа\Проект'),
    @('D:\','D:\'),
    @('\\server\share\Project','\\server\share\Project'),
    @('\\server\share\','\\server\share')
)){
    Assert ((ConvertTo-DiskAcceptWindowsPath $pair[0]) -ceq $pair[1]) ('valid Windows path: '+$pair[0])
}
foreach($path in @('a','relative','C:relative','\relative','\\server','\\?\C:\Folder','\\.\C:\Folder','//?/C:/Folder','C:\A\..\B','C:\A\.\B','C:\A\\B','C:\A.','C:\A ','C:\nul.txt','C:\x:y','C:\x?y',"C:\x`ny",'\\server\share\A\..\B','\\server\share\COM1')){
    Assert (Refuses {ConvertTo-DiskAcceptWindowsPath $path}) ('invalid Windows path: '+$path.Replace("`n",'<LF>'))
}
$oldUser=$env:USERPROFILE;$env:USERPROFILE=$TestHome;$script:DiskHome=Join-Path $TestHome 'RemoteDisk'
try{
    $base=Join-Path $TestHome 'Disk'
    foreach($path in @($base,$TestHome,[IO.Path]::GetPathRoot($base))){Assert (Refuses {Assert-DiskAcceptPath $path @()}) 'Disk root and parents are refused at runtime'}
    Assert (-not (Refuses {Assert-DiskAcceptPath (Join-Path $TestHome 'Disk-other') @()})) 'Disk root name prefix alone is not an overlap'
    $folder=@{id='disk-0123456789abcdef01234567';path=(Join-Path $base 'Accepted')}
    Assert (-not (Refuses {Assert-DiskAcceptPath $folder.path @($folder)})) 'the same existing path is allowed'
    Assert (Test-DiskFolderAccepted @{id='Different';path=$folder.path} @($folder) 'PEER') 'path equality makes acceptance a no-op'
}finally{$env:USERPROFILE=$oldUser}
Write-Output ('PASS: '+$count+' Windows path/root/equality checks (lexical Windows rules also exercised on Linux)')
