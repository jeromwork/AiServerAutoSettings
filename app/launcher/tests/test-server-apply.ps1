#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Wizard.Common.ps1')
if(-not $TestHome){$TestHome=Join-Path ([IO.Path]::GetTempPath()) ('ra-apply-'+[guid]::NewGuid().ToString('N'))}
$count=0
function Assert($Value,[string]$Message){if(-not $Value){throw ('FAIL: '+$Message)};$script:count++}
$script:calls=@();$script:probes=0;$script:scenario='change'
function Invoke-WizardApplyCommand([string]$Root,[string]$Bundle,$Request,[string]$Mode,[string]$Command,[string]$Payload,[bool]$Confirm=$false){
    $script:calls+=@([pscustomobject]@{command=$Command;confirm=$Confirm})
    if($script:scenario -eq 'ready'){return [pscustomobject]@{ok=$true;parts=@(@{part='internet';state='ready';summary='готово'});actions=@()}}
    if($Command -in @('status','plan')){return [pscustomobject]@{ok=$false;parts=@(@{part='internet';state='change';summary='нужно включить'});actions=@()}}
    $applies=@($script:calls|Where-Object {$_.command -eq 'apply'}).Count
    if($applies -lt 3){return [pscustomobject]@{ok=$false;parts=@(@{part=$(if($applies -eq 1){'internet'}else{'lan:clinic'});state='pending';summary='нужно новое SSH'});actions=@('изменение-'+$applies)}}
    return [pscustomobject]@{ok=$true;parts=@(@{part='internet';state='ready';summary='готово'});actions=@('confirm')}}
function Test-WizardApplyPorts($Config){$script:probes++;if($script:scenario -eq 'broken'){throw 'fixture port blocked'}}
$request=[pscustomobject]@{config=[pscustomobject]@{kind='remoteagents-config';schema=1;server=[pscustomobject]@{address='test.invalid'}};statusOnly=$false}
$payload="{}`r`n---remoteagents-stdin---`r`n{}`r`n"
Assert ((@(Get-WizardApplyPorts $request.config) -join ',') -eq '22') 'existing server without serverNetwork only probes SSH, never port zero'
$r=Invoke-WizardServerApplyPayload $TestHome $repo $request 'profile' $payload
Assert $r.ok 'all network transactions complete'
Assert (($script:calls.command -join ',') -eq 'plan,apply,apply,apply') 'one plan and one call per transaction'
Assert (-not $script:calls[1].confirm -and $script:calls[2].confirm -and $script:calls[3].confirm) 'first activation has no premature SSH attestation'
Assert ($script:probes -eq 2) 'fresh connection check after EACH pending transaction'
Assert (@($r.actions).Count -eq 3) 'actions from all rounds remain reviewable'
$script:calls=@();$script:scenario='ready';$script:probes=0
$r=Invoke-WizardServerApplyPayload $TestHome $repo $request 'profile' $payload
Assert ($r.ok -and $script:calls.Count -eq 1 -and $script:calls[0].command -eq 'plan' -and @($r.actions).Count -eq 0) 'unchanged apply has no mutation'
$script:calls=@();$script:scenario='change';$request.statusOnly=$true
$r=Invoke-WizardServerApplyPayload $TestHome $repo $request 'profile' $payload
Assert ($script:calls.Count -eq 1 -and $script:calls[0].command -eq 'status') 'startup observation only runs status'
$script:calls=@();$script:scenario='broken';$request.statusOnly=$false;$failed=$false
try{Invoke-WizardServerApplyPayload $TestHome $repo $request 'profile' $payload|Out-Null}catch{$failed=$true}
Assert ($failed -and $script:calls.Count -eq 2 -and -not $script:calls[1].confirm) 'failed new connection leaves rollback armed'
# Staging carries the schema and dependencies needed after the temporary checkout disappears.
$bootstrap=Get-WizardBootstrapScript $repo 'http://fixture:PROXY_TEST_SENTINEL@proxy.invalid:3128'
Assert ($bootstrap.Contains('export ra_download_proxy') -and -not $bootstrap.Contains('PROXY_TEST_SENTINEL')) 'bootstrap proxy travels only encoded in SSH stdin'
Assert (-not $bootstrap.Contains("`r")) 'bootstrap script uses LF'
$files=Get-WizardApplyFiles $repo
Assert ($files.Contains('base_network.py') -and $files.Contains('lan-config.schema.json') -and $files.Contains('tg-gateway/gateway.py') -and $files.Contains('config.paste.schema.json')) 'complete root payload'
# Key-based clean-VPS bootstrap runs the same apt work as password bootstrap.
# Model a healthy 90s bootstrap without sleeping or contacting any server.
function Get-WizardKeyCandidates {param($Root,$Own,$Chosen) 'fixture-root-key'}
$script:keyBootstrapTimeout=0
function Invoke-WizardLogin {param($Profile,$User,$Command,$InputText='', $Credential=$null,[int]$Timeout=45)
    $script:keyBootstrapTimeout=$Timeout
    if($Timeout -lt 90){throw 'fixture healthy bootstrap exceeds SSH timeout'}
    return ''
}
$keyProfile=[pscustomobject]@{keyPath='own-key'}
Assert (Connect-WizardExistingKey $TestHome $keyProfile 'root' 'bootstrap' 'fixture-stdin' '') 'existing root key supports slow clean-VPS dependency bootstrap'
Assert ($script:keyBootstrapTimeout -eq 600) 'key and password bootstrap share the 600s budget'
Write-Host ('PASS: server-apply engine '+$count+' checks')
