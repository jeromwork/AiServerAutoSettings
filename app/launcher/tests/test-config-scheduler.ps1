#requires -Version 5.1
param([string]$TestHome)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repo 'build/Wizard.Common.ps1')
$env:LOCALAPPDATA=$TestHome;$root=Join-Path $TestHome 'RemoteAgents';[void][IO.Directory]::CreateDirectory($root)
function Test-WizardWindows {$true}
function Get-WizardInteractiveUser {'fixture-user'}
function New-ScheduledTaskAction {param($Execute,$Argument) return @{execute=$Execute;argument=$Argument}}
function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel) return @{user=$UserId;logon=$LogonType;level=$RunLevel}}
function New-ScheduledTaskTrigger {param([switch]$Once,$At,$RepetitionInterval,[switch]$AtLogOn,$User) return @{once=[bool]$Once;interval=$RepetitionInterval;logon=[bool]$AtLogOn}}
function New-ScheduledTaskSettingsSet {param([switch]$StartWhenAvailable,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,$MultipleInstances,$ExecutionTimeLimit) return @{multiple=$MultipleInstances;limit=$ExecutionTimeLimit}}
function Register-ScheduledTask {param($TaskName,$Action,$Trigger,$Principal,$Settings,[switch]$Force) $script:registered=@{name=$TaskName;action=$Action;triggers=$Trigger;principal=$Principal;settings=$Settings}}
function Get-TaskState($Name) {return @{exists=$true;enabled=$true}}
$count=0
function Assert($OK,$Why){if(-not $OK){throw $Why};$script:count++}
$result=Install-WizardConfigSync $root $repo
Assert ($result.supported -and $result.intervalSec -eq 300) 'five minute config sync enabled'
Assert ($script:registered.triggers[0].interval.TotalSeconds -eq 300 -and $script:registered.triggers[1].logon) 'recurring trigger and logon recovery'
Assert ($script:registered.principal.level -eq 'Limited' -and $script:registered.principal.logon -eq 'Interactive') 'same user without elevation'
Assert ($script:registered.settings.multiple -eq 'IgnoreNew' -and $script:registered.settings.limit.TotalMinutes -eq 4) 'sync does not queue or run indefinitely'
Assert ($script:registered.action.argument -like '*"-Action" "ConfigSync"*') 'task runs key-only ConfigSync'
$copy=@(Get-ChildItem -Path (Join-Path $root 'state/config-sync/*/build/Wizard.ps1'))[0]
Assert ($copy -and (Get-FileHash $copy.FullName).Hash -ceq (Get-FileHash (Join-Path $repo 'build/Wizard.ps1')).Hash) 'worker survives source bundle pruning'
$task=$script:registered.name
[void](Install-WizardConfigSync $root $repo)
Assert ($script:registered.name -ceq $task -and @(Get-ChildItem (Join-Path $root 'state/config-sync')).Count -eq 1) 'repeat registration reuses immutable runtime'
Write-Output ('OK: '+$count+' config scheduler checks (Windows Task Scheduler adapters stubbed)')
