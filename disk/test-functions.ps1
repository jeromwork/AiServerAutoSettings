param([string]$Export)
$ErrorActionPreference='Stop'
. $PSScriptRoot/RemoteDisk.ps1 -LibraryOnly
function Assert($Value,$Message){if(-not $Value){throw $Message}}
$script:LocalKey='synthetic-key';$script:RemoteKey='other-key'
Assert ((Protect-DiskText 'apiKey=abc token=xyz synthetic-key other-key') -eq 'apiKey=[redacted] token=[redacted] [redacted] [redacted]') 'redaction'
$db=[pscustomobject]@{state='idle';needTotalItems=0;pullErrors=0}
Assert ((Get-DiskStatus $false $false $db $false) -eq 'offline') 'offline must not be success'
Assert ((Get-DiskStatus $true $true $db $false) -eq 'paused') 'pause'
Assert ((Get-DiskStatus $true $false $db $true) -eq 'conflict') 'conflict'
Assert ((Get-DiskStatus $true $false $db $false) -eq 'synced') 'synced'
$db.needTotalItems=1;Assert ((Get-DiskStatus $true $false $db $false) -eq 'syncing') 'transfer'
$db.pullErrors=1;Assert ((Get-DiskStatus $true $false $db $false) -eq 'error') 'error'
Assert ((Get-DiskRelative '/tmp/root' '/tmp/root/child.txt') -eq 'child.txt') 'relative'
$rejected=$false;try{Get-DiskRelative '/tmp/root' '/tmp/root-other/file'}catch{$rejected=$true};Assert $rejected 'escape rejection'
Assert ((Quote-Native 'a b') -eq '"a b"') 'native quote'
$f=New-DiskFolder 'id' '/tmp/path' 'local' 'peer'
Assert ($f.paused -and $f.type -eq 'sendreceive' -and $f.versioning.params.keep -eq '2147483647' -and $f.versioning.params.cleanoutDays -eq '30') 'folder policy'
if($Export){@{folder=$f;ignores=@(Get-DiskIgnores)}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $Export -Encoding utf8}
'PASS pure functions: states, retention, redaction, path boundary, quoting'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('disk-functions-'+[guid]::NewGuid().ToString('N'))
try {
    $script:Queue=Join-Path $temp 'queue';$script:Sent=Join-Path $temp 'sent'
    [void](New-Item -ItemType Directory -Path $script:Queue,$script:Sent -Force)
    $script:LogFile=Join-Path $temp 'active.jsonl';$script:HostName='synthetic-host'
    $script:Upload=$null;$script:Connection=[pscustomobject]@{test=$true}
    Write-DiskLog 'start' 'apiKey=unsafe synthetic-key'
    function Start-DiskSsh($RemoteCommand,$InputText){
        $script:Captured=$InputText
        @{p=[pscustomobject]@{HasExited=$true};started=[DateTime]::UtcNow}
    }
    $script:FailUpload=$true
    function Complete-DiskSsh($Job,$Timeout){if($script:FailUpload){throw 'Synthetic offline'};''}
    Send-DiskLogs -First
    $captured=$script:Captured|ConvertFrom-Json
    Assert ($captured.stage -eq 'start' -and $captured.message -notmatch 'unsafe|synthetic-key') 'first log and redaction'
    $pending=$script:Pending
    Send-DiskLogs -DrainOnly
    Assert (Test-Path $pending) 'offline queue preserved without Syncthing'
    $script:FailUpload=$false
    Send-DiskLogs
    Send-DiskLogs -DrainOnly
    Assert (-not (Test-Path $pending)) 'acknowledged batch moved'
    Assert (@(Get-ChildItem $script:Sent).Count -eq 1) 'local journal retained'
    'PASS independent journal: first record, redaction, offline queue, retry and local retention'
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
# Remote commands retain LF line endings before they are passed to SSH.
$RemoteCommand="printf 'crlf-ok\n'`r`nprintf 'done\n'`r`n"
$normalized=Convert-DiskRemoteText $RemoteCommand
Assert ($normalized -notmatch "`r") 'RemoteCommand must not contain CR after normalization'
Assert ($normalized -ceq $RemoteCommand.Replace("`r`n","`n")) 'RemoteCommand must preserve content and LF'
$source=Get-Content -LiteralPath "$PSScriptRoot/RemoteDisk.ps1" -Raw
$codeWithoutLegacyComment=$source.Replace('# Legacy serverUser in config.json is ignored; commands use the SSH profile login.','')
Assert ($codeWithoutLegacyComment -notmatch '(?i)runuser|serverUser') 'removed user switching must not appear in RemoteDisk code'
'PASS SSH login policy: RemoteCommand CRLF normalization, no user switching or setting'
