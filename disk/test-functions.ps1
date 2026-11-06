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
# No privilege change: a temporary runuser shim executes bash as the current user.
$temp=Join-Path ([IO.Path]::GetTempPath()) ('disk-command-'+[guid]::NewGuid().ToString('N'))
$oldPath=$env:PATH;$oldHome=$env:HOME
try {
    [void](New-Item -ItemType Directory -Path $temp)
    $shim=Join-Path $temp 'runuser'
    @'
#!/usr/bin/env bash
set -eu
[ "$1" = "-u" ] && [ "$2" = "fixture_user" ] && [ "$3" = "--" ]
shift 3
exec "$@"
'@ | Set-Content -LiteralPath $shim -Encoding utf8NoBOM
    & chmod +x $shim
    $env:PATH=$temp+[IO.Path]::PathSeparator+$oldPath;$env:HOME=$temp
    $payload='printf "%s\n" "a b" "single'+"'"+'quote" ''$HOME; $(touch injected)''; printf "%s\n" "$HOME"; cat'
    Assert ((Get-DiskServerCommand $payload $false '') -ceq $payload) 'ordinary login must stay unchanged'
    $built=Get-DiskServerCommand $payload $true 'fixture_user'
    Assert ($built.StartsWith("runuser -u 'fixture_user' -- bash -c '")) 'root wrapper'
    $actual=@('stdin value' | & bash -c $built)
    Assert ($LASTEXITCODE -eq 0) 'shim arguments'
    Assert (($actual -join "`n") -ceq (@('a b',"single'quote",'$HOME; $(touch injected)',$temp,'stdin value') -join "`n")) 'shell escaping, HOME and stdin'
    Assert (-not (Test-Path (Join-Path (Get-Location) 'injected'))) 'no injection'
    foreach($bad in @('','root','nobody','-option','bad.name','user name',"user'quote",'user"quote',"user`n",'user;id',('a'*33))){
        $rejected=$false
        try{Get-DiskServerCommand 'true' $true $bad}catch{$rejected=$true}
        Assert $rejected ('invalid server user: '+$bad)
    }
    'PASS server command: nonroot unchanged, root runuser shim, quoting, HOME, stdin, invalid users'
}finally{
    $env:PATH=$oldPath;$env:HOME=$oldHome
    Remove-Item -LiteralPath $temp -Recurse -Force
}
# Selection tests do not query a machine or open WinForms.
& {
    $script:SelectionStages=@();$script:SelectionSaved=$false
    function Write-DiskLog($Stage,$Message){$script:SelectionStages+=@($Stage)}
    function Save-DiskConfig {$script:SelectionSaved=$true}
    function Start-DiskSsh { 'synthetic job' }
    function Complete-DiskSsh { $script:CandidateJson }
    $script:Connection=[pscustomobject]@{login='root'}
    $script:Config=[pscustomobject]@{serverUser='config_user'}
    $script:CandidateJson='["config_user","argument_user"]'
    $ServerUser='argument_user'
    Select-DiskServerUser
    Assert ($script:EffectiveServerUser -eq 'argument_user') 'parameter precedence'
    $ServerUser=''
    $script:Config.serverUser='config_user'
    Select-DiskServerUser
    Assert ($script:EffectiveServerUser -eq 'config_user') 'config fallback'
    $script:Config=[pscustomobject]@{}
    $script:SelectionStages=@();$script:SelectionSaved=$false
    $script:CandidateJson='["single_user"]'
    Select-DiskServerUser
    Assert ($script:EffectiveServerUser -eq 'single_user' -and $script:SelectionSaved -and 'serverUser.auto' -in $script:SelectionStages) 'auto user logged and saved'
    $script:Config=[pscustomobject]@{};$script:CandidateJson='[]'
    $rejected=$false;try{Select-DiskServerUser}catch{$rejected=$_.Exception.Message -like '*нет обычного пользователя*'}
    Assert $rejected 'no user error'
    $script:Connection.login='regular_user';$ServerUser='bad user'
    Select-DiskServerUser
    Assert (-not $script:ServerLoginIsRoot) 'ordinary login ignores root-only setting'
    'PASS user selection: parameter, config, auto logging and persistence, empty list, ordinary login'
}
