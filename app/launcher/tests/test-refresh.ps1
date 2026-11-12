#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Wizard.Common.ps1')
$env:LOCALAPPDATA=$TestHome
$root=Join-Path $TestHome 'RemoteAgents';[void][IO.Directory]::CreateDirectory($root)
$key=Join-Path $TestHome 'key';[void](Invoke-DiskProcess 'ssh-keygen' @('-q','-t','ed25519','-N','','-f',$key))
$pin=Get-WizardDeviceKey ([pscustomobject]@{sshExecutable='/usr/bin/ssh';keyPath=$key})
$profile=Join-Path $root 'ssh-profiles/fixture/project-connections/pc-fixture/profile.json';[void][IO.Directory]::CreateDirectory((Split-Path $profile -Parent));$known=Join-Path $root 'known_hosts'
Write-DiskUtf8 $known ('old.example.invalid '+$pin+"`r`n")
Write-TransportJson $profile @{sshExecutable='/usr/bin/ssh';serverAddress='old.example.invalid';login='worker';keyPath=$key;knownHostsPath=$known;configPath=(Join-Path $root 'ssh.conf');arguments=@('-p','22')}
$channel=Join-Path $root 'channel.json';Write-TransportJson $channel @{inbounds=@();outbounds=@()}
Write-TransportJson (Join-Path $root 'config.json') @{schema=1;version=1;transport=@{profilePath=$profile;channelPath=$channel;singBoxPath='fixture';entries=@();hops=@();relays=@();cdn=@()};wizard=@{configured=$true};bridge=@{enabled=$false;allowShell=$true};happier=@{label='kept'};disk=@{folders=@('Project')};vpn=@{enabled=$true;checkUrl='https://old.invalid/';dnsServer='192.0.2.1';excludeCidrs=@('192.0.2.0/24')}}
$catalog=[pscustomobject]@{schema=1;entries=@();hops=@();relays=@();cdn=@()}
$data=[pscustomobject]@{schema=1;type='settings';serverAddress='new.example.invalid';serverPort=2223;workerUser='worker';hostKeys=@($pin);routes=@([pscustomobject]@{kind='direct'});bootstrap=[pscustomobject]@{catalog=$catalog;channel=[pscustomobject]@{inbounds=@();outbounds=@()};entries=[pscustomobject]@{};hops=[pscustomobject]@{};vpn=[pscustomobject]@{checkUrl='https://new.invalid/';dnsServer='192.0.2.53'}}}
$count=0;$script:preflights=0;$script:armed=0;$script:failProof=$false
function Assert($OK,$Why){if(-not $OK){throw $Why};$script:count++}
function Throws($Body,$Why){$failed=$false;try{& $Body|Out-Null}catch{$failed=$true};Assert $failed $Why}
function Select-WizardRoute($Profile,$Worker,$Routes){$script:WizardRoute=$Routes[0]}
function Invoke-WizardLogin($Profile,$User,$Command,$InputText=''){
    Assert ($Profile.keyPath -ceq $key -and $User -eq 'worker' -and $Command -eq 'true') 'only own existing config key is used'
    return ''
}
function Invoke-TransportPreflight($Root,$Bundle,$Candidate){
    $script:preflights++
    $next=Read-TransportJson $Candidate.transport.profilePath
    Assert ($next.keyPath -ceq $key -and (Get-TransportServerPort $next) -eq 2223) 'candidate retains key and updated port'
    Assert ([IO.File]::ReadAllText($next.knownHostsPath).Contains($data.serverAddress)) 'new pins staged before publication'
}
function Register-WizardRollback($Root,$Bundle,$Kind,$Session,$Task){$script:armed++;Assert (Test-Path (Join-Path $Root 'state/wizard-network.json')) 'durable rollback receipt precedes publication'}
function Unregister-ScheduledTask {param($TaskName,[switch]$Confirm,[string]$ErrorAction)}
function Wait-WizardWorkingProof($Root,$Mark){if($script:failProof){throw 'fixture proof failed'}}
function Get-WizardConfigSettings($Root,$Command='',$InputText=''){
    if($Command -eq 'python3 -'){return (ConvertTo-Json $catalog -Depth 30)+"`r`n"}
    return (ConvertTo-Json $data -Depth 30)+"`r`n"
}
$before=[IO.File]::ReadAllText((Join-Path $root 'config.json'))
Throws {Update-WizardConfigSettings $root $repo ([pscustomobject]@{data=$data})} 'untrusted snapshot rejected'
Assert ($script:preflights -eq 0 -and $script:armed -eq 0 -and [IO.File]::ReadAllText((Join-Path $root 'config.json')) -ceq $before) 'untrusted input changes nothing'
$result=Sync-WizardConfigSettings $root $repo ([pscustomobject]@{})
Assert ($result.changed -and $script:armed -eq 1) 'authenticated snapshot commits after preflight and watchdog'
$c=Read-TransportJson (Join-Path $root 'config.json')
Assert ((Read-TransportJson $profile).serverAddress -eq 'new.example.invalid' -and (Read-TransportJson $profile).keyPath -eq $key) 'stable shared profile updated with same key'
Assert ($c.vpn.enabled -and $c.vpn.dnsServer -eq '192.0.2.53' -and $c.vpn.excludeCidrs[0] -eq '192.0.2.0/24') 'VPN choice and exclusions retained'
Assert ($c.disk.folders[0] -eq 'Project' -and $c.happier.label -eq 'kept' -and $c.bridge.allowShell) 'unrelated sections retained'
Assert (-not (Test-Path (Join-Path $root 'state/wizard-network.json'))) 'live proof disarms rollback'
$result=Sync-WizardConfigSettings $root $repo ([pscustomobject]@{})
Assert (-not $result.changed -and $script:preflights -eq 1) 'unchanged authenticated snapshot is idempotent'
$before=[IO.File]::ReadAllText((Join-Path $root 'config.json'));$previous=Read-TransportJson $profile
$script:failProof=$true;$data.serverAddress='failed.example.invalid'
Throws {Sync-WizardConfigSettings $root $repo ([pscustomobject]@{})} 'failed working proof causes rollback'
$c=Read-TransportJson (Join-Path $root 'config.json')
Assert ((Read-TransportJson $profile).serverAddress -ceq $previous.serverAddress -and $c.disk.folders[0] -eq 'Project') 'rollback restores prior profile and preserves folders'
Assert ((Get-WizardDeviceKey (Read-TransportJson $profile)) -ceq $pin) 'private config key survives update and rollback'
Assert (-not (Test-Path (Join-Path $root 'state/config-settings-version.json'))) 'failed snapshot is eligible for retry'
Write-Output ('OK: '+$count+' config sync/pins/key/rollback/CRLF checks (keygen real; SSH, TUN, scheduler stubbed)')
