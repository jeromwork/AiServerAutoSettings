# Восстанавливает сетевые адаптеры OpenVPN: создаёт свой Wintun и перезапускает TAP.
# Нужен, когда OpenVPN пишет "All wintun adapters on this system are currently in use".
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'))
    return
}
try {
    $tapctl = Join-Path $env:ProgramFiles 'OpenVPN\bin\tapctl.exe'
    if (-not (Test-Path -LiteralPath $tapctl)) { throw 'OpenVPN не установлен: нет ' + $tapctl }
    $name = 'OpenVPN Wintun'
    Get-Process openvpn -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host ('Останавливаю зависший openvpn.exe (PID ' + $_.Id + ')')
        Stop-Process -Id $_.Id -Force
    }
    $wintun = Get-NetAdapter -IncludeHidden -Name $name -ErrorAction SilentlyContinue
    $device = if ($wintun) { Get-PnpDevice -InstanceId $wintun.PnPDeviceID -ErrorAction SilentlyContinue }
    if ($wintun -and $device -and $device.Status -ne 'OK') {
        Write-Host ('Адаптер «' + $name + '» неисправен, пересоздаю')
        & $tapctl delete $wintun.InterfaceGuid | Out-Null
        $wintun = $null
    }
    if ($wintun) {
        Write-Host ('Адаптер «' + $name + '» на месте')
    } else {
        Write-Host ('Создаю адаптер «' + $name + '»')
        & $tapctl create --hwid wintun --name $name
        if ($LASTEXITCODE -ne 0) { throw 'tapctl не смог создать адаптер (код ' + $LASTEXITCODE + ')' }
    }
    Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -like 'TAP-Windows Adapter*' -and $_.Status -ne 'OK' } | ForEach-Object {
        Write-Host ('Перезапускаю ' + $_.FriendlyName)
        Disable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        Enable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
    }
    Write-Host ''
    Get-NetAdapter -IncludeHidden | Where-Object { $_.InterfaceDescription -match 'Wintun|TAP-Windows' -or $_.Name -eq $name } | Format-Table Name, Status, InterfaceDescription -AutoSize
    Write-Host 'Готово. Подключите OpenVPN заново.'
} catch {
    Write-Host ('Ошибка: ' + $_.Exception.Message) -ForegroundColor Red
}
Read-Host 'Enter — закрыть' | Out-Null
