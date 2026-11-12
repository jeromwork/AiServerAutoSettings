#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Wizard.Common.ps1')
$env:LOCALAPPDATA=$TestHome;$env:USERPROFILE=Join-Path $TestHome 'user'
$root=Join-Path $TestHome 'RemoteAgents';[void][IO.Directory]::CreateDirectory($root)
Write-TransportJson (Join-Path $root 'config.json') @{schema=1;version=1;transport=@{}}
$helper=Join-Path $root 'RemoteAgents.exe';Write-DiskUtf8 $helper 'fixture'
$path=Join-Path $root 'settings.json'
$pin='ssh-ed25519 Zml4dHVyZQ=='
Write-TransportJson $path @{schema=1;serverAddress='server.invalid';serverPort=22;workerUser='worker';hostKeys=@($pin);routes=@(
    @{kind='hop';hop=@{ssh='first@hop-one.invalid:2201';hostKey=$pin;password='first-secret'}},
    @{kind='hop';hop=@{ssh='second@hop-two.invalid:2202';hostKey=$pin;password='second-secret'}})}
$script:checks=0
function Assert($OK,$Why){if(-not $OK){throw $Why};$script:checks++}
function Select-WizardRoute($Profile,$Worker,$Routes){
    Assert ($Routes.Count -eq 2) 'both password routes participate without a request password pipe'
    for($n=0;$n -lt 2;$n++){
        $route=$Routes[$n];$file=[string]$route.request.hop.routePasswordFile
        Assert (Test-Path $file) 'each route has a private durable password relay configuration'
        $settings=Read-TransportJson $file
        Assert ($settings.password -ceq @('first-secret','second-secret')[$n]) 'each route keeps its own password'
        Assert ($route.options[1] -like '*Route.Proxy-*' -and $route.options[1] -notlike '*-secret*') 'only a file path appears in SSH arguments'
        Assert (([IO.File]::ReadAllText($settings.knownHostsPath)) -like ('*'+$settings.host+'*')) 'each hop has its own pins'
        if($env:OS -ne 'Windows_NT'){Assert (([IO.File]::GetUnixFileMode($file) -band 63) -eq 0) 'password settings are private'}
    }
    $script:WizardRoute=$Routes[1]
}
function Invoke-WizardLogin($Profile,$User,$Command,$InputText=''){
    Assert ($User -eq 'worker' -and $Command -eq 'true') 'route probes use the device key, only the existing config key'
    return ''
}
function Get-TransportHostKeys($Ssh,$HostName,$KnownHosts){return $pin}
$key=Join-Path $root 'key';Write-DiskUtf8 $key 'fixture-key-never-used-by-stub'
$result=Connect-WizardSnapshot $root ([pscustomobject]@{path=$path;keyPath=$key;askpassExecutable=$helper})
Assert $result.ok 'password-only config can connect without a pre-existing named pipe (automatic refresh)'
$p=Read-TransportJson $result.profile
Assert ($p.routeProxyCommand -like '*Route.Proxy-*') 'selected durable relay survives reconnect'
$route=(Read-TransportJson (Join-Path $root 'config.json')).wizard.serverRoute
Assert (-not $route.hop.password -and -not $route.hop.passwordPipe) 'saved route contains no password or stale pipe'
Assert ((Read-TransportJson $result.profile).keyPath -ceq $key) 'issued key is used without replacement'
Assert (@(Get-ChildItem (Join-Path $root 'ssh-profiles') -Recurse -Filter id_ed25519).Count -eq 0) 'config login generates no extra authorized key'
$settings=Read-TransportJson $path
$routes=Copy-TransportObject $settings.routes
for($n=0;$n -lt 2;$n++){
    $h=$routes[$n].hop
    $h.PSObject.Properties.Remove('ssh');$h.PSObject.Properties.Remove('password')
    $h|Add-Member host @('hop-one.invalid','hop-two.invalid')[$n]
    $h|Add-Member user @('first','second')[$n]
    $h|Add-Member port (2201+$n)
    $h|Add-Member routePasswordFile (Join-Path $root ('secrets/config-hop-'+($n+1)+'.json'))
}
Update-LauncherConfig $root {param($c) $c|Add-Member -Force profile ([pscustomobject]@{server=[pscustomobject]@{address='server.invalid';port=22;login='worker';hostKeys=@($pin);keyFile=$key;key=[pscustomobject]@{secret='server-key'};routes=$routes}})}
$file=Connect-WizardProfileServer $root ([pscustomobject]@{askpassExecutable=$helper})
Assert ((Read-TransportJson $file).keyPath -ceq $key) 'public config host/user/port route form uses the same materialized key'
Update-LauncherConfig $root {param($c) $c.profile.server.keyFile=Join-Path $Root 'missing-key'}
$failed=$false;try{Connect-WizardProfileServer $root ([pscustomobject]@{})|Out-Null}catch{$failed=$true}
Assert $failed 'missing issued key must not fall back to enrolling another key'
if($env:OS -ne 'Windows_NT'){
    # Resolve the generated inner ssh config with REAL ssh -G. A persisted
    # target ProxyCommand must not recursively apply to the jump server.
    $poison=Join-Path $root 'inherited-target.conf';Write-DiskUtf8 $poison "Host *`n ProxyCommand /bin/false`n"
    $pinned=[pscustomobject]@{sshExecutable='/usr/bin/ssh';configPath=$poison;knownHostsPath=(Join-Path $root 'known_hosts')}
    $jump=[pscustomobject]@{used='hop';hop=[pscustomobject]@{ssh='jumper@hop.invalid:2201';keyFile=$key;knownHostsPath=(Join-Path $root 'known_hosts-hop')}}
    $inner=@(New-TransportRouteOptions $jump $pinned $helper)[1].Substring(13).Replace(' -q ',' -G ').Replace('%h','target.invalid').Replace('%p','22')
    $effective=Invoke-DiskProcess '/bin/bash' @('-c',$inner) '' -TimeoutSeconds 10
    Assert ($effective -match '(?m)^hostname hop.invalid$') 'inner route is resolved by real OpenSSH'
    Assert ($effective -notmatch '(?m)^proxycommand .*false') 'inner hop does not inherit the target ProxyCommand'
}
Write-Host ('PASS: '+$script:checks+' password-route checks (SSH/probes stubbed; no Windows)')
