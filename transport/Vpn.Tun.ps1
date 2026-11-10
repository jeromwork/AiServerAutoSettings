#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName='Status')]
param([Alias('Home')][string]$TransportHome=(Join-Path $env:LOCALAPPDATA 'RemoteAgents'),
    [Parameter(Mandatory=$true,ParameterSetName='Enable')][switch]$Enable,
    [Parameter(Mandatory=$true,ParameterSetName='Disable')][switch]$Disable,
    [Parameter(Mandatory=$true,ParameterSetName='Generate')][switch]$Generate,
    [Parameter(Mandatory=$true,ParameterSetName='Worker')][switch]$Worker,
    [Parameter(Mandatory=$true,ParameterSetName='Rollback')][switch]$Rollback,
    [Parameter(Mandatory=$true,ParameterSetName='Broker')][switch]$Broker,
    [string]$Session='', [string]$OutputConfig='', [int]$ParentPid=0)
. (Join-Path $PSScriptRoot 'Transport.Common.ps1')
$root=(Get-TransportHome $TransportHome);$action=$PSCmdlet.ParameterSetName;$tasks=Get-VpnTaskNames $root
$sessionFile=Join-Path $root 'state/vpn-session.json';$stopFile=Join-Path $root 'state/vpn.stop';$configFile=Join-Path $root 'state/vpn-sing-box.json'
$child=$null;$mutex=$null;$locked=$false;$parent=$null;$failure=$false;$conflict=[pscustomobject]@{conflict=$false;items=@()}
try{
    if($action -eq 'Status'){
        $file=Join-Path $root 'status/vpn.json'
        if(-not (Test-Path -LiteralPath $file)){Write-VpnStatus $root $false $false 'off' $conflict 'Системный VPN выключен'}
        ConvertTo-Json -InputObject (Read-TransportJson $file) -Depth 10
        return
    }
    if($action -eq 'Disable'){
        Set-VpnEnabled $root $false;Write-TransportJson $stopFile @{stop=$true}
        Write-VpnStatus $root $false $false 'stopping' $conflict 'Запрошено выключение TUN; ожидается подтверждение компонента'
        return
    }
    if($action -eq 'Rollback'){
        if($env:OS -ne 'Windows_NT' -or -not (Test-VpnAdministrator)){throw 'Откат требует администратора Windows'}
        if(-not $Session -or (Read-TransportJson $sessionFile).session -ne $Session){return}
        # Автооткат не зависит от читаемости config.json.
        try{Set-VpnEnabled $root $false}catch{};Write-TransportJson $stopFile @{stop=$true}
        $snapshot=[pscustomobject]@{Processes=@(Get-CimInstance Win32_Process -ErrorAction Stop)};$own=@(Get-VpnOwnedProcessIds $root $snapshot)
        $ownerFile=Join-Path $root 'state/vpn-owner.json'
        if(Test-Path -LiteralPath $ownerFile){$owner=Read-TransportJson $ownerFile;if([int]$owner.pid -in $own){Stop-Process -Id ([int]$owner.pid) -Force -ErrorAction SilentlyContinue}}
        Stop-ScheduledTask -TaskName $tasks.Worker -ErrorAction SilentlyContinue
        Clear-VpnRoutes $root $Session
        foreach($taskName in @($tasks.Worker,$tasks.Rollback)){Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue}
        Write-VpnStatus $root $false $false 'rolled-back' $conflict 'TUN выключен независимым автооткатом';return
    }
    $settings=Read-TransportSettings $root;$v=Get-VpnOptions $settings
    if($action -eq 'Generate'){
        # Только чтение системы и генерация, без запуска TUN/задач/UAC.
        $snapshot=Get-VpnSnapshot;$paths=Get-TransportCandidates $settings $root;$net=Get-TransportNetwork
        $status=Read-TransportJson (Join-Path $root 'status/transport.json')
        $exclude=Get-VpnExclusions $settings $paths $snapshot -Root $root
        $cfg=New-VpnTunConfig $settings $paths $status.active $exclude $net.interface
        if(-not $OutputConfig){$OutputConfig=Join-Path $root 'state/vpn-generated.json'}
        Write-TransportJson $OutputConfig $cfg -Private;Test-TransportConfigFile $settings.Options.singBoxPath $OutputConfig
        Write-Output 'TUN-конфиг создан и проверен; TUN не запускался';return
    }
    if($env:OS -ne 'Windows_NT'){throw 'Запуск TUN поддержан только на Windows'}
    if($action -in @('Enable','Broker')){
        $snapshot=Get-VpnSnapshot;$own=@(Get-VpnOwnedProcessIds $root $snapshot)
        # Повторное включение не заменяет задачи работающего сеанса.
        $ownerFile=Join-Path $root 'state/vpn-owner.json'
        if(Test-Path -LiteralPath $ownerFile){$owner=Read-TransportJson $ownerFile;if([int]$owner.pid -in $own){Write-Output 'Наш TUN уже работает';return}}
        $conflict=Find-VpnConflicts $snapshot $own
        if($conflict.conflict){Write-VpnStatus $root $false $false 'conflict' $conflict 'Найден другой VPN; отключите его самостоятельно или оставьте наш VPN выключенным';return}
        if(@($snapshot.Adapters|Where-Object {$_.Name -eq $v.interfaceName}).Count){throw 'Имя TUN уже занято; существующий интерфейс не трогаем'}
        $paths=Get-TransportCandidates $settings $root;$net=Get-TransportNetwork;$status=Read-TransportJson (Join-Path $root 'status/transport.json')
        if(-not $status.ok -or ([DateTime]::UtcNow-(Convert-TransportUtc $status.updatedAt)).TotalSeconds -gt 15){throw 'Транспорт ещё не проверен'}
        $exclude=Get-VpnExclusions $settings $paths $snapshot -Root $root
        $cfg=New-VpnTunConfig $settings $paths $status.active $exclude $net.interface
        $preflight=Join-Path $root 'state/vpn-preflight.json';Write-TransportJson $preflight $cfg -Private;Test-TransportConfigFile $settings.Options.singBoxPath $preflight
        if(-not (Test-VpnAdministrator)){
            Write-VpnStatus $root $false $false 'awaiting-uac' $conflict 'Ожидается подтверждение UAC для одноразовой задачи TUN'
            $exe=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
            $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Home',$root,'-Broker','-ParentPid',[string]$ParentPid)
            # UAC подтверждает человек. Нет сохранённых паролей или обхода elevation.
            $elevated=Start-Process -FilePath $exe -ArgumentList (($args|ForEach-Object {Quote-Transport $_}) -join ' ') -Verb RunAs -PassThru -Wait
            if($elevated.ExitCode -ne 0){throw 'Повышенный компонент не запущен'};return
        }
        $mutex=New-Object Threading.Mutex($false,($tasks.Worker+'-Enable'));try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true};if(-not $locked){throw 'Включение уже выполняется'}
        $Session=[guid]::NewGuid().ToString('N');Write-TransportJson $sessionFile @{session=$Session} -Private
        Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
        $exe=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $base=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Home',$root,'-Session',$Session)
        $rollbackAction=New-ScheduledTaskAction -Execute $exe -Argument ((@($base+@('-Rollback'))|ForEach-Object {Quote-Transport $_}) -join ' ')
        $workerAction=New-ScheduledTaskAction -Execute $exe -Argument ((@($base+@('-Worker','-ParentPid',[string]$ParentPid))|ForEach-Object {Quote-Transport $_}) -join ' ')
        $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
        $taskSettings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
        # Независимый watchdog установлен ДО первого run. Не требует живого лаунчера/worker.
        Register-ScheduledTask -TaskName $tasks.Rollback -Action $rollbackAction -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)) -Principal $principal -Settings $taskSettings -Force|Out-Null
        try{
            Register-ScheduledTask -TaskName $tasks.Worker -Action $workerAction -Principal $principal -Settings $taskSettings -Force|Out-Null
            Set-VpnEnabled $root $true;Start-ScheduledTask -TaskName $tasks.Worker
            Write-VpnStatus $root $false $true 'starting' $conflict 'TUN запускается; автооткат через пять минут'
        }catch{Set-VpnEnabled $root $false;throw}
        return
    }
    if(-not (Test-VpnAdministrator)){throw 'Нужны подтверждённые права администратора'}
    if(-not $Session -or (Read-TransportJson $sessionFile).session -ne $Session){return}
    $mutex=New-Object Threading.Mutex($false,$tasks.Worker);try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true};if(-not $locked){throw 'TUN уже запущен'}
    if($ParentPid -gt 0){$parent=[Diagnostics.Process]::GetProcessById($ParentPid);[void]$parent.Handle}
    $lastRevision='';$lastTag='';$nextCheck=[DateTime]::MinValue;$validated=$false
    while($true){
        $settings=Read-TransportSettings $root;$v=Get-VpnOptions $settings
        if(-not $v.enabled -or (Test-Path -LiteralPath $stopFile) -or (Test-Path -LiteralPath (Join-Path $root 'stop')) -or ($parent -and $parent.HasExited)){break}
        $status=Read-TransportJson (Join-Path $root 'status/transport.json')
        if(-not $status.ok -or ([DateTime]::UtcNow-(Convert-TransportUtc $status.updatedAt)).TotalSeconds -gt 15){throw 'Путь транспорта потерял проверенное состояние'}
        $revision=(Get-TransportRevision $root)+(ConvertTo-Json -InputObject $v -Depth 20 -Compress)
        if(-not $child -or $lastTag -ne $status.active -or $lastRevision -ne $revision -or [DateTime]::UtcNow -ge $nextCheck){
            $snapshot=Get-VpnSnapshot;$own=@(Get-VpnOwnedProcessIds $root $snapshot);$ownInterface='';if($child){$ownInterface=$v.interfaceName}
            $conflict=Find-VpnConflicts $snapshot $own $ownInterface;if($conflict.conflict){throw 'Обнаружен конфликт VPN'}
            $paths=Get-TransportCandidates $settings $root;$net=Get-TransportNetwork;$exclude=Get-VpnExclusions $settings $paths $snapshot -Root $root
            $cfg=New-VpnTunConfig $settings $paths $status.active $exclude $net.interface
            $newJson=ConvertTo-Json -InputObject $cfg -Depth 40 -Compress
            if(-not $child -or $newJson -ne $lastJson){
                $pending=Join-Path $root 'state/vpn-pending.json';Write-TransportJson $pending $cfg -Private;Test-TransportConfigFile $settings.Options.singBoxPath $pending
                Register-VpnRollbackTask $root $Session $PSCommandPath;$validated=$false
                Stop-TransportProcess $child;$child=$null;Clear-VpnRoutes $root $Session
                Write-TransportJson $configFile $cfg -Private
                $child=Start-TransportProcess $settings.Options.singBoxPath @('run','-c',$configFile)
                Save-TransportOwner $root 'vpn' $child $settings.Options.singBoxPath $configFile
                $adapter=$null
                for($i=0;$i -lt 40;$i++){
                    if($child.Process.HasExited){throw 'TUN завершился при запуске'}
                    $adapter=Get-NetAdapter -IncludeHidden|Where-Object {$_.Name -eq $v.interfaceName -and $_.Status -eq 'Up'}|Select-Object -First 1
                    if($adapter){break};Start-Sleep -Milliseconds 250
                }
                if(-not $adapter){throw 'Не появился интерфейс TUN'}
                Write-TransportJson (Join-Path $root 'state/vpn-interface.json') @{session=$Session;guid=[string]$adapter.InterfaceGuid;name=$adapter.Name} -Private
                Test-VpnThroughTun $settings $adapter
                # Только успешная проверка сервера, DNS, внешнего HTTPS и TUN routes снимает watchdog.
                if(-not $validated){Unregister-ScheduledTask -TaskName $tasks.Rollback -Confirm:$false;$validated=$true}
                $lastJson=$newJson
            }else{Test-VpnThroughTun $settings $adapter}
            $lastTag=$status.active;$lastRevision=$revision;$nextCheck=[DateTime]::UtcNow.AddSeconds(30)
        }
        if($child.Process.HasExited){throw 'TUN неожиданно завершился'}
        Write-VpnStatus $root $true $true 'on' $conflict 'Системный VPN проверен; трафик идёт через выбранный путь'
        Start-Sleep -Seconds 1
    }
}catch{
    $failure=$true
    if($action -ne 'Generate'){try{Set-VpnEnabled $root $false}catch{};Write-VpnStatus $root $false $false 'error' $conflict 'TUN не включён или выключается после ошибки; проверьте конфиг, журнал и права'}
    Write-Error 'Компонент VPN не выполнил операцию. Секреты и параметры процессов скрыты.' -ErrorAction Continue
}finally{
    if($action -eq 'Worker' -and $locked){
        Stop-TransportProcess $child
        try{Clear-VpnRoutes $root $Session;Set-VpnEnabled $root $false
            foreach($name in @($tasks.Worker,$tasks.Rollback)){Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue}
            if(-not $failure){Write-VpnStatus $root $false $false 'off' $conflict 'Системный VPN выключен; маршруты нашего интерфейса удалены'}
        }catch{$failure=$true;Write-VpnStatus $root $false $false 'rollback-error' $conflict 'Не удалось подтвердить очистку наших маршрутов; независимый автооткат сохранён'}
    }
    if($locked){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()};if($parent){$parent.Dispose()}
}
if($failure){exit 1}
