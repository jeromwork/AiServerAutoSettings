#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
function Assert($ok,$text){if(-not $ok){throw $text};Write-Host ('PASS: '+$text)}
$env:LOCALAPPDATA=Join-Path ([IO.Path]::GetTempPath()) 'ports-profile'
$exe=Join-Path $env:LOCALAPPDATA 'RemoteDisk/channel/sing-box.exe'
$snapshot=[pscustomobject]@{listeners=@([pscustomobject]@{address='127.0.0.1';port=2222;pid=42});processes=@([pscustomobject]@{ProcessId=42;ExecutablePath=$exe})}
$line="FATAL start inbound/direct[ssh]: listen tcp 127.0.0.1:2222: bind: Only one usage of each socket address`r`n"
$c=Get-TransportBindConflict $line $snapshot
Assert ($c.port -eq 2222 -and $c.pid -eq 42 -and $c.legacy -and $c.message.Contains($exe) -and $c.message.Contains('старая установка RemoteDisk')) 'Причина называет порт, путь, PID и старую установку'
$snapshot.processes[0].ExecutablePath=Join-Path $env:LOCALAPPDATA 'Other/app.exe'
$c=Get-TransportBindConflict 'listen tcp 127.0.0.1:2222: bind: address already in use' $snapshot
Assert (-not $c.legacy -and $c.message.Contains('Other')) 'Чужая программа не названа старой установкой'
$snapshot|Add-Member legacyActions @(@{exe=$snapshot.processes[0].ExecutablePath;arguments='run -c old.json'})
$snapshot.processes[0]|Add-Member CommandLine ('"'+$snapshot.processes[0].ExecutablePath+'" run -c old.json')
$c=Get-TransportBindConflict $line $snapshot
Assert ($c.legacy) 'Старая задача RemoteDiskChannel распознана по действию и команде процесса'
$snapshot.legacyActions=@()
Assert ($null -eq (Get-TransportBindConflict 'dial tcp: connection refused' $snapshot)) 'Сетевая ошибка не принята за bind'
Assert ($null -eq (Get-TransportBindConflict 'listen tcp 127.0.0.1:2222: bind: permission denied' $snapshot)) 'Запрет доступа не принят за занятый порт'
$script:fixtureSnapshot=$snapshot
function Get-TransportPortSnapshot {$script:fixtureSnapshot}
$child=[pscustomobject]@{Process=[pscustomobject]@{HasExited=$true;ExitCode=1};ErrorDrain=[Threading.Tasks.Task]::CompletedTask;ErrorBuffer=[pscustomobject]@{}}
$child.ErrorBuffer|Add-Member ScriptMethod Snapshot {$script:bindLine}
$script:bindLine="WARN a preceding message`r`n"+$line
$d=New-TransportDiagnostic $child 'sing-box' 'process-exited'
Assert ($d.reason -eq 'port-in-use' -and (Format-TransportDiagnostic $d).Contains('PID 42')) 'Диагностика stderr сохраняет понятную причину'
Assert ($c.message.Contains('Remove-OldInstall.cmd') -and $c.message.Contains('откройте RemoteAgents снова')) 'Для старой установки дано действие ручной очистки'
$retry=Get-TransportBindRetry $null $d
Assert ($retry.failures -eq 1) 'Первая ошибка bind начинает новую серию'
$retry=Get-TransportBindRetry $retry $d
Assert ($retry.failures -eq 2) 'Повтор одной ошибки bind увеличивает паузу'
$other=Copy-TransportObject $d;$other.portConflict.port=2223
$retry=Get-TransportBindRetry $retry $other
Assert ($retry.failures -eq 1) 'Другой порт сбрасывает серию bind'
$other.stderr+=' another bind error'
$retry=Get-TransportBindRetry $retry $other
Assert ($retry.failures -eq 1) 'Другая ошибка того же порта сбрасывает серию'
$retry=Get-TransportBindRetry $retry (New-TransportDiagnostic $null 'sing-box' 'engine-start-failed')
Assert ($null -eq $retry) 'Ошибка без bind сбрасывает серию'
Assert ($null -eq (Get-TransportBindRetry $d $null)) 'Успешный исход сбрасывает серию'
Assert ((Get-TransportRestartDelay 3 1) -eq 5 -and (Get-TransportRestartDelay 3 2) -eq 10 -and (Get-TransportRestartDelay 3 8) -eq 30 -and (Get-TransportRestartDelay 3 0) -eq 3 -and (Get-TransportRestartDelay 90 1) -eq 30 -and (Get-TransportRestartDelay 90 0) -eq 30) 'Пауза bind растёт с 5 до 30 секунд и всегда ограничена 30 с'

