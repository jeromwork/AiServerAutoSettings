#requires -Version 5.1
# CLI entry to the same engine as the EXE. Payload format is server-apply stdin.
param([Parameter(Mandatory=$true)][string]$HomePath,[string]$Bundle=(Split-Path $PSScriptRoot -Parent),[switch]$StatusOnly)
$ErrorActionPreference='Stop';$env:REMOTEAGENTS_WIZARD_SESSION='0'
. (Join-Path $PSScriptRoot 'Wizard.Common.ps1')
try{
    $payload=Convert-TransportLF ([Console]::In.ReadToEnd())
    $config=($payload -split ('(?m)^'+[regex]::Escape($script:WizardNetMarker)+'$'),2)[0]|ConvertFrom-Json
    $request=[pscustomobject]@{config=$config;statusOnly=[bool]$StatusOnly}
    $mode=Get-WizardApplyMode $HomePath $request
    if($mode -eq 'command'){throw 'Нет root/sudo; используйте EXE с server.rootPassword'}
    $result=Invoke-WizardResourceLock $HomePath 'server-network' {Invoke-WizardServerApplyPayload $HomePath $Bundle $request $mode $payload}
    $result|ConvertTo-Json -Depth 80 -Compress
    if(-not $result.ok){exit 1}
}catch{
    @{ok=$false;error='Применение не завершено. Проверьте SSH, входящие порты и состояние таймера отката.'}|ConvertTo-Json -Compress
    exit 1
}
