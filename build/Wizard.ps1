#requires -Version 5.1
[CmdletBinding()]
param([Alias('Home')][string]$LauncherHome,[ValidateSet('Server','Catalog','Connection','DiskTree','Disk','AccountList','Account','Bridge','Vpn','Inspect','Activate','RollbackNetwork')][string]$Action,[string]$RequestFile,[string]$Session)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Wizard.Common.ps1')
$root=Get-TransportHome $LauncherHome;$bundle=Split-Path $PSScriptRoot -Parent
if($root -ine (Get-TransportHome (Join-Path $env:LOCALAPPDATA 'RemoteAgents'))){throw 'Настройка компьютера разрешена только в основном Home'}
try{
    if($Action -eq 'RollbackNetwork'){Undo-WizardNetwork $root $Session;return}
    $request=[pscustomobject]@{};if($RequestFile){$request=Read-TransportJson $RequestFile}
    Write-MigrationLog $root ('wizard.'+$Action+'.start')
    $result=Invoke-WizardStep $root $bundle $Action $request
    Write-MigrationLog $root ('wizard.'+$Action+'.complete')
    @{ok=$true;result=$result}|ConvertTo-Json -Depth 40 -Compress
}catch{
    Write-MigrationLog $root ('wizard.'+$Action+'.failed')
    $detail=Protect-TransportText ([string]$_.Exception.Message)
    @{ok=$false;reason=$detail;remedy='Проверьте SSH, состояние служб и журнал соответствующего шага; повторите проверку. Секреты в журнал не копируйте.'}|ConvertTo-Json -Compress
    exit 1
}
