#requires -Version 5.1
[CmdletBinding()]
param([string]$Profile,[switch]$Uninstall,[switch]$HelpersReady)
. (Join-Path $PSScriptRoot 'Disk.Common.ps1')
$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk';$tray=Join-Path $script:DiskHome 'tray/syncthingtray.exe';$state=Join-Path $script:DiskHome 'state'
. (Join-Path $PSScriptRoot 'Disk.Binary.ps1')
function Get-DiskPort {$socket=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$socket.Start();try{$socket.LocalEndpoint.Port}finally{$socket.Stop()}}
function Wait-DiskTransport {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.ElapsedMilliseconds -lt 30000){
        $client=New-Object Net.Sockets.TcpClient
        try{
            $connect=$client.ConnectAsync('127.0.0.1',2222)
            if($connect.Wait([int][Math]::Max(1,[Math]::Min(1000,30000-$watch.ElapsedMilliseconds)))){
                $stream=$client.GetStream();$bytes=New-Object byte[] 4;$count=0
                while($count -lt 4 -and $watch.ElapsedMilliseconds -lt 30000){
                    $read=$stream.ReadAsync($bytes,$count,4-$count)
                    if(-not $read.Wait([int][Math]::Max(1,[Math]::Min(1000,30000-$watch.ElapsedMilliseconds)))){break}
                    if($read.Result -eq 0){break};$count+=$read.Result
                }
                if($count -eq 4 -and [Text.Encoding]::ASCII.GetString($bytes) -ceq 'SSH-'){return}
            }
        }catch{}finally{$client.Dispose()}
        if($watch.ElapsedMilliseconds -lt 30000){Start-Sleep -Milliseconds ([int][Math]::Min(250,30000-$watch.ElapsedMilliseconds))}
    }
    throw 'Связь не поднялась: нет баннера SSH на 127.0.0.1:2222 за 30 с. Настройки сохранены; повторите установку.'
}
$step='Подготовка'
try {
    if($Uninstall){. (Join-Path $PSScriptRoot 'Disk.NavPane.ps1');Remove-DiskNavPane;Write-DiskLog 'Удаление';Write-Output 'Значок Disk в Проводнике удалён. Пользовательские файлы сохранены.';return}
    $step='SSH-профиль и файлы';Read-DiskProfile $Profile
    Write-DiskUtf8 (Join-Path $script:DiskHome 'profile.txt') $script:ProfilePath
    $upload='set -eu; umask 077; mkdir -p "$HOME/.local/share/remote-disk"' + "`n"
    if(-not $HelpersReady){
    foreach($name in @('server-disk.sh','stignore.txt','stignore-previous.sha256')){$data=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $name)).Replace("`r",'');$upload+='printf %s '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($data))+' | base64 -d > "$HOME/.local/share/remote-disk/'+$name+'"' + "`n"}
    }
    $step='Bootstrap сервера';$remote=(Invoke-DiskSsh 'bash -s' -Direct -InputText ($upload+'bash "$HOME/.local/share/remote-disk/server-disk.sh" bootstrap'))|ConvertFrom-Json
    $step='Установка трея';Install-DiskBinary 'https://github.com/Martchus/syncthingtray/releases/download/v2.1.9/syncthingtray-2.1.9-x86_64-w64-mingw32.exe.zip' 'c20d74998cb84980b07cb00eca4c38d26643eaa69b8bef94f6841ded6c752cc5' tray syncthingtray.exe
    $step='Конфигурация движка';$fresh=-not (Test-Path -LiteralPath (Join-Path $state 'config.xml'))
    if($fresh){[void](Invoke-DiskProcess $tray @('syncthing','generate','--home',$state))};Read-DiskState
    $options=@{globalAnnounceEnabled=$false;localAnnounceEnabled=$false;relaysEnabled=$false;natEnabled=$false;autoUpgradeIntervalH=0;reconnectionIntervalS=10;listenAddresses=@(('tcp://127.0.0.1:'+(Get-DiskPort)));startBrowser=$false}
    $running=$false;try{$running=[bool](Invoke-DiskApi 'system/status')}catch{}
    if($running){$options.Remove('listenAddresses');[void](Invoke-DiskApi 'config/options' PATCH $options)}else{
        if($fresh){foreach($folder in @($script:Engine.configuration.SelectNodes('folder'))){[void]$script:Engine.configuration.RemoveChild($folder)};$script:Engine.configuration.gui.address='127.0.0.1:'+(Get-DiskPort)}
        Save-DiskState $options;Read-DiskState
    }
    Write-DiskUtf8 (Join-Path $script:DiskHome 'tray/syncthingtray.ini') (New-DiskIni $tray $state $script:Gui $script:ApiKey)
    . (Join-Path $PSScriptRoot 'Disk.Engine.ps1')
    $script:DiskEngine=$null;Start-DiskHeadless
    $local=$null;for($i=0;$i -lt 40;$i++){try{$local=Invoke-DiskApi 'system/status';if($local.myID){break}}catch{};Start-Sleep -Milliseconds 250};if(-not $local.myID){throw 'Движок не запустился'}
    $step='Подключение устройств';[void](Invoke-DiskApi ('config/devices/'+$remote.deviceId) PUT @{deviceID=$remote.deviceId;name='RemoteDisk Server';addresses=@('tcp://127.0.0.1:22001');autoAcceptFolders=$false})
    [void](Invoke-DiskServer add-device @{deviceId=$local.myID;deviceName=$env:COMPUTERNAME} -Direct);Write-DiskUtf8 (Join-Path $script:DiskHome 'server.txt') $remote.deviceId
    $step='Проверка связи';Wait-DiskTransport
    Write-DiskLog 'Установка';Write-Output ('RemoteDisk установлен. Серверные папки появляются в '+(Get-DiskBase)+'; занятые пути остаются в ожидании.')
}catch{Write-DiskLog $step $_;Write-Error ('Установка RemoteDisk не выполнена: '+$_.Exception.Message+' Проверьте SSH-профиль, доступ к серверу и загрузкам.') -ErrorAction Continue;exit 1}
