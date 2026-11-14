#requires -Version 5.1
function New-DiskInstallFixture([string]$Root) {
    $bundle=Join-Path $Root 'bundle';$disk=Join-Path $bundle 'disk'
    [void][IO.Directory]::CreateDirectory($disk);[void][IO.Directory]::CreateDirectory((Join-Path $bundle 'transport'))
    foreach($name in @('Install-RemoteDisk.ps1','Disk.Common.ps1','Disk.NavPane.ps1','Disk.Binary.ps1','Disk.Engine.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $disk $name)}
    Write-DiskUtf8 (Join-Path $bundle 'transport/Transport.Common.ps1') 'function Get-TransportEffectivePort {22123}'
    return $bundle
}
function Add-DiskFixtureCode([string]$Bundle,[string]$Code) {
    [IO.File]::AppendAllText((Join-Path $Bundle 'disk/Disk.Common.ps1'),("`n"+$Code),(New-Object Text.UTF8Encoding($false)))
}
function Invoke-DiskFixture([string]$Bundle,$Arguments) {
    Invoke-DiskProcess ((Get-Process -Id $PID).Path) (@('-NoProfile','-NonInteractive','-File',(Join-Path $Bundle 'disk/Install-RemoteDisk.ps1'))+@($Arguments)) -TimeoutSeconds 75
}
