#requires -Version 5.1
[CmdletBinding()]
param([Alias('Home')][string]$LauncherHome,[ValidateSet('InviteRefresh','InviteSync','InvitePrepare','InviteVerify','InviteDisk','InviteEnroll','InviteAccount','Server','Lan','LanRemove','NetStatus','AdminProbe','Proxy','Skip','Catalog','Connection','DiskTree','Disk','AccountList','Account','ResumeAccount','Operation','Bridge','Vpn','Inspect','Activate','RollbackNetwork','RollbackBridge')][string]$Action,[string]$RequestFile,[string]$Session,[string]$ProgressFile)
$ErrorActionPreference='Stop'
# Machine-readable JSON must preserve filenames on non-Russian Windows too.
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$wizardRootInput=$LauncherHome;$wizardProgressInput=$ProgressFile
. (Join-Path $PSScriptRoot 'Wizard.Common.ps1')
# Dot-sourced libraries share this scope; retain our CLI input.
$script:WizardProgressFile=$wizardProgressInput
$env:REMOTEAGENTS_WIZARD_PROGRESS=$wizardProgressInput
$root=Get-TransportHome $wizardRootInput;$bundle=Split-Path $PSScriptRoot -Parent
if($root -ine (Get-TransportHome (Join-Path $env:LOCALAPPDATA 'RemoteAgents'))){throw 'Настройка компьютера разрешена только в основном Home'}
try{
    if($Action -eq 'RollbackNetwork'){Invoke-WizardAction $root $Action $null {Undo-WizardNetwork $root $Session};return}
    if($Action -eq 'RollbackBridge'){Invoke-WizardAction $root $Action $null {Undo-WizardBridge $root $Session};return}
    $request=[pscustomobject]@{};if($RequestFile){$request=Read-TransportJson $RequestFile}
    Write-SetupLog $root ('wizard.'+$Action+'.start')
    $result=Invoke-WizardAction $root $Action $request {Invoke-WizardStep $root $bundle $Action $request}
    Write-SetupLog $root ('wizard.'+$Action+'.complete')
    @{ok=$true;result=$result}|ConvertTo-Json -Depth 40 -Compress
}catch{
    Write-SetupLog $root ('wizard.'+$Action+'.failed')
    $detail=Protect-TransportText ([string]$_.Exception.Message)
    @{ok=$false;reason=$detail;remedy='Проверьте SSH, состояние служб и журнал соответствующего шага; повторите проверку. Секреты в журнал не копируйте.'}|ConvertTo-Json -Compress
    exit 1
}
