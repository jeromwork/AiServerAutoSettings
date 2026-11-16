#requires -Version 5.1
$ErrorActionPreference='Stop'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('disk-fast-'+[guid]::NewGuid().ToString('N'))
try {
    . (Join-Path $PSScriptRoot 'Disk.Common.ps1')
    if((Get-DiskMilliseconds TIMING_TEST 123) -ne 123){throw 'Duration default changed'}
    $env:REMOTE_DISK_TIMING_TEST_MS='7'
    if((Get-DiskMilliseconds TIMING_TEST 123) -ne 7){throw 'Duration override ignored'}
    $env:REMOTE_DISK_TIMING_TEST_MS='NaN';$failed=$false
    try{Get-DiskMilliseconds TIMING_TEST 123|Out-Null}catch{$failed=$true}
    if(-not $failed){throw 'Invalid duration accepted'}
    $ini=New-DiskIni 'tray.exe' 'state' '127.0.0.1:8384' 'fixture'
    if(-not $ini.Contains('connections\1\reconnectInterval=30')){throw 'Tray reconnect default changed'}
    $env:REMOTE_DISK_TRAY_RECONNECT_MS='7000'
    if(-not (New-DiskIni 'tray.exe' 'state' '127.0.0.1:8384' 'fixture').Contains('connections\1\reconnectInterval=7')){throw 'Tray reconnect override ignored'}
    foreach($file in @('Disk.Common.ps1','Disk.Binary.ps1','Disk.Engine.ps1','Disk.NavPane.ps1','Install-RemoteDisk.ps1')){
        $tokens=$null;$errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file),[ref]$tokens,[ref]$errors)
        if($errors.Count){throw ($errors|Out-String)}
    }
    & {
        . (Join-Path $PSScriptRoot 'Disk.Engine.ps1')
        $env:REMOTE_DISK_ENGINE_POLL_MS='30000'
        $script:now=0.0
        function Get-DiskNowMilliseconds {$script:now}
        function Start-Sleep {param($Milliseconds) $script:now+=$Milliseconds}
        function Invoke-DiskApi {throw 'offline fixture'}
        $failed=$false
        try{Wait-DiskEngineReady|Out-Null}catch{$failed=$true}
        if(-not $failed -or $script:now -ne 30000){throw 'Engine readiness did not use virtual time/default budget'}
    }
    # Each script executes in a child scope, with fake REST and a virtual clock.
    $env:REMOTE_DISK_OFFER_POLL_MS='30000'
    & (Join-Path $PSScriptRoot 'test-accept.ps1') -TestHome (Join-Path $temp 'accept')
} finally {
    Remove-Item Env:REMOTE_DISK_TIMING_TEST_MS -ErrorAction SilentlyContinue
    Remove-Item Env:REMOTE_DISK_ENGINE_POLL_MS -ErrorAction SilentlyContinue
    Remove-Item Env:REMOTE_DISK_OFFER_POLL_MS -ErrorAction SilentlyContinue
    Remove-Item Env:REMOTE_DISK_TRAY_RECONNECT_MS -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}
