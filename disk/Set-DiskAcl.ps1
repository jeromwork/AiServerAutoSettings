#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$FolderPath,[Parameter(Mandatory=$true)][string]$RecordPath,[ValidateSet('lock','unlock')][string]$Mode)
Set-StrictMode -Version 2;$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'DiskLock.ps1')
$mutex=$null;$held=$false;$payload=$RecordPath+'.acl';$process=$null
try{
    $mutex=New-Object Threading.Mutex($false,('Local\RemoteDiskAcl-'+[IO.Path]::GetFileNameWithoutExtension($RecordPath)))
    try{$held=$mutex.WaitOne()}catch [Threading.AbandonedMutexException]{$held=$true}
    $FolderPath=[IO.Path]::GetFullPath($FolderPath).TrimEnd('\')
    if($FolderPath -match '[\r\n]'){throw 'Newlines in ACL path are not supported'}
    if((Get-Item -LiteralPath $FolderPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'ACL root is a reparse point'}
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $raw=Read-DiskRawAcl $FolderPath;$record=Read-DiskJson $RecordPath
    if($record -and ($record.path -cne $FolderPath -or $record.sid -ne $sid)){throw 'ACL recovery record does not match path/user'}
    if(-not $record -and $Mode -eq 'lock'){
        $record=[pscustomobject]@{path=$FolderPath;sid=$sid;baseline=(Get-DiskOwnAceCount $raw $sid);before=$raw.GetSddlForm('Access')}
        # Durable intent BEFORE mutation: retry after a kill neither duplicates nor loses the deny.
        Write-DiskJson $RecordPath $record
    }
    if($record){
        $count=Get-DiskOwnAceCount $raw $sid
        if($Mode -eq 'lock' -and $count -lt $record.baseline){throw 'Preexisting deny changed; use unlock to reconcile before retrying'}
        if($Mode -eq 'lock' -and $count -le $record.baseline){
            $ace=New-Object Security.AccessControl.CommonAce([Security.AccessControl.AceFlags]3,[Security.AccessControl.AceQualifier]::AccessDenied,65878,(New-Object Security.Principal.SecurityIdentifier($sid)),$false,$null)
            $raw.DiscretionaryAcl.InsertAce(0,$ace)
        }
        if($Mode -eq 'unlock' -and $count -gt $record.baseline){
            for($i=0;$i -lt $raw.DiscretionaryAcl.Count;$i++){if(Test-DiskOwnAce $raw.DiscretionaryAcl[$i] $sid){$raw.DiscretionaryAcl.RemoveAce($i);break}}
        }
        $expected=$raw.GetSddlForm('Access')
        # icacls /deny would remove allow bits; /remove:d would delete unrelated denies.
        # /restore applies the CURRENT DACL with precisely one managed ACE added/removed.
        [IO.File]::WriteAllText($payload,([IO.Path]::GetFileName($FolderPath)+"`r`n"+$expected+"`r`n"),[Text.Encoding]::Unicode)
        $job=Start-DiskIcaclsProcess $FolderPath $payload;$process=$job.p
        while(-not $process.WaitForExit(100)){} # Worker only; UI/controller keep running.
        if($process.ExitCode -ne 0){throw ('icacls exit '+$process.ExitCode)}
        if((Read-DiskRawAcl $FolderPath).GetSddlForm('Access') -cne $expected){throw 'ACL verification failed: DACL differs; other rights must be preserved'}
        # Audit inherited results in both directions; a partial unlock is not success.
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        $subjects=@($sid)+@($identity.Groups|ForEach-Object {$_.Value})
        $queue=New-Object 'System.Collections.Generic.Queue[string]';$queue.Enqueue($FolderPath)
        while($queue.Count){
            $dir=$queue.Dequeue();$parentRaw=Read-DiskRawAcl $dir
            foreach($child in @(Get-ChildItem -LiteralPath $dir -Force)){
                if($child.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'ACL cannot verify a reparse point'}
                $acl=Get-Acl -LiteralPath $child.FullName;$denied=$false
                foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
                    if($rule.IdentityReference.Value -eq $sid -and $rule.AccessControlType -eq 'Deny' -and ([int]$rule.FileSystemRights -band 65878) -eq 65878){$denied=$true}
                    if($Mode -eq 'lock' -and -not $rule.IsInherited -and $rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -in $subjects -and ([int]$rule.FileSystemRights -band 65878)){throw 'Child explicit allow bypasses inherited deny'}
                }
                if($Mode -eq 'lock' -and -not $denied){throw 'Child ACL did not inherit the write deny'}
                if($Mode -eq 'unlock'){
                    $expectedInherited=0;$remainingInherited=0
                    foreach($ace in $parentRaw.DiscretionaryAcl){
                        if($ace -is [Security.AccessControl.CommonAce] -and $ace.AceQualifier -eq 'AccessDenied' -and $ace.SecurityIdentifier.Value -eq $sid -and $ace.AccessMask -eq 65878 -and ([int]$ace.AceFlags -band 3)){$expectedInherited++}
                    }
                    foreach($ace in (Read-DiskRawAcl $child.FullName).DiscretionaryAcl){
                        if($ace -is [Security.AccessControl.CommonAce] -and $ace.AceQualifier -eq 'AccessDenied' -and $ace.SecurityIdentifier.Value -eq $sid -and $ace.AccessMask -eq 65878 -and ([int]$ace.AceFlags -band 16)){$remainingInherited++}
                    }
                    if($remainingInherited -gt $expectedInherited){throw 'Child retained an orphaned inherited deny after unlock'}
                }
                if($child.PSIsContainer){$queue.Enqueue($child.FullName)}
            }
        }
        if($Mode -eq 'unlock'){Remove-Item -LiteralPath $RecordPath -Force}
    }
    Write-DiskJson ($RecordPath+'.result') @{ok=$true;locked=($Mode -eq 'lock');error='';time=[DateTime]::UtcNow.ToString('o')}
    exit 0
}catch{
    Write-DiskJson ($RecordPath+'.result') @{ok=$false;locked=$null;error=$_.Exception.Message;time=[DateTime]::UtcNow.ToString('o')}
    exit 1
}finally{
    if($process){$process.Dispose()};Remove-Item -LiteralPath $payload -Force -ErrorAction SilentlyContinue
    if($held){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}
}
