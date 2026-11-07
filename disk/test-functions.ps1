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
    $script:LocalKey='';$script:RemoteKey='';$script:Tray=$null;$script:Install=$null
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
    assert '-sS' in args
    print('synthetic token=hidden '+('x'*800),file=sys.stderr)
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
    $retryRows=@(Get-Content $script:LogFile | ForEach-Object {$_|ConvertFrom-Json} | Where-Object {$_.stage -eq 'engine.download.retry'})
    $stderrText=($retryRows[0].message -split ' stderr=',2)[1]
    Assert ($stderrText.Length -eq 500) 'curl stderr capped at 500 characters'
    'PASS curl: -sS, redacted stderr capped at 500 characters'
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

# Exercise the connection-attempt code used by the real UI timer with a ready engine.
. $PSScriptRoot/RemoteDisk.ps1 -LibraryOnly
$source=Get-Content -LiteralPath "$PSScriptRoot/RemoteDisk.ps1" -Raw
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$parseErrors)
$engineAst=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Step-DiskEngine'},$true)
Assert ($engineAst.Extent.Text -notmatch 'Start-Job|Receive-Job|Remove-Job|engine.jsonl') 'installation must run on main thread'
Assert ($source -match 'function Start-DiskLogWorker' -and $source -match 'Start-Job') 'delivery worker retained'
$begin=$source.IndexOf('            if($script:Tunnel -and $script:Tunnel.p.HasExited)')
$end=$source.IndexOf('            Update-DiskState',$begin)
$attemptText=$source.Substring($begin,$end-$begin)
foreach($stage in @('dns','dns.error','tcp','tcp.error')){
    Assert (([regex]::Matches($attemptText,"Write-DiskLog '"+[regex]::Escape($stage)+"'")).Count -eq 1) "single $stage record site per connection attempt"
}
Assert ($attemptText.IndexOf("Write-DiskLog 'dns'") -gt $attemptText.IndexOf('Step-DiskInitialization')) 'diagnostics after installation polling'
Assert ($attemptText.IndexOf("Write-DiskLog 'tcp'") -lt $attemptText.IndexOf('Start-DiskTunnel')) 'diagnostics before tunnel'
$attempt=[scriptblock]::Create($attemptText)
$temp=Join-Path ([IO.Path]::GetTempPath()) ('disk-reconnect-'+[guid]::NewGuid().ToString('N'))
$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
try {
    [void](New-Item -ItemType Directory -Path (Join-Path $temp 'bin') -Force)
    [IO.File]::WriteAllText((Join-Path $temp 'bin/syncthing.exe'),'synthetic')
    $listener.Start();$port=$listener.LocalEndpoint.Port
    $script:DiskHome=$temp;$script:LogFile=Join-Path $temp 'session.jsonl';$script:HostName='test'
    $script:Remote=$null;$script:RemoteInstall=$null;$script:Install=$null;$script:Tunnel=$null
    $script:LastStatus='Нет подключения';$script:Tray=$null;$script:Retry=[DateTime]::MinValue
    $script:Connection=[pscustomobject]@{serverAddress='localhost';arguments=@('-p',"$port",'localhost')}
    $script:Bootstraps=0;$script:LocalChecks=0;$script:Tunnels=0
    $script:BootstrapPolls=0
    function Start-DiskSsh($RemoteCommand,$InputText){
        Assert ($RemoteCommand -match ' bootstrap') 'only bootstrap transport on ready installation'
        $script:Bootstraps++
        @{p=[pscustomobject]@{HasExited=$true};out=[pscustomobject]@{IsCompleted=$true};err=[pscustomobject]@{IsCompleted=$true}}
    }
    function Complete-DiskSsh($Job,$Timeout){'{"apiKey":"fake","listen":1,"gui":2,"reverse":3}'}
    function Initialize-DiskLocal {$script:LocalChecks++;$script:LocalKey='local-fake'}
    function Get-DiskCurl {throw 'download must not start'}
    function Start-DiskTunnel {$script:Tunnels++;$script:Tunnel=@{p=[pscustomobject]@{HasExited=$false}}}
    function Connect-DiskDevices {}
    $Command='show';$Path=''
    for($n=0;$n -lt 2;$n++){
        $now=[DateTime]::UtcNow;& $attempt
        Assert ($script:Tunnels -eq $n) 'bootstrap begins asynchronously before tunnel'
        $now=[DateTime]::UtcNow;& $attempt
        Assert ($script:Tunnels -eq $n+1) 'tunnel starts after bootstrap completes'
        if($n -eq 0){
            $script:Tunnel.p.HasExited=$true
            $now=[DateTime]::UtcNow;& $attempt
            Assert ($null -eq $script:Remote -and $null -eq $script:Tunnel) 'tunnel exit clears remote bootstrap cache'
            $script:Retry=[DateTime]::MinValue
        }
    }
    Assert ($script:Bootstraps -eq 2 -and $script:LocalChecks -eq 2) 'bootstrap and local engine checked again after exit'
    Assert ($script:LastStatus -notmatch 'Установка' -and $null -eq $script:Install) 'ready engine has no installation status'
    $rows=@(Get-Content $script:LogFile | ForEach-Object {$_|ConvertFrom-Json})
    Assert (@($rows|Where-Object {$_.stage -like 'engine.download*'}).Count -eq 0) 'ready engine has no download journal'
    foreach($stage in @('dns','tcp')){Assert (@($rows|Where-Object {$_.stage -eq $stage}).Count -eq 2) "$stage once per connection attempt"}
    # The real initialize catch must invalidate bootstrap even before a tunnel exists.
    function Initialize-DiskLocal {throw 'synthetic local failure'}
    $script:Tunnel=$null;$script:Retry=[DateTime]::MinValue;$now=[DateTime]::UtcNow;& $attempt
    Assert ($null -eq $script:Remote) 'initialize error clears remote bootstrap cache'
    $script:Tray=[pscustomobject]@{Icon=$null;Text=''}
    function New-DiskIcon($State){Assert ($State -eq 'error') 'startup error icon';$null}
    Update-DiskState
    Assert ($script:LastStatus -eq 'Ошибка запуска: synthetic local failure') 'startup error visible'
    Assert ($script:Tray.Text -eq $script:LastStatus -and $script:Tray.Text.Length -le 63) 'startup error tooltip'
    $script:LastInitError=Protect-DiskText ('token=hidden '+('x'*100));Update-DiskState
    Assert ($script:Tray.Text.Length -eq 63 -and $script:LastStatus -notmatch 'hidden') 'tooltip truncated and secret redacted'
    $script:Tray=$null
    'PASS startup error: status retained by Update-DiskState, red icon, redaction, tooltip <=63'
    'PASS reconnect: ready engine checked twice, async bootstrap repeated after tunnel exit, no download/status; initialize error resets remote'
    'PASS network: dns/tcp once per attempt after initialization; main-thread installation, delivery worker retained'
}finally{
    $listener.Stop();Stop-DiskInstall
    Remove-Item -LiteralPath $temp -Recurse -Force
}

