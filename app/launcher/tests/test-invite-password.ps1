#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Wizard.Common.ps1')
$env:LOCALAPPDATA=$TestHome;$env:USERPROFILE=Join-Path $TestHome 'user'
$root=Join-Path $TestHome 'RemoteAgents';[void][IO.Directory]::CreateDirectory($root)
Write-TransportJson (Join-Path $root 'config.json') @{schema=1;version=1;transport=@{}}
$helper=Join-Path $root 'RemoteAgents.exe';Write-DiskUtf8 $helper 'fixture'
$path=Join-Path $root 'invite.json'
$pin='ssh-ed25519 Zml4dHVyZQ=='
Write-TransportJson $path @{schema=1;id=('a'*32);serverAddress='server.invalid';serverPort=22;workerUser='worker';enrollUser='enroll';hostKeys=@($pin);expiresUtc='2099-01-01T00:00:00Z';passKey='unused';routes=@(
    @{kind='hop';hop=@{ssh='first@hop-one.invalid:2201';hostKey=$pin;password='first-secret'}},
    @{kind='hop';hop=@{ssh='second@hop-two.invalid:2202';hostKey=$pin;password='second-secret'}})}
$script:checks=0
function Assert($OK,$Why){if(-not $OK){throw $Why};$script:checks++}
function Select-WizardRoute($Profile,$Worker,$Routes){
    Assert ($Routes.Count -eq 2) 'both password routes participate without a request password pipe'
    for($n=0;$n -lt 2;$n++){
        $route=$Routes[$n];$file=[string]$route.request.hop.invitePasswordFile
        Assert (Test-Path $file) 'each route has a private durable password relay configuration'
        $settings=Read-TransportJson $file
        Assert ($settings.password -ceq @('first-secret','second-secret')[$n]) 'each route keeps its own password'
        Assert ($route.options[1] -like '*--invite-hop*' -and $route.options[1] -notlike '*-secret*') 'only a file path appears in SSH arguments'
        Assert (([IO.File]::ReadAllText($settings.knownHostsPath)) -like ('*'+$settings.host+'*')) 'each hop has its own pins'
        if($env:OS -ne 'Windows_NT'){Assert (([IO.File]::GetUnixFileMode($file) -band 63) -eq 0) 'password settings are private'}
    }
    $script:WizardRoute=$Routes[1]
}
function Invoke-WizardLogin($Profile,$User,$Command,$InputText=''){
    Assert ($User -eq 'worker' -and $Command -eq 'true') 'route probes use the device key, never the enrollment pass'
    return ''
}
function Get-TransportHostKeys($Ssh,$HostName,$KnownHosts){return $pin}
$result=Connect-WizardInvite $root ([pscustomobject]@{path=$path;askpassExecutable=$helper})
Assert $result.ok 'password-only invitation can connect without a pre-existing named pipe (automatic refresh)'
$p=Read-TransportJson $result.profile
Assert ($p.inviteProxyCommand -like '*--invite-hop*') 'selected durable relay survives enrollment'
$route=(Read-TransportJson (Join-Path $root 'config.json')).wizard.serverRoute
Assert (-not $route.hop.password -and -not $route.hop.passwordPipe) 'saved route contains no password or stale pipe'
Write-Host ('PASS: '+$script:checks+' password-route checks (SSH/probes stubbed; no Windows)')
