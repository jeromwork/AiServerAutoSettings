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

# Process shims exercise the actual polling and SSH transport, without Syncthing.
. $PSScriptRoot/RemoteDisk.ps1 -LibraryOnly
$temp=Join-Path ([IO.Path]::GetTempPath()) ('disk-engine-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temp -Force)
try {
    $script:DiskHome=$temp;$script:LogFile=Join-Path $temp 'engine.jsonl';$script:HostName='test'
    $script:LocalKey='';$script:RemoteKey='';$script:Tray=$null;$script:EngineReady=$false;$script:Install=$null
    $script:Remote=$null;$script:RemoteInstall=$null
    $shim=Join-Path $temp 'transport.py'
    $shimText=@'
#!/usr/bin/env python3
import sys,os,json,base64
from pathlib import Path
root=Path(__file__).parent
mode=(root/'mode').read_text().strip()
args=sys.argv[1:]
if '-o' in args and '-C' in args:
    p=Path(args[args.index('-o',args.index('-C'))+1])
    count=root/'curl-count'
    n=int(count.read_text())+1 if count.exists() else 1
    count.write_text(str(n))
    with (root/'curl-offsets').open('a') as f:f.write(str(p.stat().st_size if p.exists() else 0)+'\n')
    if mode=='resume':
        with p.open('ab') as f:f.write(b'abcd' if n==1 else b'efgh')
    print('synthetic token=hidden',file=sys.stderr)
    sys.exit(33 if n==2 and mode=='resume' else 18)
cmd=args[-1]
if ' bootstrap' in cmd:
    sys.stdin.read()
    with (root/'bootstrap-count').open('a') as f:f.write('1\n')
    print('{"apiKey":"fake","listen":1,"gui":2,"reverse":3}')
elif cmd.endswith('prepare'):
    print('{"size":8}\r')
else:
    offset,length=map(int,cmd.split()[-2:])
    with (root/'chunks').open('a') as f:f.write(str(offset)+'\n')
    failed=root/'chunk-failed'
    if not failed.exists():failed.touch();sys.exit(1)
    data=base64.b64encode(b'abcdefgh'[offset:offset+length]).decode()
    print(data[:4]+'\r\n'+data[4:]+'\r\n')
'@
    [IO.File]::WriteAllText($shim,$shimText.Replace("`r",''),(New-Object Text.UTF8Encoding($false)))
    & chmod +x $shim
    $script:Shim=$shim
    function Get-DiskCurl { $script:Shim }
    $script:Connection=[pscustomobject]@{sshExecutable=$shim;arguments=@('fake-profile-host')}
    function Tick-Until($Condition){
        for($n=0;$n -lt 300;$n++){
            if(& $Condition){return}
            [void](Step-DiskInitialization);Start-Sleep -Milliseconds 20
        }
        throw 'Engine polling timeout'
    }
    'resume'|Set-Content (Join-Path $temp 'mode')
    # Successful remote bootstrap is retained across every installation tick.
    for($n=0;$n -lt 100;$n++){if(Initialize-DiskRemote){break};Start-Sleep -Milliseconds 20}
    Assert ($null -ne $script:Remote) 'remote initialized'
    1..5|ForEach-Object {Assert (Initialize-DiskRemote) 'remote stays initialized'}
    Assert (@(Get-Content (Join-Path $temp 'bootstrap-count')).Count -eq 1) 'bootstrap called once'
    function Initialize-DiskRemote {throw 'Remote bootstrap repeated after success'}
    'resume'|Set-Content (Join-Path $temp 'mode')
    [void](Step-DiskInitialization)
    $script:Install.size=8L
    $sha=[Security.Cryptography.SHA256]::Create()
    $script:Install.hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes('abcdefgh')))).Replace('-','');$sha.Dispose()
    Tick-Until { (Get-DiskPartSize) -eq 8 -and -not $script:Install.job }
    Assert (Test-DiskEngineArchive) 'resumed archive hash'
    $offsets=@(Get-Content (Join-Path $temp 'curl-offsets'))
    Assert ($offsets.Count -eq 2 -and $offsets[0] -eq '0' -and $offsets[1] -eq '4') 'curl resumes existing partial file'
    'PASS engine direct: interrupted process resumed at byte 4; bootstrap once'
    Remove-Item $script:Install.part
    Remove-Item (Join-Path $temp 'curl-count'),(Join-Path $temp 'curl-offsets')
    'stall'|Set-Content (Join-Path $temp 'mode')
    $script:Install.failures=0;$script:Install.prepared=$false
    Tick-Until { $script:Install.route -eq 'server' }
    Assert (@(Get-Content (Join-Path $temp 'curl-offsets')).Count -eq 2) 'fallback after two stalled processes'
    Tick-Until { (Get-DiskPartSize) -eq 8 -and -not $script:Install.job }
    Assert (Test-DiskEngineArchive) 'CRLF base64 decoded with correct SHA'
    $offsets=@(Get-Content (Join-Path $temp 'chunks'))
    Assert ($offsets.Count -eq 2 -and $offsets[0] -eq '0' -and $offsets[1] -eq '0') 'failed chunk retries same offset'
    Assert ($script:LastStatus -match 'через сервер' -and $script:LastStatus.Length -le 63) 'honest installation status'
    $script:Install.hash='BAD'
    Assert (-not (Test-DiskEngineArchive)) 'bad SHA rejected'
    Assert (-not (Test-Path $script:Install.part)) 'bad SHA partial removed'
    [void](Step-DiskInitialization)
    Assert ($script:Install.offset -eq 0 -and $script:Install.job) 'restart from zero after bad SHA'
    $log=Get-Content $script:LogFile -Raw
    Assert ($log -match 'engine.hash.error' -and $log -notmatch 'token=hidden') 'hash error logged and secrets redacted'
    'PASS engine fallback: two stalls, SSH chunk retry at same offset, CRLF base64, bad SHA deletion, status'
}finally{
    Stop-DiskInstall
    Remove-Item -LiteralPath $temp -Recurse -Force
}