# A real small ZIP validates the hash -> extraction -> main-thread initialization path.
. $PSScriptRoot/RemoteDisk.ps1 -LibraryOnly
$temp=Join-Path ([IO.Path]::GetTempPath()) ('disk-extract-'+[guid]::NewGuid().ToString('N'))
try {
    $payload=Join-Path $temp 'payload/syncthing-windows-amd64-v2.1.7'
    [void](New-Item -ItemType Directory -Path $payload -Force)
    [IO.File]::WriteAllText((Join-Path $payload 'syncthing.exe'),'synthetic engine')
    $zip=Join-Path $temp 'fixture.zip'
    Compress-Archive -LiteralPath $payload -DestinationPath $zip
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fixture=[IO.Compression.ZipFile]::Open($zip,[IO.Compression.ZipArchiveMode]::Update)
    try {
        $evil=$fixture.CreateEntry('../escape.txt');$writer=New-Object IO.StreamWriter($evil.Open())
        try{$writer.Write('must not escape')}finally{$writer.Dispose()}
    }finally{$fixture.Dispose()}
    $part=Join-Path $temp 'syncthing.zip.part';Move-Item $zip $part
    $script:DiskHome=$temp;$script:LogFile=Join-Path $temp 'session.jsonl';$script:HostName='test'
    $script:Install=@{part=$part;size=[long](Get-Item $part).Length;hash=(Get-DiskFileSha256 $part);route='direct';job=$null;started=[DateTime]::UtcNow;progress=[DateTime]::UtcNow;bytes=0L}
    $script:Tray=$null;$script:RemoteInstall=$null;$script:LocalKey=''
    $script:MainThread=[Threading.Thread]::CurrentThread.ManagedThreadId
    function Initialize-DiskLocal {
        Assert ([Threading.Thread]::CurrentThread.ManagedThreadId -eq $script:MainThread) 'local initialization on main thread'
        Assert (Test-Path (Join-Path $script:DiskHome 'bin/syncthing.exe')) 'binary extracted before initialization'
        $script:LocalKey='exact-local-key'
    }
    $known=Join-Path $temp 'known.bin';[IO.File]::WriteAllBytes($known,[Text.Encoding]::ASCII.GetBytes('abc'))
    Assert ((Get-DiskFileSha256 $known) -ceq 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD') 'SHA256 known bytes'
    [IO.File]::WriteAllBytes($known,[byte[]]@())
    Assert ((Get-DiskFileSha256 $known) -ceq 'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855') 'SHA256 empty bytes'
    Assert (Step-DiskEngine) 'verified archive installed synchronously'
    $binary=Join-Path $temp 'bin/syncthing.exe'
    Assert ([IO.File]::ReadAllText($binary) -ceq 'synthetic engine') 'exact ZIP payload'
    Assert (-not (Test-Path (Join-Path $temp 'escape.txt'))) 'zip slip entry ignored'
    Assert (@(Get-ChildItem (Join-Path $temp 'bin') -File).Count -eq 1) 'only binary extracted'
    [IO.File]::WriteAllText($binary,'old engine')
    Expand-DiskEngineArchive (Join-Path $temp 'syncthing.zip') $binary
    Assert ([IO.File]::ReadAllText($binary) -ceq 'synthetic engine') 'existing binary replaced'
    $missing=Join-Path $temp 'missing.zip'
    $fixture=[IO.Compression.ZipFile]::Open($missing,[IO.Compression.ZipArchiveMode]::Create);$fixture.Dispose()
    $rejected=$false;try{Expand-DiskEngineArchive $missing $binary}catch{$rejected=$_.Exception.Message -match 'syncthing.exe'}
    Assert $rejected 'missing engine has clear error'
    $journal=Get-Content $script:LogFile -Raw
    Assert ($journal -match 'engine.hash.ok' -and $journal -match 'engine.extract.done') 'hash and extract success logged'
    'PASS SHA256: known bytes and empty file; ZIP: traversal ignored, only engine, replacement, missing entry, success journal'
    Assert ($script:LocalKey -ceq 'exact-local-key' -and $null -eq $script:Install) 'local key belongs to initializer; installation cleared'
    [IO.File]::WriteAllText($part,'partial')
    $script:Install=@{part=$part;job=$null}
    Stop-DiskInstall
    Assert ([IO.File]::ReadAllText($part) -ceq 'partial') 'stop preserves partial download'
    'PASS extraction: real ZIP, SHA verification, main-thread initializer/key, stop preserves .part'
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}


# Real Syncthing 2.1.7 generate fixture: no root folder, StrictMode 2.
. $PSScriptRoot/RemoteDisk.ps1 -LibraryOnly
$temp=Join-Path ([IO.Path]::GetTempPath()) ('disk-config-'+[guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Path $temp -Force)
    $script:LogFile=Join-Path $temp 'config.jsonl';$script:HostName='test'
    $script:LocalKey='';$script:RemoteKey=''
    $archive='/tmp/sync-eval.hGIBPT/syncthing-linux-amd64-v2.1.7.tar.gz'
    $configPath=Join-Path $temp 'config.xml'
    if(Test-Path -LiteralPath $archive){
        & tar -xzf $archive -C $temp
        Assert ($LASTEXITCODE -eq 0) 'fixture extraction'
        & (Join-Path $temp 'syncthing-linux-amd64-v2.1.7/syncthing') generate --home $temp --no-port-probing *> $null
        Assert ($LASTEXITCODE -eq 0) 'real syncthing generate'
        'PASS fixture: real syncthing 2.1.7 generate'
    } else {
        [IO.File]::WriteAllText($configPath,'<configuration version="37"><device id="fixture"/><gui enabled="true"><address>127.0.0.1:8384</address><apikey>fixture</apikey></gui><ldap/><options><listenAddress>default</listenAddress><globalAnnounceEnabled>true</globalAnnounceEnabled><localAnnounceEnabled>true</localAnnounceEnabled><relaysEnabled>true</relaysEnabled><natEnabled>true</natEnabled><startBrowser>true</startBrowser><crashReportingEnabled>true</crashReportingEnabled><autoUpgradeIntervalH>12</autoUpgradeIntervalH><urAccepted>0</urAccepted></options><defaults><folder/><device/></defaults></configuration>')
        'PASS fixture: fallback structure device, gui, ldap, options, defaults'
    }
    [xml]$xml=[IO.File]::ReadAllText($configPath)
    Assert ($xml.SelectNodes('/configuration/folder').Count -eq 0) 'generated config has no root folder'
    $unsafe=[IO.File]::ReadAllText($configPath)
    Set-DiskEngineConfig $configPath '22111' '22112' $true
    [xml]$xml=[IO.File]::ReadAllText($configPath)
    foreach($key in @('globalAnnounceEnabled','localAnnounceEnabled','relaysEnabled','natEnabled','startBrowser','crashReportingEnabled')){
        Assert ($xml.SelectSingleNode('/configuration/options/'+$key).InnerText -ceq 'false') "safe $key"
    }
    foreach($pair in @(@('autoUpgradeIntervalH','0'),@('urAccepted','-1'),@('listenAddress','tcp://127.0.0.1:22111'))){
        Assert ($xml.SelectSingleNode('/configuration/options/'+$pair[0]).InnerText -ceq $pair[1]) "safe $($pair[0])"
    }
    Assert ($xml.SelectSingleNode('/configuration/gui/address').InnerText -ceq '127.0.0.1:22112') 'safe GUI'
    # Inspect with whitespace preserved: the [xml] cast would hide this defect.
    $exact=New-Object Xml.XmlDocument;$exact.PreserveWhitespace=$true
    $exact.LoadXml([IO.File]::ReadAllText($configPath))
    foreach($password in $exact.SelectNodes('//encryptionPassword')){
        Assert ($password.InnerText -ceq '') 'generated encryptionPassword strictly empty'
    }
    if(Test-Path -LiteralPath $archive){
        & (Join-Path $temp 'syncthing-linux-amd64-v2.1.7/syncthing') generate --home $temp --no-port-probing *> $null
        Assert ($LASTEXITCODE -eq 0) 'real Syncthing parses saved config without starting'
    }
    # Both defaults and existing folders must be repaired on ordinary runs.
    $exact.LoadXml([IO.File]::ReadAllText($configPath))
    $folder=$exact.CreateElement('folder');[void]$exact.DocumentElement.AppendChild($folder)
    $defaults=$exact.SelectSingleNode('/configuration/defaults/folder')
    foreach($parent in @($folder,$defaults)){
        $password=$exact.CreateElement('encryptionPassword');$password.SetAttribute('test','keep')
        $password.InnerText="`n        ";[void]$parent.AppendChild($password)
    }
    $real=$exact.CreateElement('encryptionPassword');$real.InnerText='abc';[void]$folder.AppendChild($real)
    foreach($name in @('emptyLeaf','spaceLeaf','valueLeaf')){
        $leaf=$exact.CreateElement($name);$leaf.InnerText="`n        "
        if($name -eq 'spaceLeaf'){$leaf.InnerText='   '}
        if($name -eq 'valueLeaf'){$leaf.SetAttribute('value','keep')}
        [void]$folder.AppendChild($leaf)
    }
    $exact.Save($configPath)
    Set-DiskEngineConfig $configPath '22111' '22112' $false
    $exact.LoadXml([IO.File]::ReadAllText($configPath))
    foreach($password in $exact.SelectNodes('//encryptionPassword[@test]')){
        Assert ($password.InnerText -ceq '' -and $password.GetAttribute('test') -ceq 'keep') 'whitespace password repaired, attributes kept'
    }
    Assert ($exact.SelectSingleNode('//encryptionPassword[not(@test)]/text()[.="abc"]').Value -ceq 'abc') 'real password preserved'
    Assert ($exact.SelectSingleNode('//emptyLeaf').InnerText -ceq '') 'multiline whitespace leaf repaired'
    Assert ($exact.SelectSingleNode('//spaceLeaf').InnerText -ceq '   ') 'single line whitespace retained'
    Assert ($exact.SelectSingleNode('//valueLeaf').InnerText -ceq "`n        ") 'value attribute leaf retained'
    $repairBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath))
    $repairStamp=[IO.File]::GetLastWriteTimeUtc($configPath)
    Set-DiskEngineConfig $configPath '22111' '22112' $false
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -ceq $repairBytes) 'repair idempotent bytes'
    Assert ([IO.File]::GetLastWriteTimeUtc($configPath) -eq $repairStamp) 'repair idempotent timestamp'
    Assert ((Get-Content $script:LogFile -Raw) -match 'encryptionPassword') 'password repair key logged'
    # Restore the real generated fixture for the existing folder lifecycle tests.
    [void]$exact.DocumentElement.RemoveChild($exact.SelectSingleNode('/configuration/folder'))
    $exact.Save($configPath)
    [xml]$xml=[IO.File]::ReadAllText($configPath)
    'PASS empty config values: generated XML, Syncthing parse, folder/defaults repair, real password, attributes, idempotence'
    $marker=Join-Path $temp 'remote-disk-configured'
    Assert (Test-Path $marker) 'marker after successful save'
    $bytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath))
    $stamp=[IO.File]::GetLastWriteTimeUtc($configPath)
    Set-DiskEngineConfig $configPath '22111' '22112' $false
    Assert (([Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath))) -ceq $bytes) 'idempotent bytes'
    Assert ([IO.File]::GetLastWriteTimeUtc($configPath) -eq $stamp) 'idempotent timestamp'
    [void]$xml.DocumentElement.AppendChild($xml.CreateElement('folder'));$xml.Save($configPath)
    Set-DiskEngineConfig $configPath '22111' '22112' (-not (Test-Path $marker))
    [xml]$xml=[IO.File]::ReadAllText($configPath)
    Assert ($xml.SelectNodes('/configuration/folder').Count -eq 1) 'marked user folder preserved'
    Remove-Item $marker
    Set-DiskEngineConfig $configPath '22111' '22112' (-not (Test-Path $marker))
    [xml]$xml=[IO.File]::ReadAllText($configPath)
    Assert ($xml.SelectNodes('/configuration/folder').Count -eq 0) 'first setup removes folder'
    $option=$xml.SelectSingleNode('/configuration/options/startBrowser');[void]$option.ParentNode.RemoveChild($option);$xml.Save($configPath)
    Set-DiskEngineConfig $configPath '22111' '22112' $false
    [xml]$xml=[IO.File]::ReadAllText($configPath)
    Assert ($xml.SelectSingleNode('/configuration/options/startBrowser').InnerText -ceq 'false') 'missing option created'
    foreach($required in @('options','gui')){
        [xml]$broken=$unsafe;$node=$broken.SelectSingleNode('/configuration/'+$required);[void]$node.ParentNode.RemoveChild($node);$broken.Save($configPath)
        Remove-Item $marker -ErrorAction SilentlyContinue
        $before=[IO.File]::ReadAllText($configPath)
        $failed=$false;try{Set-DiskEngineConfig $configPath '22111' '22112' $true}catch{$failed=$_.Exception.Message -match 'configuration/options and configuration/gui'}
        Assert $failed "missing $required rejected"
        Assert (([IO.File]::ReadAllText($configPath)) -ceq $before) 'invalid config unchanged'
        Assert (-not (Test-Path $marker)) 'failure creates no marker'
    }
    $journal=Get-Content $script:LogFile -Raw
    Assert ($journal -match 'engine.config.applied' -and $journal -notmatch 'apikey') 'changed keys logged without apikey'
    'PASS safe config: existing unsafe XML, idempotent bytes/time, folder marker, missing option, missing options/gui rejected'
} finally {Remove-Item -LiteralPath $temp -Recurse -Force}

