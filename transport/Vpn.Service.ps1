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
        $pipe.Connect($TimeoutMs)
        [uint32]$serverPid=0
        if(-not [RemoteAgents.VpnPipeNative]::GetNamedPipeServerProcessId($pipe.SafePipeHandle,[ref]$serverPid)){throw 'VPN pipe identity unavailable'}
        $service=Get-CimInstance Win32_Service -Filter "Name='RemoteAgentsTun'" -ErrorAction Stop
        if(-not $service -or $serverPid -eq 0 -or $serverPid -ne [uint32]$service.ProcessId){throw 'VPN pipe identity mismatch'}
        $clock=[Diagnostics.Stopwatch]::StartNew();$utf8=New-Object Text.UTF8Encoding($false,$true)
        $bytes=$utf8.GetBytes($Line+"`n");$write=$pipe.WriteAsync($bytes,0,$bytes.Length)
        if(-not $write.Wait($TimeoutMs)){throw 'VPN pipe timeout'};$pipe.Flush()
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
    if($answer.ok -ne $true){$ex=New-Object Exception('VPN service rejected request');$ex.Data['vpnServiceError']=[string]$answer.error;throw $ex}
    return $answer
}
function New-VpnServiceStartRequest($Config,[int]$WatchPid) { @{protocol=1;command='start';watchPid=$WatchPid;config=$Config} }
function Get-VpnServiceStatus {
    try { Invoke-VpnServiceRequest @{protocol=1;command='status'} 1000 } catch { return $null }
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
    $process=Start-Process -FilePath $launcher -ArgumentList (($arguments|ForEach-Object {Quote-Transport $_}) -join ' ') -Verb RunAs -Wait -PassThru
    if($process.ExitCode -ne 0){throw 'VPN service installation failed'}
    $until=[DateTime]::UtcNow.AddSeconds(20)
    do{if(Get-VpnServiceStatus){return};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $until)
    throw 'VPN service unavailable after installation'
}
function Assert-VpnServiceReady([string]$Root,[int]$ParentPid,[string]$Status) {
    $bundle=Join-Path $PSScriptRoot 'sing-box.exe';$hash=''
    if(Test-Path -LiteralPath $bundle){$hash=([string](Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash).ToLowerInvariant()}
    $answer=Get-VpnServiceStatus
    if($answer -and $answer.protocol -eq 1 -and (-not $hash -or $answer.singBoxSha256 -eq $hash)){return}
    try{
        $installed=Get-Service -Name 'RemoteAgentsTun' -ErrorAction Stop
        if($installed.Status -ne 'Running'){
            Start-Service -Name 'RemoteAgentsTun' -ErrorAction Stop
            $until=[DateTime]::UtcNow.AddSeconds(20)
            do{
                $answer=Get-VpnServiceStatus
                if($answer -and $answer.protocol -eq 1 -and (-not $hash -or $answer.singBoxSha256 -eq $hash)){return}
                if($answer){break};Start-Sleep -Milliseconds 250
            }while([DateTime]::UtcNow -lt $until)
        }
    }catch{}
    if(-not $hash){throw 'Bundled sing-box missing; service cannot be installed'}
    Write-VpnStatus $Root $false $false 'awaiting-uac' ([pscustomobject]@{conflict=$false;items=@()}) 'Ожидается одно подтверждение UAC: установка службы VPN (один раз)'
    Install-VpnService $Root $ParentPid $bundle
    $answer=Get-VpnServiceStatus
    if(-not $answer -or $answer.protocol -ne 1 -or $answer.singBoxSha256 -ne $hash){throw 'VPN service version mismatch'}
}
function Start-VpnServiceSession([string]$Root,[int]$ParentPid,[string]$ScriptPath,$Conflict) {
    Assert-VpnServiceReady $Root $ParentPid (Join-Path $Root 'status/vpn.json')
    $mutex=New-Object Threading.Mutex($false,((Get-VpnTaskNames $Root).Worker+'-Service'));$held=$false
    try{
        try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){Write-Output 'Наш TUN уже работает';return}
        Remove-Item -LiteralPath (Join-Path $Root 'state/vpn.stop') -Force -ErrorAction SilentlyContinue
        Set-VpnEnabled $Root $true
        $mutex.ReleaseMutex();$held=$false
        $exe=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $arguments=@($exe,'-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$ScriptPath,'-Home',$Root,'-ServiceWorker','-ParentPid',[string]$ParentPid)
        try{
            $created=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=(($arguments|ForEach-Object {Quote-Transport $_}) -join ' ')} -ErrorAction Stop
            if($created.ReturnValue -ne 0){throw 'VPN worker creation failed'}
        }catch{Set-VpnEnabled $Root $false;throw}
        Write-VpnStatus $Root $false $true 'starting' $Conflict 'TUN запускается через службу; автооткат через пять минут'
    }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Invoke-VpnServiceWorker([string]$Root,[int]$ParentPid) {
    $mutex=New-Object Threading.Mutex($false,((Get-VpnTaskNames $Root).Worker+'-Service'))
    $locked=$false;$parent=$null;$session='';$failure=$false;$conflict=[pscustomobject]@{conflict=$false;items=@()}
    try{
        try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){throw 'TUN уже запущен'}
        if($ParentPid -gt 0){$parent=[Diagnostics.Process]::GetProcessById($ParentPid);[void]$parent.Handle}
        $lastRevision='';$lastTag='';$lastJson='';$nextCheck=[DateTime]::MinValue
        while($true){
            $settings=Read-TransportSettings $Root;$v=Get-VpnOptions $settings
            if(-not $v.enabled -or (Test-Path -LiteralPath (Join-Path $Root 'state/vpn.stop')) -or (Test-Path -LiteralPath (Join-Path $Root 'stop')) -or ($parent -and $parent.HasExited)){break}
            $status=Get-VpnTransportState $Root $settings
            $revision=(Get-TransportRevision $Root)+(ConvertTo-Json -InputObject $v -Depth 20 -Compress)
            if(-not $session -or $lastTag -ne $status.active -or $lastRevision -ne $revision -or [DateTime]::UtcNow -ge $nextCheck){
                $snapshot=Get-VpnSnapshot;$ownInterface='';if($session){$ownInterface=$v.interfaceName}
                $conflict=Find-VpnConflicts $snapshot @() $ownInterface
                $paths=Get-TransportCandidates $settings $Root;$net=Get-TransportNetwork;$exclude=Get-VpnExclusions $settings $paths $snapshot -Root $Root
                $cfg=New-VpnTunConfig $settings $paths $status.active $exclude $net.interface
                $newJson=ConvertTo-Json -InputObject $cfg -Depth 40 -Compress
                if(-not $session -or $newJson -ne $lastJson){
                    $started=Invoke-VpnServiceRequest (New-VpnServiceStartRequest $cfg $ParentPid)
                    $session=[string]$started.session;$adapter=$null
                    if(-not $session){throw 'TUN службы остановлен'}
                    for($i=0;$i -lt 40;$i++){
                        $live=Get-VpnServiceStatus
                        if(-not $live -or $live.session -ne $session -or $live.state -notin @('starting','on')){throw 'TUN службы остановлен'}
                        $adapter=Get-NetAdapter -IncludeHidden|Where-Object {$_.Name -eq $v.interfaceName -and $_.Status -eq 'Up'}|Select-Object -First 1
                        if($adapter){break};Start-Sleep -Milliseconds 250
                    }
                    if(-not $adapter){throw 'Не появился интерфейс TUN'}
                    Test-VpnThroughTun $settings $adapter
                    [void](Invoke-VpnServiceRequest @{protocol=1;command='confirm';session=$session})
                    $lastJson=$newJson
                }else{Test-VpnThroughTun $settings $adapter}
                $lastTag=$status.active;$lastRevision=$revision;$nextCheck=[DateTime]::UtcNow.AddSeconds(30)
            }
            $live=Get-VpnServiceStatus
            if(-not $live -or $live.session -ne $session -or $live.state -ne 'on'){throw 'TUN службы остановлен'}
            Write-VpnStatus $Root $true $true 'on' $conflict $(if($settings.Transport.bootstrap){'Начальный VPN: TUN, DNS и HTTPS проверены; SSH ещё не проверен'}else{'Системный VPN проверен; трафик идёт через выбранный путь'})
            Start-Sleep -Seconds 1
        }
    }catch{$failure=$true;throw}finally{
        $cleanupFailed=$false
        if($session){try{$stopped=Invoke-VpnServiceRequest @{protocol=1;command='stop';session=$session};$cleanupFailed=($stopped.state -ne 'off')}catch{$cleanupFailed=$true}}
        if($locked -and -not $failure){
            Set-VpnEnabled $Root $false
            if($cleanupFailed){Write-VpnStatus $Root $false $false 'rollback-error' $conflict 'Не удалось подтвердить остановку TUN службы'}
            else{Write-VpnStatus $Root $false $false 'off' $conflict 'Системный VPN выключен; TUN службы остановлен'}
        }
        if($locked){$mutex.ReleaseMutex()};$mutex.Dispose();if($parent){$parent.Dispose()}
    }
}