Assert ($c.message.Contains('другой программой')) 'Диагностика прямо говорит о другой программе'
$root=Join-Path ([IO.Path]::GetTempPath()) ('transport-ports-'+[guid]::NewGuid().ToString('N'))
$held=New-Object Collections.ArrayList
try{
    [void][IO.Directory]::CreateDirectory($root)
    $profile=[pscustomobject]@{arguments=@('-p','45022','-o','HostName=127.0.0.2','-o','HostName=127.0.0.20');configPath=(Join-Path $root 'ssh.conf')}
    $profileFile=Join-Path $root 'profile.json';Write-TransportJson $profileFile $profile
    $transport=[pscustomobject]@{profilePath=$profileFile;channelFirst=$true}
    $configFile=Join-Path $root 'config.json';Write-TransportJson $configFile @{transport=$transport}
    # JSON и SSH-конфиг приходят с Windows; проверяем CRLF и BOM.
    [IO.File]::WriteAllText($configFile,([IO.File]::ReadAllText($configFile).Replace("`n","`r`n")),(New-Object Text.UTF8Encoding($true)))
    [IO.File]::WriteAllText($profile.configPath,"Host *`r`n    HostName 127.0.0.2`r`nHost other`r`n    HostName 127.0.0.20`r`n",(New-Object Text.UTF8Encoding($true)))
    $settings=[pscustomobject]@{Options=(Get-TransportPortDefaults);Transport=$transport;Profile=$profile;Channel=[pscustomobject]@{inbounds=@([pscustomobject]@{tag='sync'})}}
    $script:fixtureSnapshot=[pscustomobject]@{listeners=@();processes=@();legacyActions=@()}
    foreach($pair in @(@('127.0.0.1',2222),@('127.0.0.1',26001),@('127.0.0.1',28001),@('127.0.0.2',45022))){
        $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse($pair[0]),[int]$pair[1]);$listener.ExclusiveAddressUse=$true;$listener.Start();[void]$held.Add($listener)
    }
    Assert (-not (Test-TransportPortFree '127.0.0.1' 2222 $script:fixtureSnapshot)) 'Реальный TcpListener мешает выбору даже при пустом снимке'
    $script:fixtureSnapshot.listeners=@([pscustomobject]@{address='127.0.0.1';port=2222;pid=42},[pscustomobject]@{address='127.0.0.1';port=26001;pid=0},[pscustomobject]@{address='127.0.0.1';port=28001;pid=0})
    $script:fixtureSnapshot.processes=@([pscustomobject]@{ProcessId=42;ExecutablePath='C:\Other\app.exe'})
    $originalConfig=[IO.File]::ReadAllText($configFile)
    $settings=Resolve-TransportPorts $root $settings 3 3
    Assert ([IO.File]::ReadAllText($configFile) -ceq $originalConfig) 'Выбор не записывает эффективные порты в config.json'
    Assert ($settings.Options.sshPort -eq 2232) 'Занятый SSH по умолчанию заменён следующим портом +10'
    Assert ($settings.Options.probePortBase -eq 26100 -and $settings.Options.socksPortBase -eq 28100) 'Блоки проб и SOCKS перемещены целиком с шагом 100'
    Assert ($settings.Options.channelSshAddress -eq '127.0.0.3') 'Занятый адрес канала заменён следующим адресом 127.x'
    $stateFile=Join-Path $root 'state/transport-ports.json';$state=Read-TransportJson $stateFile
    Assert ($state.schema -eq 1 -and $state.configured.sshPort -eq 2222 -and $state.effective.sshPort -eq 2232 -and @($state.moved).Count -eq 4) 'Состояние хранит настроенные и выбранные значения, список переносов'
    foreach($key in @('sshPort','channelSocksPort','syncPort','apiPort','probePortBase','socksPortBase','channelSshAddress','serverPort')){
        Assert ((Get-TransportEffectivePort $root $key) -eq $state.effective.$key) ('Общий читатель возвращает '+$key)
    }
    $ssh=[IO.File]::ReadAllText($profile.configPath)
    Assert ($ssh.Contains("HostName 127.0.0.3`r`n") -and $ssh.Contains("HostName 127.0.0.20`r`n") -and [IO.File]::ReadAllBytes($profile.configPath)[0] -eq 239) 'SSH HostName заменён только при точном совпадении; CRLF и BOM сохранены'
    $saved=Read-TransportJson $profileFile
    Assert ($saved.arguments -contains 'HostName=127.0.0.3' -and $saved.arguments -contains 'HostName=127.0.0.20') 'Сохранённые SSH options обновлены только при точном совпадении'
    $log=[IO.File]::ReadAllText((Join-Path $root 'logs/transport.log'))
    Assert ($log.Contains('Порт 2222 занят другой программой (C:\Other\app.exe, PID 42) — использую 2232')) 'Журнал объясняет перенос порта, программу и PID'
    # Сохранённый маршрут через наш SOCKS не должен помнить настроенный порт.
    [IO.File]::WriteAllText((Join-Path $root 'RemoteAgents.exe'),'fixture')
    $transport|Add-Member -Force channelSocksPort 2222
    $route=[pscustomobject]@{used='proxy';proxy=[pscustomobject]@{type='socks';host='127.0.0.1';port=2222}}
    Write-TransportJson $configFile @{transport=$transport;wizard=@{serverRoute=$route}}
    $settings=Resolve-TransportPorts $root $settings 3 3
    $port=[int](Get-TransportEffectivePort $root 'channelSocksPort')
    Assert ($port -ne 2222 -and (Get-TransportSavedRoute $root).proxy.port -eq $port) 'Сохранённый маршрут читает эффективный порт нашего SOCKS'
    $profile|Add-Member -Force routeProxyCommand 'старый прокси'
    $options=@(Get-TransportSavedRouteOptions $root $profile)
    Assert ($options[1].Contains((' '+$port+' %h %p')) -and -not $options[1].Contains('старый прокси')) 'Старый ProxyCommand заменён для нашего SOCKS-входа'
    $profile.PSObject.Properties.Remove('routeProxyCommand');$transport.PSObject.Properties.Remove('channelSocksPort')
    $transport|Add-Member -Force socksPortBase 26101;Write-TransportJson $configFile @{transport=$transport}
    $settings=Resolve-TransportPorts $root $settings 3 3
    Assert ($settings.Options.socksPortBase -eq 26201) 'Блок SOCKS не пересекается с уже выбранным блоком проб'
    $transport|Add-Member -Force sshPort 3333;Write-TransportJson $configFile @{transport=$transport}
    Assert ((Get-TransportEffectivePort $root 'sshPort') -eq 3333 -and (Get-TransportEffectivePort $root 'probePortBase') -eq 26000) 'Изменение настроек отменяет всё прежнее состояние'
    $transport.PSObject.Properties.Remove('sshPort');$transport.PSObject.Properties.Remove('socksPortBase');Write-TransportJson $configFile @{transport=$transport}
    foreach($listener in $held){$listener.Stop()};$held.Clear();$script:fixtureSnapshot.listeners=@()
    $settings=Resolve-TransportPorts $root $settings 3 3
    Assert ($settings.Options.sshPort -eq 2222 -and $settings.Options.probePortBase -eq 26000 -and $settings.Options.socksPortBase -eq 28000 -and $settings.Options.channelSshAddress -eq '127.0.0.2') 'После освобождения портов повторный выбор возвращает настроенные значения'
    Assert (([IO.File]::ReadAllText($profile.configPath)).Contains("HostName 127.0.0.2`r`n")) 'Возврат адреса канала обновляет SSH-профиль'
    # Внутренние пересечения настроек тоже устраняются.
    $transport|Add-Member -Force apiPort 2222;Write-TransportJson $configFile @{transport=$transport}
    $settings=Resolve-TransportPorts $root $settings 3 3
    Assert ($settings.Options.apiPort -eq 2232) 'API не пересекается с выбранным SSH-входом'
    # Happier's origin is allocated first and never moved, even if ordinary inputs prefer it.
    $web=Get-TransportLocalWeb ([pscustomobject]@{profile=[pscustomobject]@{happier=[pscustomobject]@{localWeb=[pscustomobject]@{enabled=$true;port=2222;serverPort=47832}}}})
    $settings|Add-Member -Force LocalWeb $web
    $transport.PSObject.Properties.Remove('apiPort')
    $settings=Resolve-TransportPorts $root $settings 3 3
    Assert ($web.port -eq 2222 -and $web.available -and $settings.Options.sshPort -eq 2232) 'Happier reserves fixed port before SSH allocation'
    foreach($key in @('syncPort','channelSocksPort','apiPort','probePortBase','socksPortBase')){
        $transport|Add-Member -Force $key 2222
        $settings=Resolve-TransportPorts $root $settings 3 3
        Assert ($web.port -eq 2222 -and $web.available -and $settings.Options[$key] -ne 2222) ('Happier reserved before '+$key)
        $transport.PSObject.Properties.Remove($key)
    }
    $webListener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,2222);$webListener.ExclusiveAddressUse=$true;$webListener.Start();[void]$held.Add($webListener)
    $script:fixtureSnapshot.listeners=@([pscustomobject]@{address='127.0.0.1';port=2222;pid=42})
    $settings=Resolve-TransportPorts $root $settings 3 3
    Assert ($web.port -eq 2222 -and -not $web.available -and $settings.Options.sshPort -eq 2232) 'occupied fixed origin is disabled without stopping channel or changing port'
    Assert ($web.conflict.pid -eq 42 -and $web.conflict.message.Contains('C:\Other\app.exe') -and $web.conflict.message.Contains('Happier') -and $web.conflict.message.Contains('фиксированный')) 'Happier conflict identifies process and recovery action'
    Assert (([IO.File]::ReadAllText((Join-Path $root 'logs/transport.log'))).Contains('Вход Happier не запущен')) 'fixed-port conflict reaches journal'
    $webListener.Stop();$held.Clear();$script:fixtureSnapshot.listeners=@()
    $settings=Resolve-TransportPorts $root $settings 3 3
    Assert ($web.available -and $web.port -eq 2222 -and $null -eq $web.conflict) 'freed origin recovers at same configured port'
    $settings.PSObject.Properties.Remove('LocalWeb')
    # Исчерпан детерминированный поиск: ОС выбирает начало целого блока.
    $script:fixtureSnapshot.listeners=@(0..199|ForEach-Object {[pscustomobject]@{address='127.0.0.1';port=(40000+$_*100);pid=0}})
    $selected=@{};$base=Select-TransportPortBlock 40000 3 100 $script:fixtureSnapshot $selected
    Assert ($selected.Count -eq 3 -and $selected.ContainsKey($base+2) -and $base -le 65533) 'После исчерпания поиска ОС выбирает свободный блок целиком'
    $script:fixtureSnapshot.listeners=@([pscustomobject]@{address='0.0.0.0';port=45022;pid=0})
    Assert (-not (Test-TransportPortFree '127.0.0.3' 45022 $script:fixtureSnapshot)) 'Wildcard в снимке запрещает порт на другом loopback-адресе'
    $transport.channelFirst=$false;$settings.Channel.inbounds=@();$transport.PSObject.Properties.Remove('apiPort')
    $settings=Resolve-TransportPorts $root $settings 0 0
    Assert (@((Read-TransportJson $stateFile).moved).Count -eq 0) 'Неиспользуемые входы и пустые блоки не требуют свободных портов'
}finally{foreach($listener in $held){$listener.Stop()};if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
