#requires -Version 5.1
[CmdletBinding()]
param([Alias('Home')][string]$LauncherHome,[ValidateSet('Server','Lan','Skip','Catalog','Connection','DiskTree','Disk','AccountList','Account','ResumeAccount','Operation','Bridge','Vpn','Inspect','Activate','RollbackNetwork','RollbackBridge')][string]$Action,[string]$RequestFile,[string]$Session,[string]$ProgressFile)
$ErrorActionPreference='Stop'
# Machine-readable JSON must preserve filenames on non-Russian Windows too.
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$wizardRootInput=$LauncherHome;$wizardProgressInput=$ProgressFile
. (Join-Path $PSScriptRoot 'Wizard.Common.ps1')
# FirstInstall's library parameters share dot-source scope; retain our CLI input.
$script:WizardProgressFile=$wizardProgressInput
$env:REMOTEAGENTS_WIZARD_PROGRESS=$wizardProgressInput
$root=Get-TransportHome $wizardRootInput;$bundle=Split-Path $PSScriptRoot -Parent
if($root -ine (Get-TransportHome (Join-Path $env:LOCALAPPDATA 'RemoteAgents'))){throw 'Настройка компьютера разрешена только в основном Home'}
try{
    if($Action -eq 'RollbackNetwork'){Invoke-WizardLock $root {Undo-WizardNetwork $root $Session} -TimeoutMs 30000;return}
    if($Action -eq 'RollbackBridge'){Invoke-WizardLock $root {Undo-WizardBridge $root $Session} -TimeoutMs 30000;return}
    $request=[pscustomobject]@{};if($RequestFile){$request=Read-TransportJson $RequestFile}
    Write-MigrationLog $root ('wizard.'+$Action+'.start')
    # Status polling of detached server installs is read-only: it never waits for a running step.
    if($Action -eq 'Operation'){$result=Invoke-WizardStep $root $bundle $Action $request}
    else{$result=Invoke-WizardLock $root {Invoke-WizardStep $root $bundle $Action $request}}
    Write-MigrationLog $root ('wizard.'+$Action+'.complete')
    @{ok=$true;result=$result}|ConvertTo-Json -Depth 40 -Compress
}catch{
    Write-MigrationLog $root ('wizard.'+$Action+'.failed')
    $detail=Protect-TransportText ([string]$_.Exception.Message)
    @{ok=$false;reason=$detail;remedy='Проверьте SSH, состояние служб и журнал соответствующего шага; повторите проверку. Секреты в журнал не копируйте.'}|ConvertTo-Json -Compress
    exit 1
}
