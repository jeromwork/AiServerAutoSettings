#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
. (Join-Path $PSScriptRoot 'Vpn.Service.ps1')
$count=0
function Assert($Condition,[string]$Message){if(-not $Condition){throw ('Тест: '+$Message)};$script:count++}
$work=Join-Path ([IO.Path]::GetTempPath()) ('vpn-service-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$oldPf=$env:ProgramFiles;$oldWpf=$env:ProgramW6432;$oldSystem=$env:SystemRoot;$oldOs=$env:OS;$oldLegacy=$env:REMOTEAGENTS_VPN_LEGACY_UAC
try{
    $env:ProgramFiles=$work;$env:ProgramW6432=$work;$env:SystemRoot=$work
    $env:OS='Windows_NT';$env:REMOTEAGENTS_VPN_LEGACY_UAC=''
    Assert (Test-VpnServiceMode) 'основной режим Windows'
    $env:REMOTEAGENTS_VPN_LEGACY_UAC='1';Assert (-not (Test-VpnServiceMode)) 'явный legacy';$env:REMOTEAGENTS_VPN_LEGACY_UAC=''
    $env:OS='Linux';Assert (-not (Test-VpnServiceMode)) 'не Windows';$env:OS='Windows_NT'
    $info=Get-VpnServiceInfo;Assert ($info.Name -eq 'RemoteAgentsTun' -and $info.Pipe -eq 'RemoteAgentsTun' -and $info.Protocol -eq 1 -and $info.Directory -eq (Join-Path $work 'RemoteAgents/vpn')) 'имена службы'
    $script:bundle=Join-Path $PSScriptRoot 'sing-box.exe';$script:hash='8f30682ee198855440d2a7fe070d5d3653793b2d01bb8c85eea88f93bbe7c8b9'
    function Test-Path {param([string]$LiteralPath,[string]$Path) if(-not $LiteralPath){$LiteralPath=$Path};if($LiteralPath -eq $script:bundle){return $script:bundleExists};Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath}
    function Get-FileHash {param($LiteralPath,$Algorithm) Assert ($Algorithm -eq 'SHA256' -and $LiteralPath -eq $script:bundle) 'хэш бандла';[pscustomobject]@{Hash=$script:hash.ToUpperInvariant()}}
    function Get-VpnServiceOwnerSid { 'S-1-5-21-1-2-3-1001' }
    function Reset-Mocks {
        $script:bundleExists=$true;$script:installed=$true;$script:running=$true;$script:available=$true;$script:protocol=1;$script:serviceHash=$script:hash
        $script:errorCode='';$script:calls=New-Object Collections.ArrayList;$script:trace=New-Object Collections.ArrayList;$script:uac=New-Object Collections.ArrayList;$script:startService=0;$script:created=$null;$script:createResult=0
        $script:serviceState='off';$script:session='';$script:probeFails=$false;$script:rollback=$false;$script:rollbackAfterConfirm=$false;$script:cleanupFails=$false;$script:adapterCalls=0;$script:adapterAfter=1;$script:sleeps=0
        Remove-Item -LiteralPath (Join-Path $work 'state/vpn.stop') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $work 'stop') -Force -ErrorAction SilentlyContinue
        Write-TransportJson (Join-Path $work 'config.json') @{schema=1;version=1;vpn=@{enabled=$true};components=@{vpn=@{enabled=$true}}}
        Write-VpnStatus $work $false $true 'starting' @{conflict=$false;items=@()} 'test'
    }
    function Send-VpnServiceLine([string]$Line,[int]$TimeoutMs) {
        Assert ($Line -notmatch "[`r`n]") 'запрос одной строкой'
        $r=ConvertFrom-Json -InputObject $Line;[void]$script:calls.Add($r);[void]$script:trace.Add($r.command)
        if($script:errorCode){return (ConvertTo-Json -Compress @{ok=$false;protocol=1;error=$script:errorCode})}
        if(-not $script:available){throw 'not available'}
        switch($r.command){
            start {$script:session='0123456789abcdef0123456789abcdef';$script:serviceState='starting'}
            confirm {$script:serviceState='on'}
            stop {$script:serviceState='off';if($script:cleanupFails){$script:serviceState='cleanup-error'}}
        }
        $state=$script:serviceState;if(($script:rollback -or ($script:rollbackAfterConfirm -and $script:serviceState -eq 'on')) -and $r.command -eq 'status'){$state='rolled-back'}
        ConvertTo-Json -Compress @{ok=$true;protocol=$script:protocol;state=$state;session=$script:session;singBoxSha256=$script:serviceHash;interface='RemoteAgents-TUN';deadlineSec=300;reason=''}
    }
    function Start-Process {param($FilePath,$ArgumentList,$Verb,[switch]$Wait,[switch]$PassThru)
        [void]$script:uac.Add([pscustomobject]@{FilePath=$FilePath;ArgumentList=$ArgumentList;Verb=$Verb;Wait=$Wait;PassThru=$PassThru})
        $script:installed=$true;$script:running=$true;$script:available=$true;$script:protocol=1;$script:serviceHash=$script:hash
        [pscustomobject]@{ExitCode=0}
    }
    function Get-Service {param($Name,$ErrorAction) if(-not $script:installed){throw 'absent'};[pscustomobject]@{Status=$(if($script:running){'Running'}else{'Stopped'})}}
    function Start-Service {param($Name,$ErrorAction) $script:startService++;$script:running=$true;$script:available=$true}
    function Invoke-CimMethod {param($ClassName,$MethodName,$Arguments,$ErrorAction) $script:created=[pscustomobject]@{ClassName=$ClassName;MethodName=$MethodName;Arguments=$Arguments};[pscustomobject]@{ReturnValue=$script:createResult;ProcessId=555}}
    function Start-Sleep {param($Milliseconds,$Seconds) if($Seconds -eq 1){$script:sleeps++;if($script:sleeps -gt 3){throw 'test loop exceeded'};Write-TransportJson (Join-Path $work 'state/vpn.stop') @{stop=$true}}}
    [IO.File]::WriteAllText((Join-Path $work 'RemoteAgents.exe'),'launcher fixture')
    Reset-Mocks
    Assert ((Get-VpnServiceLauncher $work 0) -eq (Join-Path $work 'RemoteAgents.exe')) 'поиск лаунчера'
    $request=New-VpnServiceStartRequest @{log=@{disabled=$true}} 123
    Assert (($request.Keys|Sort-Object) -join ',' -eq 'command,config,protocol,watchPid') 'только четыре поля start'
    Assert ($request.watchPid -eq 123 -and $request.command -eq 'start') 'поля start'
    $answer=Invoke-VpnServiceRequest $request
    Assert ($answer.state -eq 'starting' -and $script:calls.Count -eq 1) 'обмен JSON'
    $script:errorCode='forbidden';$caught=$false
    try{Invoke-VpnServiceRequest @{protocol=1;command='status'}|Out-Null}catch{$caught=$_.Exception.Data['vpnServiceError'] -eq 'forbidden'}
    Assert $caught 'код отказа в Exception.Data'
    Reset-Mocks;Assert-VpnServiceReady $work 0 ''
    Assert ($script:uac.Count -eq 0 -and $script:startService -eq 0) 'готовая служба без UAC'
    Reset-Mocks;$script:bundleExists=$false;Assert-VpnServiceReady $work 0 ''
    Assert ($script:uac.Count -eq 0) 'готовая служба без бандла'
    Reset-Mocks;$script:installed=$false;$script:available=$false;Assert-VpnServiceReady $work 0 ''
    Assert ($script:uac.Count -eq 1) 'отсутствует: один UAC'
    $call=$script:uac[0]
    Assert ($call.Verb -eq 'RunAs' -and $call.Wait -and $call.PassThru -and $call.FilePath -eq (Join-Path $work 'RemoteAgents.exe')) 'повышается только установщик'
    foreach($arg in @('--vpn-service-install','--home','--owner-sid','--sing-box',$work,'S-1-5-21-1-2-3-1001',$script:bundle)){Assert ($call.ArgumentList.Contains($arg)) ('аргумент '+$arg)}
    Reset-Mocks;$script:serviceHash='bad';Assert-VpnServiceReady $work 0 '';Assert ($script:uac.Count -eq 1) 'смена бинарника: переустановка'
    Reset-Mocks;$script:protocol=2;Assert-VpnServiceReady $work 0 '';Assert ($script:uac.Count -eq 1) 'смена протокола: переустановка'
    Reset-Mocks;$script:running=$false;$script:available=$false;Assert-VpnServiceReady $work 0 '';Assert ($script:startService -eq 1 -and $script:uac.Count -eq 0) 'остановленная служба запускается без UAC'
    Reset-Mocks;$script:bundleExists=$false;$script:installed=$false;$script:available=$false;$caught=$false
    try{Assert-VpnServiceReady $work 0 ''}catch{$caught=$true};Assert ($caught -and $script:uac.Count -eq 0) 'без источника установка запрещена'
    Reset-Mocks
    Start-VpnServiceSession $work 123 (Join-Path $PSScriptRoot 'Vpn.Tun.ps1') ([pscustomobject]@{conflict=$true;items=@('warning')})
    Assert ($script:created.ClassName -eq 'Win32_Process' -and $script:created.MethodName -eq 'Create') 'worker через CIM вне job'
    Assert ($script:created.Arguments.CommandLine.Contains('-ServiceWorker') -and $script:created.Arguments.CommandLine.Contains((Join-Path $PSScriptRoot 'Vpn.Tun.ps1'))) 'команда worker'
    Assert ((Read-TransportJson (Join-Path $work 'config.json')).vpn.enabled -and (Read-TransportJson (Join-Path $work 'status/vpn.json')).state -eq 'starting' -and $script:uac.Count -eq 0) 'starting без UAC'
    Reset-Mocks;$script:createResult=5;$caught=$false
    try{Start-VpnServiceSession $work 0 (Join-Path $PSScriptRoot 'Vpn.Tun.ps1') @{}}catch{$caught=$true}
    Assert ($caught -and -not (Read-TransportJson (Join-Path $work 'config.json')).vpn.enabled) 'ошибка CIM сбрасывает enabled'
    function Read-TransportSettings([string]$Root) { [pscustomobject]@{Vpn=(Read-TransportJson (Join-Path $Root 'config.json')).vpn;Transport=@{bootstrap=$false};Options=@{};Profile=@{}} }
    function Get-VpnTransportState {param($Root,$Settings) [pscustomobject]@{active='reality-edge'}}
    function Get-TransportRevision {param($Root) 'revision'}
    function Get-VpnSnapshot { [pscustomobject]@{Adapters=@();Processes=@();Routes=@()} }
    function Find-VpnConflicts {param($Snapshot,$OwnProcessIds,$OwnInterface) [pscustomobject]@{conflict=$true;items=@('warning')} }
    function Get-TransportCandidates {param($Settings,$Root) @{}}
    function Get-TransportNetwork { @{interface='Ethernet'} }
    function Get-VpnExclusions {param($Settings,$Paths,$Snapshot,$Root) @()}
    $script:fixture=Read-TransportJson (Join-Path $PSScriptRoot '../app/launcher/tests/fixtures/vpn-tun-config.json')
    function New-VpnTunConfig {param($Settings,$Paths,$SelectedTag,$ExcludeCidrs,$Interface) $script:fixture}
    function Get-NetAdapter {param([switch]$IncludeHidden) $script:adapterCalls++;[void]$script:trace.Add('adapter');if($script:adapterCalls -ge $script:adapterAfter){[pscustomobject]@{Name='RemoteAgents-TUN';Status='Up';ifIndex=4}}}
    function Test-VpnThroughTun {param($Settings,$Adapter) [void]$script:trace.Add('probe');if($script:probeFails){throw 'probe failed'}}
    Reset-Mocks;$script:adapterAfter=2
    Invoke-VpnServiceWorker $work 0
    $commands=@($script:calls|ForEach-Object {$_.command})
    Assert (($commands|Where-Object {$_ -in @('start','confirm','stop')}) -join ',' -eq 'start,confirm,stop') 'start → проверка → confirm → stop'
    Assert ($script:trace.IndexOf('probe') -gt $script:trace.IndexOf('adapter') -and $script:trace.IndexOf('confirm') -gt $script:trace.IndexOf('probe')) 'проверка предшествует confirm'
    Assert ($script:adapterCalls -eq 2 -and $commands -contains 'status') 'ожидание адаптера и честный status'
    $status=Read-TransportJson (Join-Path $work 'status/vpn.json')
    Assert ($status.state -eq 'off' -and -not $status.enabled -and -not (Read-TransportJson (Join-Path $work 'config.json')).vpn.enabled) 'vpn.stop завершает worker'
    Assert ($script:uac.Count -eq 0) 'worker не повышает права при чужом VPN'
    Reset-Mocks;$script:probeFails=$true;$caught=$false
    try{Invoke-VpnServiceWorker $work 0}catch{$caught=$_.Exception.Message -eq 'probe failed'}
    $commands=@($script:calls|ForEach-Object {$_.command})
    Assert ($caught -and $commands -notcontains 'confirm' -and $commands -contains 'stop') 'ошибка пробы: нет confirm, stop и исключение'
    Assert ((Read-TransportJson (Join-Path $work 'status/vpn.json')).state -ne 'off') 'ошибку не затирает off'
    Reset-Mocks;$script:rollback=$true;$caught=$false
    try{Invoke-VpnServiceWorker $work 0}catch{$caught=$_.Exception.Message -eq 'TUN службы остановлен'}
    Assert ($caught -and @($script:calls|Where-Object {$_.command -eq 'stop'}).Count -eq 1) 'rolled-back: исключение и stop'
    Reset-Mocks;$script:rollbackAfterConfirm=$true;$caught=$false
    try{Invoke-VpnServiceWorker $work 0}catch{$caught=$_.Exception.Message -eq 'TUN службы остановлен'}
    Assert ($caught -and @($script:calls|Where-Object {$_.command -eq 'confirm'}).Count -eq 1 -and @($script:calls|Where-Object {$_.command -eq 'stop'}).Count -eq 1) 'откат после confirm не выдаётся за on'
    Reset-Mocks;$script:cleanupFails=$true;Invoke-VpnServiceWorker $work 0
    Assert ((Read-TransportJson (Join-Path $work 'status/vpn.json')).state -eq 'rollback-error') 'остаток интерфейса не выдаётся за off'
    foreach($file in @('Vpn.Tun.ps1','Vpn.Service.ps1')){
        $path=Join-Path $PSScriptRoot $file;$bytes=[IO.File]::ReadAllBytes($path)
        Assert ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ($file+' UTF-8 BOM')
        $text=[Text.Encoding]::UTF8.GetString($bytes);Assert ($text.Contains("`r`n") -and $text -notmatch '(?<!\r)\n') ($file+' CRLF')
        $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        Assert ($errors.Count -eq 0) ($file+' parse')
    }
    Write-Output ('OK: '+$count+' проверок службы VPN без сети')
}finally{
    $env:ProgramFiles=$oldPf;$env:ProgramW6432=$oldWpf;$env:SystemRoot=$oldSystem;$env:OS=$oldOs;$env:REMOTEAGENTS_VPN_LEGACY_UAC=$oldLegacy
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
