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
        $script:serviceState='off';$script:session='';$script:probeFails=$false;$script:rollback=$false;$script:rollbackAfterConfirm=$false;$script:cleanupFails=$false;$script:adapterCalls=0;$script:adapterAfter=1;$script:sleeps=0;$script:failStep='';$script:failCommand='';$script:uacExit=0;$script:clock=[DateTime]::UtcNow;$script:cycles=1;$script:checks=0;$script:cancelUac=$false;$script:failCheck=0
        Remove-Item -LiteralPath (Join-Path $work 'state/vpn.stop') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $work 'stop') -Force -ErrorAction SilentlyContinue
        Write-TransportJson (Join-Path $work 'config.json') @{schema=1;version=1;password='fixture-client-password';vpn=@{enabled=$true};components=@{vpn=@{enabled=$true}}}
        Write-VpnStatus $work $false $true 'starting' @{conflict=$false;items=@()} 'test'
    }
    function Send-VpnServiceLine([string]$Line,[int]$TimeoutMs) {
        Assert ($Line -notmatch "[`r`n]") 'запрос одной строкой'
        $r=ConvertFrom-Json -InputObject $Line;[void]$script:calls.Add($r);[void]$script:trace.Add($r.command)
        if($r.command -eq $script:failCommand){return (ConvertTo-Json -Compress @{ok=$false;protocol=1;error='config-rejected';reason='config-rejected';detail='check: fixture-client-password rejected'})}
        if($script:errorCode){return (ConvertTo-Json -Compress @{ok=$false;protocol=1;error=$script:errorCode})}
        if(-not $script:available){throw 'not available'}
        switch($r.command){
            start {$script:session='0123456789abcdef0123456789abcdef';$script:serviceState='starting'}
            confirm {$script:serviceState='on'}
            stop {$script:serviceState='off';if($script:cleanupFails){$script:serviceState='cleanup-error'}}
        }
        $state=$script:serviceState;if(($script:rollback -or ($script:rollbackAfterConfirm -and $script:serviceState -eq 'on')) -and $r.command -eq 'status'){$state='rolled-back'}
        ConvertTo-Json -Compress @{ok=$true;protocol=$script:protocol;state=$state;session=$script:session;singBoxSha256=$script:serviceHash;interface='RemoteAgents-TUN';deadlineSec=90;reason=$(if($state -eq 'rolled-back'){'lease-expired'}elseif($state -eq 'cleanup-error'){'cleanup-error'}else{''});detail='service detail fixture-client-password'}
    }
    function Start-Process {param($FilePath,$ArgumentList,$Verb,[switch]$Wait,[switch]$PassThru,$ErrorAction)
        [void]$script:uac.Add([pscustomobject]@{FilePath=$FilePath;ArgumentList=$ArgumentList;Verb=$Verb;Wait=$Wait;PassThru=$PassThru})
        $script:installed=$true;$script:running=$true;$script:available=$true;$script:protocol=1;$script:serviceHash=$script:hash
        if($script:cancelUac){throw (New-Object ComponentModel.Win32Exception(1223))}
        [pscustomobject]@{ExitCode=$script:uacExit}
    }
    function Get-Service {param($Name,$ErrorAction) if(-not $script:installed){throw 'absent'};[pscustomobject]@{Status=$(if($script:running){'Running'}else{'Stopped'})}}
    function Start-Service {param($Name,$ErrorAction) $script:startService++;if($script:failStep -eq 'service-start'){throw 'service failed fixture-client-password'};$script:running=$true;$script:available=$true}
    function Invoke-CimMethod {param($ClassName,$MethodName,$Arguments,$ErrorAction) $script:created=[pscustomobject]@{ClassName=$ClassName;MethodName=$MethodName;Arguments=$Arguments};[pscustomobject]@{ReturnValue=$script:createResult;ProcessId=555}}
    function Start-Sleep {param($Milliseconds,$Seconds) if($Seconds -eq 1){$script:sleeps++;if($script:sleeps -gt 5){throw 'test loop exceeded'};$script:clock=$script:clock.AddSeconds(31);if($script:sleeps -lt $script:cycles){return};Write-TransportJson (Join-Path $work 'state/vpn.stop') @{stop=$true}}}
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
    $result=Start-VpnServiceSession $work 123 (Join-Path $PSScriptRoot 'Vpn.Tun.ps1') ([pscustomobject]@{conflict=$true;items=@('warning')})
    Assert ($script:created.ClassName -eq 'Win32_Process' -and $script:created.MethodName -eq 'Create') 'worker через CIM вне job'
    Assert ($script:created.Arguments.CommandLine.Contains('-ServiceWorker') -and $script:created.Arguments.CommandLine.Contains((Join-Path $PSScriptRoot 'Vpn.Tun.ps1'))) 'команда worker'
    Assert ((Read-TransportJson (Join-Path $work 'config.json')).vpn.enabled -and (Read-TransportJson (Join-Path $work 'status/vpn.json')).state -eq 'starting' -and $script:uac.Count -eq 0) 'starting без UAC'
    Reset-Mocks;$script:createResult=5;$caught=$false
    $result=Start-VpnServiceSession $work 0 (Join-Path $PSScriptRoot 'Vpn.Tun.ps1') @{}
    Assert ($result -eq $false -and -not (Read-TransportJson (Join-Path $work 'config.json')).vpn.enabled) 'ошибка CIM сбрасывает enabled'
    function Read-TransportSettings([string]$Root) { [pscustomobject]@{Vpn=(Read-TransportJson (Join-Path $Root 'config.json')).vpn;Transport=@{bootstrap=$false};Options=@{};Profile=@{};password='fixture-client-password'} }
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
    function Get-VpnServiceUtcNow { $script:clock }
    $realProbe=(Get-Command Test-VpnServiceThroughTun).ScriptBlock
    function Test-VpnServiceThroughTun {param($Settings,$Adapter) [void]$script:trace.Add('probe');$script:checks++;if($script:checks -eq $script:failCheck){$script:failStep='dns'};if($script:probeFails){throw 'probe failed fixture-client-password'};[void](Test-VpnServiceChecks $Settings $Adapter)}
    function Assert-VpnTunRoute {param($Address,$InterfaceIndex) if($script:failStep -eq 'route-check'){throw 'route failed fixture-client-password'}}
    function Invoke-VpnServiceSshProbe {param($Settings,$v) if($script:failStep -eq 'ssh-probe'){throw 'ssh failed fixture-client-password'}}
    function Get-VpnServiceDnsAddresses {param($HostName) if($script:failStep -eq 'dns'){throw 'dns failed fixture-client-password'};[Net.IPAddress]::Parse('192.0.2.1')}
    function Invoke-VpnServiceHttpsRequest {param($Uri) if($script:failStep -eq 'https'){throw 'HTTP 503 fixture-client-password'}}
    Reset-Mocks;$script:adapterAfter=2
    $result=Invoke-VpnServiceWorker $work 0
    $commands=@($script:calls|ForEach-Object {$_.command})
    Assert (($commands|Where-Object {$_ -in @('start','confirm','stop')}) -join ',' -eq 'start,confirm,stop') 'start → проверка → confirm → stop'
    Assert ($script:trace.IndexOf('probe') -gt $script:trace.IndexOf('adapter') -and $script:trace.IndexOf('confirm') -gt $script:trace.IndexOf('probe')) 'проверка предшествует confirm'
    Assert ($script:adapterCalls -eq 2 -and $commands -contains 'status') 'ожидание адаптера и честный status'
    $status=Read-TransportJson (Join-Path $work 'status/vpn.json')
    Assert ($status.state -eq 'off' -and -not $status.enabled -and -not (Read-TransportJson (Join-Path $work 'config.json')).vpn.enabled) 'vpn.stop завершает worker'
    Assert ($script:uac.Count -eq 0) 'worker не повышает права при чужом VPN'
    function Assert-Failure([string]$Step,[string]$Reason='') {
        $status=Read-TransportJson (Join-Path $work 'status/vpn.json')
        Assert ($status.state -eq 'error' -and $status.step -eq $Step -and $status.summary.Contains('«'+$Step+'»') -and $status.detail) ('подробный статус '+$Step)
        Assert (($status.PSObject.Properties.Name|Sort-Object) -join ',' -eq 'conflict,detail,enabled,ok,reason,state,step,summary,updatedAt') ('все прежние поля '+$Step)
        if($Reason){Assert ($status.reason -eq $Reason) ('reason '+$Reason)}
        $log=[IO.File]::ReadAllText((Join-Path $work 'logs/vpn.log'));Assert ($log.Contains('error step='+$Step+' reason=')) ('vpn.log step '+$Step)
        $client=[IO.File]::ReadAllText((Join-Path $work 'logs/vpn-service-client.log'));Assert ($client.Contains('step='+$Step)) ('полный журнал '+$Step)
        Assert (-not ($client+$log+($status|ConvertTo-Json -Depth 20)).Contains('fixture-client-password')) ('секрет скрыт '+$Step)
    }
    Reset-Mocks;$script:probeFails=$true
    $result=Invoke-VpnServiceWorker $work 0
    $commands=@($script:calls|ForEach-Object {$_.command})
    Assert ($result -eq $false -and $commands -notcontains 'confirm' -and $commands -contains 'stop') 'ошибка пробы: false, без confirm, stop'
    Assert-Failure 'route-check'
    foreach($step in @('route-check','ssh-probe','dns','https')){
        Reset-Mocks;$script:failStep=$step
        $result=Invoke-VpnServiceWorker $work 0
        Assert ($result -eq $false) ('не бросает '+$step)
        Assert-Failure $step 'check-failed'
        if($step -eq 'https'){Assert ((Read-TransportJson (Join-Path $work 'status/vpn.json')).detail.Contains('503')) 'HTTP код 503'}
        Assert (@($script:calls|Where-Object {$_.command -eq 'confirm'}).Count -eq 0 -and @($script:calls|Where-Object {$_.command -eq 'stop'}).Count -eq 1) ('не продлевает при ошибке '+$step)
    }
    Reset-Mocks;$script:failCommand='start';$result=Invoke-VpnServiceWorker $work 0
    Assert ($result -eq $false) 'service-start false';Assert-Failure 'service-start' 'config-rejected'
    Reset-Mocks;$script:rollback=$true;$result=Invoke-VpnServiceWorker $work 0
    Assert ($result -eq $false -and @($script:calls|Where-Object {$_.command -eq 'stop'}).Count -eq 1) 'wait-interface false и stop'
    Assert-Failure 'wait-interface' 'lease-expired'
    Assert ((Read-TransportJson (Join-Path $work 'status/vpn.json')).detail.Contains('Ожидание')) 'время ожидания интерфейса'
    Reset-Mocks;$script:adapterAfter=100;$result=Invoke-VpnServiceWorker $work 0
    Assert ($result -eq $false) 'interface timeout false';Assert-Failure 'wait-interface' 'interface-timeout'
    Reset-Mocks;$script:rollbackAfterConfirm=$true;$result=Invoke-VpnServiceWorker $work 0
    Assert ($result -eq $false -and @($script:calls|Where-Object {$_.command -eq 'confirm'}).Count -eq 1 -and @($script:calls|Where-Object {$_.command -eq 'stop'}).Count -eq 1) 'service-stopped: false и stop'
    Assert-Failure 'service-stopped' 'lease-expired'
    Reset-Mocks;$script:cleanupFails=$true;$result=Invoke-VpnServiceWorker $work 0
    Assert ($result -eq $false) 'cleanup false';Assert-Failure 'service-stopped' 'cleanup-error'
    Reset-Mocks;$script:cycles=3;$result=Invoke-VpnServiceWorker $work 0
    Assert ($result -eq $true -and $script:checks -eq 3 -and @($script:calls|Where-Object {$_.command -eq 'confirm'}).Count -eq 3) 'каждая периодическая проверка продлевает аренду'
    $trace=@($script:trace|Where-Object {$_ -in @('probe','confirm')})
    Assert (($trace -join ',') -eq 'probe,confirm,probe,confirm,probe,confirm') 'confirm только после проверки'
    Reset-Mocks;$script:cycles=3;$script:failCheck=2;$result=Invoke-VpnServiceWorker $work 0
    Assert ($result -eq $false -and $script:checks -eq 2 -and @($script:calls|Where-Object {$_.command -eq 'confirm'}).Count -eq 1 -and @($script:calls|Where-Object {$_.command -eq 'stop'}).Count -eq 1) 'периодическая ошибка: аренда не продлена, stop'
    Assert-Failure 'dns' 'check-failed'
    Reset-Mocks;$script:failCommand='confirm';$result=Invoke-VpnServiceWorker $work 0
    Assert ($result -eq $false) 'lease error false';Assert-Failure 'service-lease' 'config-rejected'
    Reset-Mocks;$script:installed=$false;$script:available=$false;$script:uacExit=1223
    $result=Start-VpnServiceSession $work 0 (Join-Path $PSScriptRoot 'Vpn.Tun.ps1') @{}
    Assert ($result -eq $false) 'отмена UAC exit 1223 false';Assert-Failure 'install-service' 'uac-declined'
    Assert ((Read-TransportJson (Join-Path $work 'status/vpn.json')).summary.Contains('UAC отклонён')) 'честная отмена UAC'
    Reset-Mocks;$script:installed=$false;$script:available=$false;$script:cancelUac=$true
    $result=Start-VpnServiceSession $work 0 (Join-Path $PSScriptRoot 'Vpn.Tun.ps1') @{}
    Assert ($result -eq $false) 'отмена UAC Win32Exception false';Assert-Failure 'install-service' 'uac-declined'
    Reset-Mocks;$script:running=$false;$script:available=$false;$script:failStep='service-start'
    $result=Start-VpnServiceSession $work 0 (Join-Path $PSScriptRoot 'Vpn.Tun.ps1') @{}
    Assert ($result -eq $false) 'Start-Service error false';Assert-Failure 'service-start' 'service-unavailable'
    Reset-Mocks
    $protected=Protect-VpnServiceText 'pubkey short-id /secret-ws password-value' @{tls=@{reality=@{public_key='pubkey';short_id='short-id'}};transport=@{path='/secret-ws'};password='password-value'}
    Assert ($protected -notmatch 'pubkey|short-id|/secret-ws|password-value') 'все секретные поля удалены'
    Reset-Mocks;$script:probeFails=$true;$script:cleanupFails=$true
    $result=Invoke-VpnServiceWorker $work 0
    Assert ($result -eq $false) 'первичная ошибка и ошибка очистки возвращают false'
    Assert-Failure 'route-check'
    Assert ((Read-TransportJson (Join-Path $work 'status/vpn.json')).detail.Contains('cleanup-error')) 'причина очистки добавлена к первичной'
    Reset-Mocks
    $log=Join-Path $work 'logs/vpn-service-client.log';[IO.File]::WriteAllText($log,('x'*1MB))
    Write-VpnServiceLog $work 'vpn-service-client.log' 'rotation'
    Assert ((Test-Path -LiteralPath ($log+'.1')) -and (Get-Item -LiteralPath $log).Length -lt 1MB) 'ротация клиентского журнала 1 МиБ'
    function Test-BoundedProbe {
        $script:jobMode='timeout';$script:jobsStopped=0
        function Start-Job {param($ScriptBlock,$ArgumentList) [pscustomobject]@{State=$(if($script:jobMode -eq 'timeout'){'Running'}else{'Completed'})}}
        function Receive-Job {param($Job,$ErrorAction) if($script:jobMode -eq 'success'){@{step='https';ok=$true}}elseif($script:jobMode -eq 'failure'){@{step='dns';ok=$false;reason='check-failed';detail='dns fixture-client-password'}}else{@{step='dns'}}}
        function Stop-Job {param($Job,$ErrorAction) $script:jobsStopped++}
        function Remove-Job {param($Job,[switch]$Force,$ErrorAction)}
        $caught=$false
        try{& $realProbe @{} @{} 10}catch{$caught=$_.Exception.Data['vpnReason'] -eq 'check-timeout' -and $_.Exception.Data['vpnStep'] -eq 'dns'}
        Assert ($caught -and $script:jobsStopped -eq 1) 'общий таймаут сохраняет шаг, останавливает job'
        $script:jobMode='success';& $realProbe @{} @{} 1000
        Assert ($script:jobsStopped -eq 2) 'успешный job очищен'
        $script:jobMode='failure';$caught=$false
        try{& $realProbe @{} @{} 1000}catch{$caught=$_.Exception.Data['vpnStep'] -eq 'dns' -and $_.Exception.Message.Contains('fixture-client-password')}
        Assert ($caught -and $script:jobsStopped -eq 3) 'ошибка дочерней проверки передана с шагом'
    }
    Test-BoundedProbe
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
