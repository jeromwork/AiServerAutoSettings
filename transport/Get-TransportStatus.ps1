#requires -Version 5.1
[CmdletBinding()]
param([Alias('Home')][string]$TransportHome=(Join-Path $env:LOCALAPPDATA 'RemoteAgents'))
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
try{
    $s=Read-TransportJson (Join-Path $TransportHome 'status/transport.json');$age=([DateTime]::UtcNow-(Convert-TransportUtc $s.updatedAt)).TotalSeconds
    $health='нет проверенного соединения';if($s.ok -and $age -ge -5 -and $age -le 15){$health='соединение проверено'}
    if($age -gt 15 -or $age -lt -5){$health='статус устарел, демон не отвечает'}
    $cost='неизвестна';if($s.metered -eq $true){$cost='лимитная'}elseif($s.metered -eq $false){$cost='без лимита'}
    $speed='не измерена';if($null -ne $s.kbps){$speed=([string]$s.kbps+' КБ/с')}
    Write-Output ('Транспорт: '+$health+'. Путь: '+$s.active+'. Скорость: '+$speed+'. Сеть: '+$cost+'.')
    if($s.error){Write-Output $s.error}
    foreach($c in @($s.candidates)){$v='—';if($null -ne $c.kbps){$v=[string]$c.kbps};Write-Output ('  '+$c.title+' ['+$c.tag+']: '+$c.state+'; '+$v+' КБ/с')}
}catch{Write-Output 'Статус транспорта ещё не записан или недоступен.';exit 1}