$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'RemoteDisk.ps1'),[ref]$tokens,[ref]$parseErrors)
Assert ($parseErrors.Count -eq 0) 'RemoteDisk parser errors'
$forbidden=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Get-FileHash','Expand-Archive','New-Guid','New-TemporaryFile','Format-Hex')},$true))
Assert ($forbidden.Count -eq 0) 'no optional PowerShell function calls'
$configFunction=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-DiskEngineConfig'},$true))[0]
Assert ($configFunction.Extent.Text -notmatch '\[xml\]\s*\$xml\s*=') 'no XML cast for saved document'
$testTokens=$null;$testErrors=$null
[void][Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$testTokens,[ref]$testErrors)
Assert ($testErrors.Count -eq 0) 'test-functions parser errors'
'PASS static command ban; Parser errors: 0'
$functions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|ForEach-Object {$_.Name})
$commands=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object {$_.GetCommandName()}|Where-Object {$_ -and $_ -notin $functions}|Sort-Object -Unique)
'Commands (excluding file functions): '+($commands -join ', ')

# Exercise actual tunnel argument construction using OpenSSH configuration output.
. $PSScriptRoot/RemoteDisk.ps1 -LibraryOnly
if(Get-Command ssh -ErrorAction SilentlyContinue){
    $temp=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory $temp)
    try {
        $script:LogFile=Join-Path $temp 'test.jsonl';$script:HostName='test'
        $script:Connection=[pscustomobject]@{sshExecutable=(Get-Command ssh).Source;arguments=@('-F','/dev/null','-o','cLeArAlLfOrWaRdInGs=YeS','example.invalid')}
        $job=Start-DiskSsh '' '' @('-G','-L','18080:localhost:80','-R','18081:localhost:81')
        $output=Complete-DiskSsh $job
        Assert ($output -match '(?m)^localforward ' -and $output -match '(?m)^remoteforward ') 'ssh -G retains both tunnel forwards'
        'PASS tunnel: actual ssh -G localforward and remoteforward'
    } finally {Remove-Item $temp -Recurse -Force}
} else {'SKIP tunnel ssh -G: ssh unavailable'}
