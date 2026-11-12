#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Wizard.Common.ps1')
$env:LOCALAPPDATA=$TestHome
$root=Join-Path $TestHome 'RemoteAgents';[void][IO.Directory]::CreateDirectory($root)
$hostId=Get-WizardHostId $root
if((Get-WizardHostId $root) -cne $hostId){throw 'host ID must survive repeated setup'}
$other=Join-Path $TestHome 'other';[void][IO.Directory]::CreateDirectory($other)
if((Get-WizardHostId $other) -ceq $hostId){throw 'different computer state must have its own ID'}
$profile=Join-Path $root ('ssh-profiles/fixture/project-connections/'+$hostId+'/ssh-transport.json')
Write-TransportJson $profile @{fixture=$true}
Write-TransportJson (Join-Path $root 'config.json') @{schema=1;transport=@{profilePath=$profile};bridge=@{enabled=$true;allowShell=$false};components=@{}}
$remote=Join-Path $TestHome 'remote'
$lib=Join-Path $remote '.local/share/codex-remote';[void][IO.Directory]::CreateDirectory($lib)
Copy-Item -LiteralPath (Join-Path $repo 'server_node_catalog.py') -Destination (Join-Path $lib 'server_node_catalog.py')
$record=Join-Path $remote ('.local/share/remote-agents-nodes/'+$hostId+'/control.json')
$label='win-'+('a'*28)
Write-TransportJson $record @{projectId='control';hostId=$hostId;deviceLabel=$label;deviceName='fixture';socketPath=(Join-Path $remote ('.local/state/codex-remote/'+$label+'.sock'));serverWorkspace=(Join-Path $remote 'work/projects/control');windowsReplica='C:\Users\fixture\workspace';allowShell=$false;controlOnly=$true}
function Invoke-WizardSsh($Root,$Command,$InputText='',$Timeout=60){
    Invoke-DiskProcess '/usr/bin/env' @(('HOME='+$remote),'bash','-c',$Command) (Convert-TransportLF $InputText) -TimeoutSeconds 10
}
function Test-WizardBridge($Root){$true}
$name='Ноутбук сына'
$r=Invoke-WizardStep $root $repo 'Bridge' ([pscustomobject]@{enabled=$true;shell=$false;deviceName=$name})
if(-not $r.ok -or (Read-TransportJson $record).deviceName -cne $name){throw 'deviceName did not reach real server registry'}
if((Read-TransportJson (Join-Path $root 'config.json')).profile.device.name -cne $name){throw 'deviceName not persisted'}
if(-not (Read-TransportJson $record).controlOnly -or (Read-TransportJson $record).allowShell){throw 'rename must preserve permissions and binding'}
$failed=$false;try{Set-WizardBridge $root $repo $true $false "bad`r`nname"}catch{$failed=$true}
if(-not $failed -or (Read-TransportJson $record).deviceName -cne $name){throw 'invalid name changed registry'}
Write-Output 'OK: persistent device identity, Bridge deviceName -> real registry, unchanged shell policy, invalid name refusal (SSH/bridge health stubbed)'
