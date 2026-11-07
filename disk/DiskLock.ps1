#requires -Version 5.1
# ACL work is isolated from WinForms: inherited propagation can take minutes.
function Get-DiskSafetyPlan([string]$Event,[bool]$Tunnel,[bool]$LocalConnected,[bool]$RemoteConfirmed,[bool]$AclVerified,[bool]$AclFailed) {
    $lock=$Event -in @('start','Suspend','Resume','exit') -or -not ($Tunnel -and $LocalConnected -and $RemoteConfirmed)
    [pscustomobject]@{lock=$lock;pause=($lock -or -not $AclVerified -or $AclFailed);error=$AclFailed}
}
function Get-DiskLockRecord([string]$HomePath,$Folder) {
    if($Folder.id -notmatch '^[A-Za-z0-9_-]+$'){throw 'Invalid folder ID in ACL record'}
    Join-Path $HomePath ('locks/'+$Folder.id+'.json')
}
function Read-DiskJson([string]$File) {
    if(Test-Path -LiteralPath $File){
        $stream=New-Object IO.FileStream($File,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader=New-Object IO.StreamReader($stream)
        try{$value=ConvertFrom-Json -InputObject $reader.ReadToEnd();foreach($item in $value){$item}}finally{$reader.Dispose()}
    }
}
function Write-DiskJson([string]$File,$Value) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($File))
    $temp=$File+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 20 -Compress),(New-Object Text.UTF8Encoding($false)))
    if([IO.File]::Exists($File)){[IO.File]::Replace($temp,$File,[NullString]::Value)}else{[IO.File]::Move($temp,$File)}
}
function Read-DiskRawAcl([string]$FolderPath) {
    $item=Get-Item -LiteralPath $FolderPath -Force
    $acl=$item.GetAccessControl('Access')
    New-Object Security.AccessControl.RawSecurityDescriptor($acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access))
}
function Test-DiskOwnAce($Ace,[string]$Sid) {
    $Ace -is [Security.AccessControl.CommonAce] -and $Ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessDenied -and
        $Ace.SecurityIdentifier.Value -eq $Sid -and $Ace.AccessMask -eq 65878 -and [int]$Ace.AceFlags -eq 3
}
function Get-DiskOwnAceCount($Raw,[string]$Sid) {
    $count=0;foreach($ace in $Raw.DiscretionaryAcl){if(Test-DiskOwnAce $ace $Sid){$count++}};$count
}
function Get-DiskLockInfo([string]$HomePath,$Folder) {
    $locked=$null;$aclError=''
    try{
        $recordPath=Get-DiskLockRecord $HomePath $Folder;$record=Read-DiskJson $recordPath;$result=Read-DiskJson ($recordPath+'.result')
        if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){
            $locked=$false;if($record){$locked=(Get-DiskOwnAceCount (Read-DiskRawAcl $Folder.path) $record.sid) -gt $record.baseline}
        }
        if($result -and -not $result.ok){$aclError=$result.error;$locked=$null}
    }catch{$aclError=$_.Exception.Message;$locked=$null}
    [pscustomobject]@{locked=$locked;error=$aclError}
}
function Start-DiskAclProcess([string]$HomePath,$Folder,[bool]$Locked) {
    $record=Get-DiskLockRecord $HomePath $Folder;$mode='unlock';if($Locked){$mode='lock'}
    $si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=Join-Path $PSHOME 'powershell.exe'
    $si.Arguments=(@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Set-DiskAcl.ps1'),'-FolderPath',$Folder.path,'-RecordPath',$record,'-Mode',$mode)|ForEach-Object {'"'+([regex]::Replace([regex]::Replace($_,'(\\*)"','$1$1\"'),'(\\+)$','$1$1'))+'"'}) -join ' '
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true
    $p=New-Object Diagnostics.Process;$p.StartInfo=$si;[void]$p.Start();$p
}
function Request-DiskUnlock([string]$HomePath,$Folders) {
    foreach($folder in $Folders){Write-DiskJson ((Get-DiskLockRecord $HomePath $folder)+'.unlock') @{requested=[DateTime]::UtcNow.ToString('o')}}
}
function Get-DiskAclIdentity { [Security.Principal.WindowsIdentity]::GetCurrent() }
function Set-DiskDirectoryAcl([string]$FolderPath,[string]$Expected) {
    # Access-only DACL update uses the owner's WRITE_DAC, without restore privileges.
    $dir=New-Object IO.DirectoryInfo($FolderPath)
    $sec=New-Object Security.AccessControl.DirectorySecurity
    $sec.SetSecurityDescriptorSddlForm($Expected,'Access')
    $dir.SetAccessControl($sec)
}
function Test-DiskProcessStart([DateTime]$Actual,$Expected) {
    $Actual.ToUniversalTime().Ticks -eq ([DateTime]$Expected).ToUniversalTime().Ticks
}
