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
