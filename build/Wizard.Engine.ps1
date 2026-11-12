#requires -Version 5.1
# Long actions own only their mutable resource. Config R/M/W retains its short mutex.
function Get-WizardResources([string]$Action,$Request) {
    switch($Action){
        {$_ -in @('Connection','RollbackNetwork','InviteRefresh','InviteSync')} {return @('connection')}
        {$_ -in @('Bridge','RollbackBridge')} {return @('bridge')}
        {$_ -in @('Account','ResumeAccount','InviteAccount')} {return @('account')}
        {$_ -in @('Disk','InviteDisk')} {return @('disk')}
        {$_ -in @('Vpn','Bootstrap','InvitePrepare')} {return @('vpn')}
        {$_ -in @('Proxy','Lan','LanRemove')} {return @('server-network')}
        'Server' {return @('profile')}
        'Skip' {if($Request.step -eq 'Disk'){return @('disk')}}
        'Operation' {if($Request.start){return @('server-install-'+[string]$Request.start)}}
    }
    return @()
}
function Invoke-WizardResourceLock([string]$Root,[string]$Resource,[scriptblock]$Body,[int]$TimeoutMs=120000) {
    $name='Global\RemoteAgentsWizard-'+(Get-TransportFingerprint $Resource (Get-TransportHome $Root).ToLowerInvariant())
    $mutex=New-Object Threading.Mutex($false,$name);$locked=$false
    try{
        try{$locked=$mutex.WaitOne($TimeoutMs)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){throw ('Раздел занят: '+$Resource+'; повторите после завершения')}
        & $Body
    }finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Invoke-WizardAction([string]$Root,[string]$Action,$Request,[scriptblock]$Body) {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try{
        $resources=@(Get-WizardResources $Action $Request)
        if($resources.Count){Invoke-WizardResourceLock $Root $resources[0] $Body}else{& $Body}
    }finally{
        # Same JSONL envelope as other progress messages, including failed stages.
        Write-WizardProgress ('timing '+$Action+' '+$watch.ElapsedMilliseconds)
    }
}

function Start-WizardWorkingTransport([string]$Root,[string]$Bundle) {
    # The daemon's own per-Home mutex arbitrates with the tray supervisor.
    $stop=Join-Path $Root 'state/transport.stop';if(Test-Path $stop){Remove-Item -LiteralPath $stop -Force}
    $si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=Get-TransportPowerShell
    $si.Arguments=((@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $Bundle 'transport/Transport.Daemon.ps1'),'-Home',$Root)|ForEach-Object {Quote-Transport $_}) -join ' ')
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    $child=New-Object Diagnostics.Process;$child.StartInfo=$si
    try{[void]$child.Start();[void]$child.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null);[void]$child.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)}finally{$child.Dispose()}
}
function Wait-WizardWorkingProof([string]$Root,[DateTime]$Mark,[int]$Timeout=120) {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds -lt $Timeout){
        if(Test-WizardNetworkProof $Root $Mark){return}
        Start-Sleep -Milliseconds 200
    }
    throw 'Рабочая связь не подтверждена; повторите раздел «Связь»'
}
function Set-WizardInitialNetwork([string]$Root,[string]$Bundle,$Transport) {
    $previous=(Read-TransportJson (Join-Path $Root 'config.json')).transport;$mark=[DateTime]::UtcNow
    try{
        Update-LauncherConfig $Root {param($c) $c|Add-Member -Force transport $Transport}
        Start-WizardWorkingTransport $Root $Bundle
        Wait-WizardWorkingProof $Root $mark
    }catch{
        Update-LauncherConfig $Root {param($c) $c|Add-Member -Force transport $previous}
        throw
    }
}
