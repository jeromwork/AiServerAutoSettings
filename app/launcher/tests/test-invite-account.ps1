#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Wizard.Common.ps1')
$env:LOCALAPPDATA=$TestHome
$root=Join-Path $TestHome 'RemoteAgents';[void][IO.Directory]::CreateDirectory($root)
Write-TransportJson (Join-Path $root 'config.json') @{schema=1;version=1;transport=@{};components=@{}}
$count=0
function Assert($Value,[string]$Name){if(-not $Value){throw ('FAIL: '+$Name)};$script:count++}
function Throws([scriptblock]$Body,[string]$Name){$failed=$false;try{& $Body|Out-Null}catch{$failed=$true};Assert $failed $Name}
$row=[pscustomobject]@{account=('a'*64);label='Текущий';serverUrl='https://api.example.invalid';webappUrl='https://web.example.invalid'}
$script:rows=@($row);$script:health=$true;$script:newCalls=0
function Invoke-WizardStep($Root,$Bundle,$Action,$Request){if($Action -ne 'AccountList'){throw 'Unexpected action'};return @{accounts=$script:rows}}
function Invoke-WizardSsh($Root,$Command,$InputText){$q=ConvertFrom-Json $InputText;if($q.action -ne 'inspect' -or $q.account -cne ('a'*64)){throw 'Unexpected account probe'};return ('{"ok":'+$script:health.ToString().ToLower()+'}'+"`r`n")}
function Invoke-WizardAccount($Root,$Bundle,$Request,$Explicit){$script:newCalls++;$script:newRequest=$Request;return @{ok=$true}}
$r=Connect-WizardInviteAccount $root $repo ([pscustomobject]@{mode='same'})
Assert $r.ok 'same account requires live server probe'
Assert ($script:newCalls -eq 0) 'same account does not create or reconnect a server daemon'
Assert ((Read-TransportJson (Join-Path $root 'state/happier-account.json')).account -ceq $row.account) 'public account identity saved'
Assert (-not (Test-Path (Join-Path $root 'secrets/happier-account.key'))) 'same account requires no recovery secret'
$script:health=$false
Throws {Connect-WizardInviteAccount $root $repo ([pscustomobject]@{mode='same'})} 'offline Happier is not reported as success'
$script:health=$true;$script:rows=@($row,[pscustomobject]@{account=('b'*64)})
Throws {Connect-WizardInviteAccount $root $repo ([pscustomobject]@{mode='same'})} 'ambiguous server account refused'
$r=Connect-WizardInviteAccount $root $repo ([pscustomobject]@{mode='same';account=$row.account})
Assert $r.ok 'configured public account id selects same account'
$r=Connect-WizardInviteAccount $root $repo ([pscustomobject]@{mode='new:Новый';account=$row.account})
Assert ($r.ok -and $script:newCalls -eq 1 -and $script:newRequest.label -ceq 'Новый') 'new mode uses existing account workflow'
Assert ($script:newRequest.serverUrl -ceq $row.serverUrl -and $script:newRequest.webappUrl -ceq $row.webappUrl) 'Happier URLs are obtained from server metadata'
Write-Host ('OK: '+$count+' invitation Happier checks (fake SSH; no live accounts)')
