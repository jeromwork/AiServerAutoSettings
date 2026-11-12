#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Wizard.Common.ps1')
$env:LOCALAPPDATA=$TestHome;$root=Join-Path $TestHome 'RemoteAgents';[void][IO.Directory]::CreateDirectory($root)
$oldOS=$env:OS;$env:OS='Windows_NT'
$count=0
function Assert($OK,$Why){if(-not $OK){throw $Why};$script:count++}
$task='RemoteAgents config sync '+(Get-TransportFingerprint 'sync' $root.ToLowerInvariant()).Substring(0,16)
$script:tasks=@{};$script:tasks[$task]=@{enabled=$true;running=$true}
$foreign=$task+'-foreign';$script:tasks[$foreign]=@{enabled=$true;running=$true}
$script:calls=@()
$runtime=Join-Path $root ('state/config-sync/'+('a'*24))
$script:processes=@(
    [pscustomobject]@{ProcessId=1000001;CommandLine=('wscript.exe //B //Nologo "'+(Join-Path $runtime 'config-sync-hidden.vbs')+'"')},
    [pscustomobject]@{ProcessId=1000002;CommandLine=('powershell.exe "-File" "'+(Join-Path $runtime 'build/Wizard.ps1')+'" "-Home" "'+$root+'" "-Action" "ConfigSync"')},
    [pscustomobject]@{ProcessId=1000003;CommandLine=('powershell.exe -File "'+(Join-Path ($root+'-other') ('state/config-sync/'+('a'*24)+'/build/Wizard.ps1'))+'"')},
    [pscustomobject]@{ProcessId=1000004;CommandLine=('powershell.exe -File "'+(Join-Path $root 'build/Wizard.ps1')+'" -Action ConfigSync')})
$script:trees=@()
function Get-CimInstance($ClassName,$Filter,$ErrorAction){return $script:processes}
function Stop-LegacyConfigSyncProcessTree($Process){
    Assert (-not $script:tasks.ContainsKey($task) -or -not $script:tasks[$task].enabled) 'disable task before killing worker trees'
    $script:calls+='tree';$script:trees+=@($Process.ProcessId)
    $script:processes=@($script:processes|Where-Object {$_.ProcessId -ne $Process.ProcessId})
}
function Get-TaskState($Name){return @{exists=$script:tasks.ContainsKey($Name)}}
function Register-ScheduledTask {throw 'ConfigSync must never register a task'}
function Disable-ScheduledTask($TaskName,$ErrorAction){$script:calls+='disable';$script:tasks[$TaskName].enabled=$false}
function Stop-ScheduledTask($TaskName,$ErrorAction){
    Assert (-not $script:tasks[$TaskName].enabled) 'disable before stopping to prevent a new scheduled instance'
    $script:calls+='stop';$script:tasks[$TaskName].running=$false
}
function Unregister-ScheduledTask($TaskName,$Confirm,$ErrorAction){
    Assert (-not $script:tasks[$TaskName].running) 'active legacy instance is stopped before deletion'
    $script:calls+='unregister';$script:tasks.Remove($TaskName)
}
try{
    $result=Invoke-WizardStep $root $repo 'RetireConfigSync' ([pscustomobject]@{})
    Assert $result.ok 'launcher migration dispatch succeeds'
    Assert (-not $script:tasks.ContainsKey($task)) 'legacy task removed'
    Assert ($script:tasks[$foreign].enabled -and $script:tasks[$foreign].running) 'other Home task left alone'
    Assert (($script:calls -join ',') -eq 'disable,tree,tree,stop,unregister') 'retirement ordered correctly'
    Assert (($script:trees -join ',') -eq '1000001,1000002') 'whole legacy worker trees selected; foreign and launcher workers untouched'
    [void](Invoke-WizardStep $root $repo 'RetireConfigSync' ([pscustomobject]@{}))
    Assert ($script:calls.Count -eq 5) 'migration is idempotent when task is absent'
    Assert (-not (Test-Path (Join-Path $root 'state/config-sync'))) 'no independent runtime or schedule created'
    $script:processes=@([pscustomobject]@{ProcessId=1000005;CommandLine=('wscript.exe //B "'+(Join-Path $runtime 'config-sync-hidden.vbs')+'"')})
    Remove-LegacyConfigSyncTask $root
    Assert ($script:trees[-1] -eq 1000005) 'orphan legacy worker is stopped even after task deletion'
    $script:tasks[$task]=@{enabled=$true;running=$true}
    function Stop-ScheduledTask {throw 'injected scheduler failure'}
    $failed=$false;try{Remove-LegacyConfigSyncTask $root}catch{$failed=$true}
    Assert ($failed -and $script:tasks.ContainsKey($task)) 'stop failure is reported, not hidden by unregistering'
}finally{$env:OS=$oldOS}
Write-Output ('OK: '+$count+' config scheduler retirement checks (Windows Task Scheduler adapters stubbed)')
