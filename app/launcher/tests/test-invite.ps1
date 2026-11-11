#requires -Version 5.1
param([string]$TestHome,[string]$InvitePath,[string]$Relay,[switch]$HostMismatch,[string]$ExpectedFailure)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Wizard.Common.ps1')
$env:LOCALAPPDATA=$TestHome
$root=Join-Path $TestHome 'RemoteAgents'
[void][IO.Directory]::CreateDirectory((Join-Path $root 'secrets'))
Write-TransportJson (Join-Path $root 'config.json') @{schema=1;version=1;transport=@{};components=@{}}
$script:WizardProgressFile=Join-Path $TestHome 'progress.jsonl'
$request=[pscustomobject]@{path=$InvitePath;askpassExecutable=$Relay}
if($ExpectedFailure){
    $why='';try{Connect-WizardInvite $root $request|Out-Null}catch{$why=$_.Exception.Message}
    $expected=if($ExpectedFailure -eq 'used'){'*уже использовано*'}else{'*Срок приглашения истёк*'}
    if($why -notlike $expected){throw ('Unexpected error: '+$why)}
    Write-Host ('PASS: invitation '+$ExpectedFailure+' has a separate understandable error')
    return
}
if($HostMismatch){
    $why='';try{Connect-WizardInvite $root $request|Out-Null}catch{$why=$_.Exception.Message}
    if($why -notlike '*Ключ хоста*'){throw ('FAIL host mismatch: '+$why)}
    if((Read-TransportJson (Join-Path $root 'config.json')).transport.profilePath){throw 'Untrusted host saved active profile'}
    Write-Host 'PASS: invitation host mismatch refused; no active profile'
    return
}
$r=Connect-WizardInvite $root $request
if(-not $r.ok){throw 'Enrollment failed'}
$p=Read-TransportJson $r.profile
if($p.arguments -notcontains 'StrictHostKeyChecking=yes'){throw 'Missing strict pinning'}
if(Test-Path (Join-Path $root 'secrets/invite-pass')){throw 'Pass was not removed'}
if((Invoke-WizardSsh $root 'printf own-key-ok').Trim() -cne 'own-key-ok'){throw 'Own-key login failed'}
# Same invitation, own key already registered: retry after lost reply must not enroll twice.
$r=Connect-WizardInvite $root $request
if(-not $r.ok){throw 'Lost-reply recovery failed'}
if((Get-TransportServerPort $p) -ne [int](Read-TransportJson $InvitePath).serverPort){throw 'SSH port lost by transport'}
$transportArgs=@(Get-TransportSshArguments $p (Get-TransportServerPort $p))
if($Relay -and -not @($transportArgs|Where-Object {$_ -like 'ProxyCommand=*--proxy-connect*'}).Count){throw 'Bootstrap route lost by transport'}
if($Relay){
    $progress=[IO.File]::ReadAllText($script:WizardProgressFile)
    if($progress -notlike '*напрямую*' -or $progress -notlike '*локальный прокси*'){throw 'Route fallback not exercised'}
    if(-not @($p.arguments|Where-Object {$_ -like 'ProxyCommand=*'}).Count){throw 'Selected route not retained for own-key SSH'}
}
Write-Host ('PASS: invitation -> real SSH enrollment -> own-key login; strict pinning; pass removed; retry resumes'+$(if($Relay){'; direct failure -> next route'}else{'; SSH key hop'}))
