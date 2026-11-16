#requires -Version 5.1
[CmdletBinding()]
param([string]$Profile,[switch]$HelpersReady,[string]$AcceptFile,[switch]$Uninstall,[switch]$CleanupLegacy)
. (Join-Path $PSScriptRoot 'Disk.Common.ps1')
$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk'
$tray=Join-Path $script:DiskHome 'tray/syncthingtray.exe';$state=Join-Path $script:DiskHome 'state'
function Get-DiskPort {$socket=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$socket.Start();try{$socket.LocalEndpoint.Port}finally{$socket.Stop()}}
function Wait-DiskTransport([double]$TimeoutSeconds=(Get-DiskSeconds TRANSPORT_READY 30)) {
    $budget=$TimeoutSeconds*1000
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.ElapsedMilliseconds -lt $budget){
        $client=New-Object Net.Sockets.TcpClient
        try{
            $port=[int](Get-TransportEffectivePort (Join-Path $env:LOCALAPPDATA 'RemoteAgents') 'sshPort')
            $connect=$client.ConnectAsync('127.0.0.1',$port)
            if($connect.Wait([int][Math]::Max(1,[Math]::Min((Get-DiskMilliseconds TRANSPORT_CONNECT 1000),$budget-$watch.ElapsedMilliseconds)))){
                $stream=$client.GetStream();$bytes=New-Object byte[] 4;$count=0;$banner=[Diagnostics.Stopwatch]::StartNew()
                while($count -lt 4 -and $watch.ElapsedMilliseconds -lt $budget -and $banner.ElapsedMilliseconds -lt (Get-DiskMilliseconds TRANSPORT_BANNER 5000)){
                    $read=$stream.ReadAsync($bytes,$count,4-$count)
                    if(-not $read.Wait([int][Math]::Max(1,[Math]::Min((Get-DiskMilliseconds TRANSPORT_BANNER 5000)-$banner.ElapsedMilliseconds,$budget-$watch.ElapsedMilliseconds)))){break}
                    if($read.Result -eq 0){break};$count+=$read.Result
                }
                if($count -eq 4 -and [Text.Encoding]::ASCII.GetString($bytes) -ceq 'SSH-'){return}
            }
        }catch{}finally{$client.Dispose()}
        if($watch.ElapsedMilliseconds -lt $budget){Start-Sleep -Milliseconds ([int][Math]::Min((Get-DiskMilliseconds TRANSPORT_POLL 250),$budget-$watch.ElapsedMilliseconds))}
    }
    throw ('Связь не поднялась: нет баннера SSH на 127.0.0.1:'+$port+' за '+$TimeoutSeconds+' с. Настройки сохранены; повторите установку.')
}
$step='Подготовка';$engineLease=$null;$failure=$null;$script:DiskEngine=$null
try {
    [void][IO.Directory]::CreateDirectory($script:DiskHome)
    $migration=Join-Path $script:DiskHome 'legacy-cleanup-v1'
    if($Uninstall -or $CleanupLegacy -or -not (Test-Path -LiteralPath $migration)){
        $step='Очистка старого оформления Disk'
        try{Remove-DiskLegacy;Write-DiskUtf8 $migration '1'}catch{
            if($Uninstall -or $CleanupLegacy){throw}
            Write-DiskLog $step $_
            Write-DiskProgress 'Не удалось полностью убрать старое оформление Disk; установка продолжается, очистка повторится при следующем запуске.'
        }
    }
    if($Uninstall){Remove-DiskNavPane;Write-DiskLog 'Удаление';Write-Output 'Значок Disk в Проводнике удалён. Пользовательские файлы сохранены.';return}
    if($CleanupLegacy){Write-DiskLog 'Очистка старого оформления Disk';Write-Output 'Старое оформление Disk удалено. Закрепление Disk и файлы сохранены.';return}
    $step='Чтение AcceptFile';$folders=@(Read-DiskAcceptFile $AcceptFile)
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'transport/Transport.Common.ps1')
    . (Join-Path $PSScriptRoot 'Disk.Binary.ps1')
    . (Join-Path $PSScriptRoot 'Disk.Engine.ps1')
    $step='Ожидание Диска';$engineLease=Enter-DiskEngineLock $script:DiskHome
    $serverFile=Join-Path $script:DiskHome 'server.txt'
    $peer='';if(Test-Path -LiteralPath $serverFile){$peer=[IO.File]::ReadAllText($serverFile).TrimStart([char]0xFEFF).Trim()}
    $pair=-not $peer -or -not (Test-Path -LiteralPath (Join-Path $state 'config.xml'))
    if($pair){
        $step='SSH-профиль и файлы';Read-DiskProfile $Profile
        Write-DiskUtf8 (Join-Path $script:DiskHome 'profile.txt') $script:ProfilePath
        $upload='set -eu; umask 077; mkdir -p "$HOME/.local/share/remote-disk"'+"`n"
        if(-not $HelpersReady){
            $data=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'server-disk.sh')).Replace("`r",'')
            $upload+='printf %s '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($data))+' | base64 -d > "$HOME/.local/share/remote-disk/server-disk.sh"'+"`n"
            $upload+=Get-DiskIgnoreUpload
        }
        $step='Bootstrap сервера';$remote=(Invoke-DiskRetry {Invoke-DiskSsh 'bash -s' -Direct -InputText ($upload+'bash "$HOME/.local/share/remote-disk/server-disk.sh" bootstrap')} $step)|ConvertFrom-Json
        $peer=[string]$remote.deviceId;if(-not $peer){throw 'Сервер не вернул ID устройства'}
    }
    # Never replace an installed Syncthing binary or edit an existing config.xml on update.
    if(-not (Test-Path -LiteralPath $tray)){
        $step='Установка трея';Install-DiskBinary 'https://github.com/Martchus/syncthingtray/releases/download/v2.1.9/syncthingtray-2.1.9-x86_64-w64-mingw32.exe.zip' 'c20d74998cb84980b07cb00eca4c38d26643eaa69b8bef94f6841ded6c752cc5' tray syncthingtray.exe
    }
    $step='Конфигурация движка';$fresh=-not (Test-Path -LiteralPath (Join-Path $state 'config.xml'))
    if($fresh){[void](Invoke-DiskProcess $tray @('syncthing','generate','--home',$state))}
    Read-DiskState
    if($fresh){
        foreach($folder in @($script:Engine.configuration.SelectNodes('folder'))){[void]$script:Engine.configuration.RemoveChild($folder)}
        $script:Engine.configuration.gui.address='127.0.0.1:'+(Get-DiskPort)
        Save-DiskState @{globalAnnounceEnabled=$false;localAnnounceEnabled=$false;relaysEnabled=$false;natEnabled=$false;autoUpgradeIntervalH=0;reconnectionIntervalS=[int](Get-DiskSeconds RECONNECT_INTERVAL 10);listenAddresses=@(('tcp://127.0.0.1:'+(Get-DiskPort)));startBrowser=$false}
        Read-DiskState
    }
    $ini=Join-Path $script:DiskHome 'tray/syncthingtray.ini'
    if($fresh -or -not (Test-Path -LiteralPath $ini)){Write-DiskUtf8 $ini (New-DiskIni $tray $state $script:Gui $script:ApiKey)}
    Set-DiskTrayExternalEngine
    $local=$null;try{$local=Invoke-DiskApi 'system/status'}catch{}
    if(-not $local.myID){Start-DiskHeadless}
    for($i=0;$i -lt (Get-DiskAttempts INSTALL_READY 40) -and -not $local.myID;$i++){Start-Sleep -Milliseconds (Get-DiskMilliseconds INSTALL_POLL 250);try{$local=Invoke-DiskApi 'system/status'}catch{}}
    if(-not $local.myID){throw 'Движок не запустился'}
    $step='Подключение устройств';Set-DiskServerDevice $peer
    if($pair){
        [void](Invoke-DiskRetry {Invoke-DiskServer add-device @{deviceId=$local.myID;deviceName=$env:COMPUTERNAME} -Direct} 'Регистрация устройства на сервере')
        Write-DiskUtf8 $serverFile $peer
        $step='Проверка связи';Wait-DiskTransport
    }
    $step='Приём папок';if($folders.Count){Accept-DiskFolders $folders $peer ([string]$local.myID)}
    $step='Задержка обнаружения изменений';Set-DiskWatcherDelay
    $base=Get-DiskBase;[void][IO.Directory]::CreateDirectory($base);[void](Ensure-DiskNavPane $base)
}catch{$failure=$_}finally{
    if($engineLease){
        try{Stop-DiskHeadless}catch{
            if(-not $failure){$step='Остановка временного движка';$failure=$_}else{Write-DiskLog 'Остановка временного движка' $_}
        }finally{Exit-DiskEngineLock $engineLease}
    }
}
if($failure){Write-DiskLog $step $failure;[Console]::Error.WriteLine('Установка RemoteDisk не выполнена: '+$failure.Exception.Message);exit 1}
Write-DiskLog 'Установка';Write-Output 'RemoteDisk установлен. Принимайте новые папки в Syncthing Tray. Ход передачи смотрите там же.'
