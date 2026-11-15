#requires -Version 5.1
# User-side client. Privileged operations belong to the installed service.
function Get-VpnServiceInfo {
    $pf=$env:ProgramW6432;if(-not $pf){$pf=$env:ProgramFiles}
    @{Name='RemoteAgentsTun';Pipe='RemoteAgentsTun';Protocol=1;Directory=(Join-Path $pf 'RemoteAgents/vpn')}
}
function Test-VpnServiceMode { $env:OS -eq 'Windows_NT' -and $env:REMOTEAGENTS_VPN_LEGACY_UAC -ne '1' }
function Send-VpnServiceLine([string]$Line,[int]$TimeoutMs) {
    if(-not ('RemoteAgents.VpnPipeNative' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace RemoteAgents {
    public static class VpnPipeNative {
        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint pid);
    }
}
'@
    }
    $info=Get-VpnServiceInfo
    $pipe=New-Object IO.Pipes.NamedPipeClientStream('.', $info.Pipe, [IO.Pipes.PipeAccessRights]'ReadData, WriteData', [IO.Pipes.PipeOptions]::None, [Security.Principal.TokenImpersonationLevel]::Identification, [IO.HandleInheritability]::None)
    try{
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $pipe.Connect($TimeoutMs)
        [uint32]$serverPid=0
        if(-not [RemoteAgents.VpnPipeNative]::GetNamedPipeServerProcessId($pipe.SafePipeHandle,[ref]$serverPid)){throw 'VPN pipe identity unavailable'}
        $service=Get-CimInstance Win32_Service -Filter "Name='RemoteAgentsTun'" -OperationTimeoutSec 1 -ErrorAction Stop
        if(-not $service -or $serverPid -eq 0 -or $serverPid -ne [uint32]$service.ProcessId){throw 'VPN pipe identity mismatch'}
        $utf8=New-Object Text.UTF8Encoding($false,$true)
        $bytes=$utf8.GetBytes($Line+"`n");$write=$pipe.WriteAsync($bytes,0,$bytes.Length)
        if(-not $write.Wait([Math]::Max(1,$TimeoutMs-[int]$clock.ElapsedMilliseconds))){throw 'VPN pipe timeout'};$pipe.Flush()
        $buffer=New-Object byte[] 1;$result=New-Object IO.MemoryStream
        try{
            while($true){
                $left=$TimeoutMs-[int]$clock.ElapsedMilliseconds;if($left -le 0){throw 'VPN pipe timeout'}
                $read=$pipe.ReadAsync($buffer,0,1);if(-not $read.Wait($left)){throw 'VPN pipe timeout'}
                if($read.Result -eq 0){throw 'VPN pipe closed'}
                if($buffer[0] -eq 10){return $utf8.GetString($result.ToArray())}
                if($result.Length -ge 1048576){throw 'VPN response too large'};$result.WriteByte($buffer[0])
            }
        }finally{$result.Dispose()}
    }finally{$pipe.Dispose()}
}
function Invoke-VpnServiceRequest([hashtable]$Request,[int]$TimeoutMs=15000) {
    $line=ConvertTo-Json -InputObject $Request -Depth 40 -Compress
    $response=Send-VpnServiceLine $line $TimeoutMs
    $answer=ConvertFrom-Json -InputObject $response
    if($answer.ok -ne $true){throw (New-VpnServiceException '' ([string]$answer.reason) ([string]$answer.detail) ([string]$answer.error))}
    return $answer
}
function New-VpnServiceStartRequest($Config,[int]$WatchPid) { @{protocol=1;command='start';watchPid=$WatchPid;config=$Config} }
function Get-VpnServiceStatus([switch]$Strict) {
    try { Invoke-VpnServiceRequest @{protocol=1;command='status'} 1000 } catch { if($Strict){throw};return $null }
}
function Get-VpnServiceLauncher([string]$Root,[int]$ParentPid) {
    $choices=@((Join-Path $Root 'RemoteAgents.exe'),(Join-Path $Root 'RemoteVPN.exe'))|ForEach-Object {[IO.Path]::GetFullPath($_)}
    if($ParentPid -gt 0){try{$parent=Get-Process -Id $ParentPid -ErrorAction Stop;$image=[IO.Path]::GetFullPath($parent.Path);if($image -in $choices -and (Test-Path -LiteralPath $image)){return $image}}catch{}}
    foreach($file in $choices){if(Test-Path -LiteralPath $file){return $file}};throw 'VPN launcher missing'
}
function Get-VpnServiceOwnerSid { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
function Install-VpnService([string]$Root,[int]$ParentPid,[string]$SingBox) {
    $launcher=Get-VpnServiceLauncher $Root $ParentPid
    $arguments=@('--vpn-service-install','--home',$Root,'--owner-sid',(Get-VpnServiceOwnerSid),'--sing-box',$SingBox)
    try{$process=Start-Process -FilePath $launcher -ArgumentList (($arguments|ForEach-Object {Quote-Transport $_}) -join ' ') -Verb RunAs -Wait -PassThru -ErrorAction Stop}catch{
        $native=$_.Exception;while($native.InnerException){$native=$native.InnerException}
        if($native.NativeErrorCode -eq 1223){throw (New-VpnServiceException 'install-service' 'uac-declined' 'UAC отклонён (1223)')}
        throw (New-VpnServiceException 'install-service' 'install-failed' $_.Exception.ToString())
    }
    if($process.ExitCode -eq 1223){throw (New-VpnServiceException 'install-service' 'uac-declined' 'UAC отклонён (1223)')}
    if($process.ExitCode -ne 0){
        $diagnostic='';try{$diagnostic=(Get-Content -LiteralPath (Join-Path (Get-VpnServiceInfo).Directory 'logs/service.log') -Encoding UTF8 -Tail 10 -ErrorAction Stop) -join "`n"}catch{}
        throw (New-VpnServiceException 'install-service' 'install-failed' ('Установщик завершился с кодом '+$process.ExitCode+'; журнал службы: '+$diagnostic))
    }
    $until=[DateTime]::UtcNow.AddSeconds(20)
    do{if(Get-VpnServiceStatus){return};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $until)
    throw 'VPN service unavailable after installation'
}
function Assert-VpnServiceReady([string]$Root,[int]$ParentPid,[string]$Status) {
    $bundle=Join-Path $PSScriptRoot 'sing-box.exe';$hash=''
    if(Test-Path -LiteralPath $bundle){$hash=([string](Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash).ToLowerInvariant()}
    $answer=Get-VpnServiceStatus
    if($answer -and $answer.protocol -eq 1 -and (-not $hash -or $answer.singBoxSha256 -eq $hash)){return}
    $installed=$null;try{$installed=Get-Service -Name 'RemoteAgentsTun' -ErrorAction Stop}catch{}
    if($installed -and $installed.Status -ne 'Running'){
        try{
            Start-Service -Name 'RemoteAgentsTun' -ErrorAction Stop
            $until=[DateTime]::UtcNow.AddSeconds(20)
            do{
                $answer=Get-VpnServiceStatus
                if($answer -and $answer.protocol -eq 1 -and (-not $hash -or $answer.singBoxSha256 -eq $hash)){return}
                if($answer){break};Start-Sleep -Milliseconds 250
            }while([DateTime]::UtcNow -lt $until)
            if(-not $answer){throw 'Служба не ответила за 20 с'}
        }catch{throw (New-VpnServiceException 'service-start' 'service-unavailable' $_.Exception.ToString())}
    }
    if(-not $hash){throw 'Bundled sing-box missing; service cannot be installed'}
    Write-VpnStatus $Root $false $false 'awaiting-uac' ([pscustomobject]@{conflict=$false;items=@()}) 'Ожидается одно подтверждение UAC: установка службы VPN (один раз)'
    Install-VpnService $Root $ParentPid $bundle
    $answer=Get-VpnServiceStatus
    if(-not $answer -or $answer.protocol -ne 1 -or $answer.singBoxSha256 -ne $hash){throw 'VPN service version mismatch'}
}
function New-VpnServiceException([string]$Step,[string]$Reason,[string]$Detail,[string]$Code='') {
    if(-not $Reason){$Reason=$Code};if(-not $Reason){$Reason='check-failed'}
    $ex=New-Object Exception($Detail);$ex.Data['vpnStep']=$Step;$ex.Data['vpnReason']=$Reason;$ex.Data['vpnDetail']=$Detail;$ex.Data['vpnServiceError']=$Code
    return $ex
}
function Get-VpnServiceSecrets($Value,[string]$Parent='') {
    if($null -eq $Value){return}
    if($Value -is [Collections.IDictionary]){$pairs=@($Value.Keys|ForEach-Object {[pscustomobject]@{Name=$_;Value=$Value[$_]}})}
    elseif($Value -is [pscustomobject]){$pairs=@($Value.PSObject.Properties)}
    elseif($Value -is [array]){foreach($item in $Value){Get-VpnServiceSecrets $item $Parent};return}else{return}
    foreach($pair in $pairs){
        if($pair.Value -is [string] -and ($pair.Name -in @('password','uuid','public_key','short_id') -or ($Parent -eq 'transport' -and $pair.Name -eq 'path'))){$pair.Value}
        Get-VpnServiceSecrets $pair.Value $pair.Name
    }
}
function Protect-VpnServiceText([string]$Text,$Settings) {
    $context=@{settings=$Settings;secret=@(Get-VpnServiceSecrets $Settings)}
    Protect-TransportDiagnostic (Protect-TransportDiagnostic $Text $context) $context
}
function Write-VpnServiceLog([string]$Root,[string]$Name,[string]$Text) {
    $dir=Join-Path $Root 'logs';[void][IO.Directory]::CreateDirectory($dir);$file=Join-Path $dir $Name
    $utf8=New-Object Text.UTF8Encoding($false)
    for($offset=0;$offset -lt $Text.Length;$offset+=100000){
        $entry=[DateTime]::UtcNow.ToString('o')+' '+$Text.Substring($offset,[Math]::Min(100000,$Text.Length-$offset))+"`r`n"
        if((Test-Path -LiteralPath $file) -and ((Get-Item -LiteralPath $file).Length+$utf8.GetByteCount($entry)) -gt 1MB){Move-Item -LiteralPath $file -Destination ($file+'.1') -Force}
        [IO.File]::AppendAllText($file,$entry,$utf8)
    }
}
function Write-VpnServiceFailure([string]$Root,[string]$Step,$ErrorRecord,$Conflict,$Settings,[switch]$PreserveStatus) {
    $ex=$ErrorRecord.Exception
    if($ex.Data['vpnStep']){$Step=[string]$ex.Data['vpnStep']}
    $reason=[string]$ex.Data['vpnReason'];if(-not $reason){$reason=[string]$ex.Data['vpnServiceError']};if(-not $reason){$reason=$ex.GetType().Name}
    if($reason -notmatch '^[A-Za-z0-9_.:-]{1,128}$'){$reason='operation-failed'}
    $stored=$null;try{$stored=Read-TransportJson (Join-Path $Root 'config.json')}catch{}
    $context=@{settings=$Settings;stored=$stored}
    $full=Protect-VpnServiceText ($ex.ToString()+"`n"+($ErrorRecord|Out-String)) $context
    $detail=[string]$ex.Data['vpnDetail'];if(-not $detail){$detail=$ex.GetType().FullName+': '+$ex.Message}
    $detail=Protect-VpnServiceText $detail $context;if($detail.Length -gt 2000){$detail=$detail.Substring(0,2000)}
    $summary='Ошибка VPN на шаге «'+$Step+'»: '+$detail
    try{Set-VpnEnabled $Root $false}catch{}
    $path=Join-Path $Root 'status/vpn.json'
    try{
        if($PreserveStatus){
            $previous=Read-TransportJson $path
            $combined=Protect-VpnServiceText ($previous.detail+'; '+$Step+': '+$reason+'; '+$detail) $context
            if($combined.Length -gt 2000){$combined=$combined.Substring(0,2000)}
            $previous.detail=$combined;$previous.updatedAt=[DateTime]::UtcNow.ToString('o');Write-TransportJson $path $previous
        }else{Write-TransportJson $path @{ok=$false;enabled=$false;state='error';conflict=$Conflict;summary=$summary;updatedAt=[DateTime]::UtcNow.ToString('o');step=$Step;reason=$reason;detail=$detail}}
    }finally{
        try{Write-VpnServiceLog $Root 'vpn.log' ('error step='+$Step+' reason='+$reason)}finally{Write-VpnServiceLog $Root 'vpn-service-client.log' ('state=error step='+$Step+' reason='+$reason+"`r`n"+$full)}
    }
}
function Assert-VpnServiceSession($Live,[string]$Session,[string[]]$States,[string]$Step='service-stopped') {
    if(-not $Live -or $Live.session -ne $Session -or $Live.state -notin $States){
        $reason='service-unavailable';$detail='Служба не отвечает'
        if($Live){$reason=[string]$Live.reason;if(-not $reason){$reason='session-stopped'};$detail='state='+$Live.state+'; '+$Live.detail}
        throw (New-VpnServiceException $Step $reason $detail)
    }
}
function Invoke-VpnServiceSshProbe($Settings,$v) {
    $a=@(Get-TransportSshArguments $Settings.Profile 22)+@($v.probeAddress,'head -c 65536 /dev/urandom')
    $child=$null;$sink=$null;$copy=$null
    try{
        $child=Start-TransportProcess $Settings.Profile.sshExecutable $a -Probe
        Initialize-TransportCounter;$sink=New-Object RemoteAgents.TransportCounter
        $copy=$child.Process.StandardOutput.BaseStream.CopyToAsync($sink)
        $probe=[pscustomobject]@{child=$child;sink=$sink;copy=$copy;state=(New-TransportProbeState 65536 5 20);tag='tun-check'}
        while(-not (Receive-TransportProbe $probe)){Start-Sleep -Milliseconds 100}
        if($probe.state.state -ne 'ok'){
            $diagnostic=New-TransportDiagnostic $child 'tun-check' $probe.state.state $Settings
            throw (New-VpnServiceException 'ssh-probe' $diagnostic.reason ('SSH 64 КиБ: bytes='+$probe.state.bytes+'; '+(Format-TransportDiagnostic $diagnostic)))
        }
    }finally{Stop-TransportProcess $child;try{if($copy){[void]$copy.Wait(1000)}}catch{};if($sink){$sink.Dispose()}}
}
function Get-VpnServiceDnsAddresses([string]$HostName) {
    $dns=[Net.Dns]::GetHostAddressesAsync($HostName)
    if(-not $dns.Wait(5000)){throw 'DNS timeout 5s'}
    $addresses=@($dns.Result);if(-not $addresses.Count){throw 'DNS через VPN не отвечает'}
    return $addresses
}
function Invoke-VpnServiceHttpsRequest([Uri]$Uri) {
    $req=[Net.HttpWebRequest]::Create($uri);$req.Proxy=$null;$req.Timeout=12000;$req.ReadWriteTimeout=12000;$req.AllowAutoRedirect=$false;$req.KeepAlive=$false
    $response=$null
    try{
        try{$response=$req.GetResponse()}catch{
            $cause=$_.Exception;while($cause.InnerException){$cause=$cause.InnerException}
            if($cause.Response){$response=$cause.Response;throw ('HTTP '+[int]$response.StatusCode+'; '+$cause.GetType().FullName+': '+$cause.Message)}
            throw
        }
        if([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300){throw ('HTTP '+[int]$response.StatusCode)}
    }finally{if($response){$response.Dispose()};$req.Abort()}
}
# Kept separate for offline tests; the worker runs these checks in a bounded child job.
function Test-VpnServiceChecks($Settings,$Adapter) {
    $step='route-check'
    try{
        $v=Get-VpnOptions $Settings
        Write-Output @{step=$step}
        Assert-VpnTunRoute $v.probeAddress $Adapter.ifIndex
        if(-not $Settings.Transport.bootstrap){
            $step='ssh-probe';Write-Output @{step=$step}
            Invoke-VpnServiceSshProbe $Settings $v
        }
        $step='dns';Write-Output @{step=$step};$uri=[Uri]$v.checkUrl
        $addresses=@(Get-VpnServiceDnsAddresses $uri.DnsSafeHost)
        $step='route-check';Write-Output @{step=$step}
        foreach($ip in $addresses){Assert-VpnTunRoute $ip.ToString() $Adapter.ifIndex}
        $step='https';Write-Output @{step=$step}
        Invoke-VpnServiceHttpsRequest $uri
        Write-Output @{ok=$true;step='https'}
    }catch{
        if($_.Exception.Data['vpnStep']){throw}
        $cause=$_.Exception;while($cause.InnerException){$cause=$cause.InnerException}
        throw (New-VpnServiceException $step 'check-failed' ($cause.GetType().FullName+': '+$cause.Message))
    }
}
function Test-VpnServiceThroughTun($Settings,$Adapter,[int]$TimeoutMs=55000) {
    $job=$null;$probeProcess=$null;$step='route-check';$passed=$false;$clock=[Diagnostics.Stopwatch]::StartNew()
    try{
        $probeAdapter=[pscustomobject]@{ifIndex=[int]$Adapter.ifIndex}
        $job=Start-Job -ScriptBlock {
            param($Settings,$Adapter,$Common,$Client)
            $ErrorActionPreference='Stop';Write-Output @{probePid=$PID};. $Common;. $Client
            try{Test-VpnServiceChecks $Settings $Adapter}catch{
                Write-Output @{ok=$false;step=[string]$_.Exception.Data['vpnStep'];reason=[string]$_.Exception.Data['vpnReason'];detail=[string]$_.Exception.Data['vpnDetail']}
            }
        } -ArgumentList $Settings,$probeAdapter,(Join-Path $PSScriptRoot 'Transport.Common.ps1'),(Join-Path $PSScriptRoot 'Vpn.Service.ps1')
        while($true){
            foreach($result in @(Receive-Job $job -ErrorAction Stop)){
                if($result.probePid){try{$probeProcess=[Diagnostics.Process]::GetProcessById([int]$result.probePid);[void]$probeProcess.Handle}catch{}}
                if($result.step){$step=[string]$result.step}
                if($result.ok -eq $false){throw (New-VpnServiceException $step ([string]$result.reason) ([string]$result.detail))}
                if($result.ok -eq $true){$passed=$true}
            }
            if($clock.ElapsedMilliseconds -ge $TimeoutMs){throw (New-VpnServiceException $step 'check-timeout' 'Проверка превысила общий предел 55 с')}
            if($job.State -in @('Completed','Failed','Stopped')){break}
            Start-Sleep -Milliseconds 100
        }
        if(-not $passed){throw (New-VpnServiceException $step 'check-failed' ('Проверка не завершилась: '+$job.State))}
    }finally{
        if($probeProcess){try{if(-not $probeProcess.HasExited){$probeProcess.Kill();[void]$probeProcess.WaitForExit(500)}}catch{};$probeProcess.Dispose()}
        if($job){Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue}
    }
}
function Start-VpnServiceSession([string]$Root,[int]$ParentPid,[string]$ScriptPath,$Conflict) {
    $step='install-service';$mutex=$null;$held=$false
    try{
        Assert-VpnServiceReady $Root $ParentPid (Join-Path $Root 'status/vpn.json')
        $step='service-start'
        $mutex=New-Object Threading.Mutex($false,((Get-VpnTaskNames $Root).Worker+'-Service'))
        try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){return $true}
        $clean=Invoke-VpnServiceRequest @{protocol=1;command='cleanup'}
        if($clean.state -eq 'cleanup-error'){throw (New-VpnServiceException $step ([string]$clean.reason) ([string]$clean.detail))}
        Remove-Item -LiteralPath (Join-Path $Root 'state/vpn.stop') -Force -ErrorAction SilentlyContinue
        Set-VpnEnabled $Root $true
        # Publish before Create: a fast worker error must not be overwritten by starting.
        Write-VpnStatus $Root $false $true 'starting' $Conflict 'TUN запускается через службу; окно проверки 90 с, аренда 90 с'
        $mutex.ReleaseMutex();$held=$false
        $exe=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $arguments=@($exe,'-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$ScriptPath,'-Home',$Root,'-ServiceWorker','-ParentPid',[string]$ParentPid)
        $created=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=(($arguments|ForEach-Object {Quote-Transport $_}) -join ' ')} -ErrorAction Stop
        if($created.ReturnValue -ne 0){throw ('VPN worker creation failed: '+$created.ReturnValue)}
        return $true
    }catch{try{Write-VpnServiceFailure $Root $step $_ $Conflict $null}catch{};return $false}
    finally{if($mutex){if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}}
}
function Get-VpnServiceUtcNow { [DateTime]::UtcNow }
function Invoke-VpnServiceWorker([string]$Root,[int]$ParentPid) {
    $mutex=$null;$locked=$false;$parent=$null;$session='';$failure=$false;$conflict=[pscustomobject]@{conflict=$false;items=@()};$settings=$null;$cfg=$null;$step='service-start'
    try{
        $mutex=New-Object Threading.Mutex($false,((Get-VpnTaskNames $Root).Worker+'-Service'))
        try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){throw 'TUN уже запущен'}
        if($ParentPid -gt 0){$parent=[Diagnostics.Process]::GetProcessById($ParentPid);[void]$parent.Handle}
        $lastRevision='';$lastTag='';$lastJson='';$nextCheck=[DateTime]::MinValue
        while($true){
            $step='service-start';$settings=Read-TransportSettings $Root;$v=Get-VpnOptions $settings
            if(-not $v.enabled -or (Test-Path -LiteralPath (Join-Path $Root 'state/vpn.stop')) -or (Test-Path -LiteralPath (Join-Path $Root 'stop')) -or ($parent -and $parent.HasExited)){break}
            $status=Get-VpnTransportState $Root $settings
            $revision=(Get-TransportRevision $Root)+(ConvertTo-Json -InputObject $v -Depth 20 -Compress)
            if(-not $session -or $lastTag -ne $status.active -or $lastRevision -ne $revision -or (Get-VpnServiceUtcNow) -ge $nextCheck){
                if(-not $session -or $lastTag -ne $status.active -or $lastRevision -ne $revision){
                    $snapshot=Get-VpnSnapshot;$ownInterface='';if($session){$ownInterface=$v.interfaceName}
                    $conflict=Find-VpnConflicts $snapshot @() $ownInterface
                    $paths=Get-TransportCandidates $settings $Root;$net=Get-TransportNetwork;$exclude=Get-VpnExclusions $settings $paths $snapshot -Root $Root
                    $cfg=New-VpnTunConfig $settings $paths $status.active $exclude $net.interface
                    $newJson=ConvertTo-Json -InputObject $cfg -Depth 40 -Compress
                    if(-not $session -or $newJson -ne $lastJson){
                        $started=Invoke-VpnServiceRequest (New-VpnServiceStartRequest $cfg $ParentPid)
                        $session=[string]$started.session;$adapter=$null
                        $step='wait-interface';$wait=[Diagnostics.Stopwatch]::StartNew();$live=$started
                        try{
                            for($i=0;$i -lt 40 -and $wait.Elapsed.TotalSeconds -lt 10;$i++){
                                $live=Get-VpnServiceStatus -Strict
                                Assert-VpnServiceSession $live $session @('starting','on') $step
                                $adapter=Get-NetAdapter -IncludeHidden|Where-Object {$_.Name -eq $v.interfaceName -and $_.Status -eq 'Up'}|Select-Object -First 1
                                if($adapter){break};Start-Sleep -Milliseconds 250
                            }
                            if(-not $adapter){throw (New-VpnServiceException $step 'interface-timeout' ('Ожидание '+[Math]::Round($wait.Elapsed.TotalSeconds,2)+' с; служба: '+($live|ConvertTo-Json -Compress)))}
                        }catch{
                            $why=[string]$_.Exception.Data['vpnReason'];if(-not $why){$why='interface-error'}
                            $text='Ожидание '+[Math]::Round($wait.Elapsed.TotalSeconds,2)+' с; служба: '+($live|ConvertTo-Json -Compress)+'; '+$_.Exception.Message
                            throw (New-VpnServiceException $step $why $text)
                        }
                        $lastJson=$newJson
                    }
                }
                $step='route-check';Test-VpnServiceThroughTun $settings $adapter
                $step='service-lease';$confirmed=Invoke-VpnServiceRequest @{protocol=1;command='confirm';session=$session} 3000
                Assert-VpnServiceSession $confirmed $session @('on') $step
                $lastTag=$status.active;$lastRevision=$revision;$nextCheck=(Get-VpnServiceUtcNow).AddSeconds(30)
            }
            $step='service-stopped';$live=Get-VpnServiceStatus -Strict
            Assert-VpnServiceSession $live $session @('on')
            Write-VpnStatus $Root $true $true 'on' $conflict $(if($settings.Transport.bootstrap){'Начальный VPN: TUN, DNS и HTTPS проверены; SSH ещё не проверен'}else{'Системный VPN проверен; трафик идёт через выбранный путь'})
            Start-Sleep -Seconds 1
        }
    }catch{$failure=$true;try{Write-VpnServiceFailure $Root $step $_ $conflict @{settings=$settings;config=$cfg}}catch{}}
    finally{
        if($session){
            try{
                $stopped=Invoke-VpnServiceRequest @{protocol=1;command='stop';session=$session}
                if($stopped.state -ne 'off'){throw (New-VpnServiceException 'service-stopped' ([string]$stopped.reason) ([string]$stopped.detail))}
            }catch{$prior=$failure;$failure=$true;try{Write-VpnServiceFailure $Root 'service-stopped' $_ $conflict @{settings=$settings;config=$cfg} -PreserveStatus:$prior}catch{}}
        }
        if($locked -and -not $failure){try{Set-VpnEnabled $Root $false;Write-VpnStatus $Root $false $false 'off' $conflict 'Системный VPN выключен; TUN службы остановлен'}catch{$failure=$true;try{Write-VpnServiceFailure $Root 'service-stopped' $_ $conflict $settings}catch{}}}
        if($mutex){if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()};if($parent){$parent.Dispose()}
    }
    return (-not $failure)
}
