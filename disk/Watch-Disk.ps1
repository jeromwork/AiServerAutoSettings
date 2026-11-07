#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$HomePath,[Parameter(Mandatory=$true)][int]$ParentId)
. (Join-Path $PSScriptRoot 'RemoteDisk.ps1') -LibraryOnly
$script:DiskHome=$HomePath;$script:ConfigFile=Join-Path $HomePath 'config.json'
$script:LogFile=Join-Path $HomePath 'logs/safety.jsonl';$script:HostName=$env:COMPUTERNAME
$script:LocalKey='';$script:RemoteKey='';$script:ApiTimeout=1
Add-Type -AssemblyName System.Windows.Forms
# A .NET callback only records a signal. It never calls PowerShell on an alien thread.
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Threading;
using Microsoft.Win32;
public static class DiskSafetySignals {
    public static volatile string Reason = "start";
    public static int Epoch;
    public static void Power(object sender, PowerModeChangedEventArgs e) {
        if (e.Mode == PowerModes.Suspend || e.Mode == PowerModes.Resume) {
            Reason = e.Mode.ToString(); Interlocked.Increment(ref Epoch);
        }
    }
    public static void Lost(object sender, EventArgs e) { Reason="offline"; Interlocked.Increment(ref Epoch); }
    public static void Subscribe() { SystemEvents.PowerModeChanged+=Power; }
    public static void Unsubscribe() { SystemEvents.PowerModeChanged-=Power; }
    public static void Watch(Process p) { p.EnableRaisingEvents=true; p.Exited+=Lost; }
}
'@
$parent=$null;try{$parent=[Diagnostics.Process]::GetProcessById($ParentId)}catch{}
$jobs=@{};$checked=@{};$startupReady=$false;$exitMode='';$tunnel=$null;$tunnelId=0;$tunnelStarted='';$lastEpoch=-1;$loggedEpoch=-1;$lastMessage=''
[DiskSafetySignals]::Subscribe()
$owner=New-Object Threading.Mutex($false,('Local\RemoteDiskSafety-'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
try{[void]$owner.WaitOne()}catch [Threading.AbandonedMutexException]{}
try{
    while($true){
        [Windows.Forms.Application]::DoEvents()
        $newConfig=Read-DiskJson $script:ConfigFile
        if(-not $newConfig){throw 'RemoteDisk config disappeared'}
        $script:Config=$newConfig
        $control=Read-DiskJson (Join-Path $HomePath 'safety-stop.json')
        if($control){$exitMode=$control.mode}
        if(($null -eq $parent -or $parent.HasExited) -and -not $exitMode){$exitMode='exit'}
        $reason=[DiskSafetySignals]::Reason
        if($exitMode){$reason='exit'}
        $epoch=[DiskSafetySignals]::Epoch
        if($epoch -ne $loggedEpoch){Write-DiskLog 'safety.signal' $reason;$loggedEpoch=$epoch}
        $xmlPath=Join-Path $HomePath 'state/config.xml'
        if(Test-Path -LiteralPath $xmlPath){[xml]$xml=[IO.File]::ReadAllText($xmlPath);$script:LocalKey=$xml.configuration.gui.apikey}
        $channel=Read-DiskJson (Join-Path $HomePath 'safety-channel.json')
        $alive=$false;$localConnected=$false;$remoteConfirmed=$false;$localAvailable=$false
        if($channel -and -not $exitMode){
            try{
                if($tunnelId -ne $channel.tunnelPid -or $tunnelStarted -ne $channel.tunnelStarted){
                    if($tunnel){$tunnel.Dispose()};$tunnel=[Diagnostics.Process]::GetProcessById($channel.tunnelPid)
                    if($tunnel.StartTime.ToUniversalTime().ToString('o') -ne $channel.tunnelStarted){throw 'Tunnel PID reused'}
                    [DiskSafetySignals]::Watch($tunnel);$tunnelId=$channel.tunnelPid;$tunnelStarted=$channel.tunnelStarted
                }
                $alive=-not $tunnel.HasExited
                if($alive){
                    $con=Invoke-DiskApi local 'system/connections';$localAvailable=$true
                    $p=$con.connections.PSObject.Properties[$channel.serverId];$localConnected=$null -ne $p -and $p.Value.connected
                    if($localConnected){
                        $script:RemoteKey=$channel.remoteKey
                        $remote=Invoke-DiskApi remote 'system/connections';$status=Invoke-DiskApi remote 'system/status'
                        $p=$remote.connections.PSObject.Properties[$channel.localId]
                        $remoteConfirmed=$status.myID -eq $channel.serverId -and $null -ne $p -and $p.Value.connected
                    }
                }
            }catch{$remoteConfirmed=$false}
        }
        # A signal that arrived during REST invalidates that entire proof.
        if($epoch -ne [DiskSafetySignals]::Epoch){$reason=[DiskSafetySignals]::Reason;$remoteConfirmed=$false}
        $force=$reason -in @('start','Suspend','Resume','exit') -and ($reason -eq 'Suspend' -or $lastEpoch -ne $epoch -or -not $startupReady -or $exitMode)
        $eventName='poll';if($force){$eventName=$reason}
        $allDone=$true;$allInitiallyLocked=$true;$states=@()
        foreach($folder in @($script:Config.folders)){
            $record=Get-DiskLockRecord $HomePath $folder
            $manual=(Test-Path -LiteralPath ($record+'.unlock')) -and -not $exitMode
            $info=Get-DiskLockInfo $HomePath $folder
            $plan=Get-DiskSafetyPlan $eventName $alive $localConnected $remoteConfirmed ($info.locked -eq $false) ([bool]$info.error)
            $wantLock=$plan.lock -and -not $manual
            if($exitMode -eq 'unlock'){$wantLock=$false}
            $info=Get-DiskLockInfo $HomePath $folder
            $aclError=$info.error
            # Pause BEFORE touching ACL. On recovery resume only AFTER successful ACL removal.
            try{
                $actual=Invoke-DiskApi local ('config/folders/'+$folder.id)
                $pause=$plan.pause -or $wantLock -or $null -ne $jobs[$folder.id] -or $info.locked -or [bool]$aclError -or $folder.paused
                if($actual.paused -ne $pause){[void](Invoke-DiskApi local ('config/folders/'+$folder.id) PATCH @{paused=$pause;versioning=@{type=''}})}
                $localAvailable=$true
            }catch{
                # Offline XML is set to paused by Initialize-DiskLocal before engine start.
                $localAvailable=$false
            }
            $job=$jobs[$folder.id]
            if($job -and $job.process.HasExited){
                $result=Read-DiskJson ($record+'.result')
                if($job.process.ExitCode -ne 0 -or -not $result -or -not $result.ok){
                    $aclError='ACL operation failed, exit '+$job.process.ExitCode
                    if($result -and -not $result.ok -and $result.error){$aclError=$result.error}
                    $result=[pscustomobject]@{ok=$false;locked=$null;error=$aclError;time=[DateTime]::UtcNow.ToString('o')}
                    Write-DiskJson ($record+'.result') $result
                }
                $checked[$folder.id]=@{locked=$job.locked;ok=($null -ne $result -and $result.ok -and $job.process.ExitCode -eq 0)}
                $job.process.Dispose();$jobs.Remove($folder.id);$job=$null;$info=Get-DiskLockInfo $HomePath $folder
                Write-DiskLog 'acl.result' ('id='+$folder.id+' locked='+$info.locked+' error='+$aclError)
            }
            $proof=$checked[$folder.id]
            if(-not $job -and (-not $proof -or $proof.locked -ne $wantLock -or ($proof.ok -and $info.locked -ne $wantLock))){
                $jobs[$folder.id]=@{process=(Start-DiskAclProcess $HomePath $folder $wantLock);locked=$wantLock};$job=$jobs[$folder.id]
                Write-DiskLog 'acl.start' ('id='+$folder.id+' locked='+$wantLock+' reason='+$eventName)
            }
            if($job -or $aclError -or -not $proof -or -not $proof.ok -or $proof.locked -ne $wantLock -or $info.locked -ne $wantLock){$allDone=$false}
            if($job -or $aclError -or -not $proof -or -not $proof.ok -or -not $info.locked){$allInitiallyLocked=$false}
            if(-not $wantLock -and -not $job -and -not $aclError -and $info.locked -eq $false -and $alive -and $localConnected -and $remoteConfirmed -and -not $force -and $proof -and $proof.ok -and -not $proof.locked -and $epoch -eq [DiskSafetySignals]::Epoch -and -not $tunnel.HasExited){
                try{[void](Invoke-DiskApi local ('config/folders/'+$folder.id) PATCH @{paused=[bool]$folder.paused})}catch{$aclError='Cannot resume local Syncthing';$allDone=$false}
            }
            $states+=@{id=$folder.id;locked=$info.locked;pending=($null -ne $job);error=$aclError}
        }
        if($allInitiallyLocked){$startupReady=$true}
        if($allDone){$lastEpoch=$epoch;if($reason -ne 'Suspend'){[DiskSafetySignals]::Reason='poll'}}
        Write-DiskJson (Join-Path $HomePath 'safety-state.json') @{pid=$PID;startupReady=$startupReady;remoteConfirmed=$remoteConfirmed;folders=$states;time=[DateTime]::UtcNow.ToString('o')}
        if($exitMode -and $jobs.Count -eq 0 -and @($script:Config.folders|Where-Object {-not $checked.ContainsKey($_.id)}).Count -eq 0){
            if(-not $allDone){throw 'ACL verification failed during exit/unlock'}
            break
        }
        Start-Sleep -Milliseconds 100
    }
}catch{
    $failure=$_.Exception.Message
    Write-DiskLog 'safety.error' $failure
    Write-DiskJson (Join-Path $HomePath 'safety-state.json') @{pid=$PID;startupReady=$false;error=$failure;time=[DateTime]::UtcNow.ToString('o')}
    if($exitMode -ne 'unlock'){
        foreach($folder in @($script:Config.folders)){
            try{[void](Invoke-DiskApi local ('config/folders/'+$folder.id) PATCH @{paused=$true})}catch{}
            try{$emergency=Start-DiskAclProcess $HomePath $folder $true;while(-not $emergency.WaitForExit(100)){};$emergency.Dispose()}catch{Write-DiskLog 'acl.emergency.error' $_.Exception.Message}
        }
    }
    throw
}
finally{
    [DiskSafetySignals]::Unsubscribe()
    $owner.ReleaseMutex();$owner.Dispose()
    if($tunnel){$tunnel.Dispose()};if($parent){$parent.Dispose()}
}
