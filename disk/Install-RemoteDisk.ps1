#requires -Version 5.1
[CmdletBinding()]
param([string]$Profile,[switch]$Uninstall)
. (Join-Path $PSScriptRoot 'Disk.Common.ps1')
$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk';$tray=Join-Path $script:DiskHome 'tray/syncthingtray.exe';$state=Join-Path $script:DiskHome 'state';$channel=Join-Path $script:DiskHome 'channel';$app=Join-Path $script:DiskHome 'app'
function Set-DiskRegistration([bool]$Enabled) {
    $root=[Microsoft.Win32.Registry]::CurrentUser;$run=$root.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
    try{if($Enabled){$run.SetValue('RemoteDisk',('"'+$tray+'" --wait'))}else{$run.DeleteValue('RemoteDisk',$false)}}finally{$run.Dispose()}
    $menu='Software\Classes\Directory\shell\RemoteDisk_add';$root.DeleteSubKeyTree($menu,$false)
    if($Enabled){$key=$root.CreateSubKey($menu);try{$key.SetValue('','Синхронизировать с сервером')}finally{$key.Dispose()};$key=$root.CreateSubKey($menu+'\command');try{$key.SetValue('','powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $app 'Add-RemoteDiskFolder.ps1')+'" -Path "%1"')}finally{$key.Dispose()}}
}
function Install-DiskBinary($Url,$Hash,$Directory,$Name) {
    $dest=Join-Path $script:DiskHome $Directory;$marker=Join-Path $dest 'release.txt'
    if((Test-Path -LiteralPath (Join-Path $dest $Name)) -and (Test-Path -LiteralPath $marker) -and [IO.File]::ReadAllText($marker) -eq $Hash){return}
    [void][IO.Directory]::CreateDirectory($dest);$tmp=Join-Path $script:DiskHome ([IO.Path]::GetRandomFileName());[void][IO.Directory]::CreateDirectory($tmp)
    try{$zip=Join-Path $tmp 'release.zip';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest $Url -OutFile $zip -UseBasicParsing -TimeoutSec 90
        if((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ine $Hash){throw 'SHA256 mismatch'}
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tmp 'unpacked');$exe=@(Get-ChildItem -LiteralPath (Join-Path $tmp 'unpacked') -Filter $Name -Recurse -File);if($exe.Count -ne 1){throw 'Неверный архив'}
        $target=[IO.Path]::GetFullPath((Join-Path $dest $Name));Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Name)) -ErrorAction SilentlyContinue|Where-Object {$_.Path -and [IO.Path]::GetFullPath($_.Path) -ieq $target}|ForEach-Object {Stop-Process -Id $_.Id -Force -ErrorAction Stop;$_.WaitForExit()}
        Copy-Item -LiteralPath $exe[0].FullName -Destination (Join-Path $dest $Name) -Force;Write-DiskUtf8 $marker $Hash
    }finally{Remove-Item -LiteralPath $tmp -Recurse -Force}
}
function Get-DiskPort {$socket=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$socket.Start();try{$socket.LocalEndpoint.Port}finally{$socket.Stop()}}
function Wait-DiskChannel {
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
    throw 'Канал не поднялся: нет баннера SSH на 127.0.0.1:2222 за 30 с. Трей и настройки сохранены; повторите установку.'
}
$step='Подготовка'
try {
    if($Uninstall){Unregister-ScheduledTask -TaskName RemoteDiskFolders -Confirm:$false -ErrorAction SilentlyContinue;Set-DiskRegistration $false;Stop-ScheduledTask -TaskName RemoteDiskChannel -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName RemoteDiskChannel -Confirm:$false -ErrorAction SilentlyContinue;Write-DiskLog 'Удаление автозапуска';Write-Output 'Автозапуск, задача и меню удалены. Пользовательские файлы сохранены.';return}
    $step='SSH-профиль и файлы';Read-DiskProfile $Profile;[void][IO.Directory]::CreateDirectory($app);[void][IO.Directory]::CreateDirectory($channel)
    foreach($name in @('Install-RemoteDisk.ps1','Add-RemoteDiskFolder.ps1','Disk.Common.ps1','Disk.Selective.ps1','Sync-RemoteDiskFolders.ps1','Enable-RemoteDiskFolders.ps1','Move-RemoteDiskFolder.ps1','stignore.txt','legacy-ignores.sha256','server-disk.sh')){$target=Join-Path $app $name;if([IO.Path]::GetFullPath((Join-Path $PSScriptRoot $name)) -ne [IO.Path]::GetFullPath($target)){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $target -Force}}
    Write-DiskUtf8 (Join-Path $script:DiskHome 'profile.txt') $script:ProfilePath
    $upload='set -eu; umask 077; mkdir -p "$HOME/.local/share/remote-disk"' + "`n"
    foreach($name in @('server-disk.sh','stignore.txt','legacy-ignores.sha256')){$data=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $name)).Replace("`r",'');$upload+='printf %s '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($data))+' | base64 -d > "$HOME/.local/share/remote-disk/'+$name+'"' + "`n"}
    $step='Bootstrap сервера';$remote=(Invoke-DiskSsh 'bash -s' -Direct -InputText ($upload+'bash "$HOME/.local/share/remote-disk/server-disk.sh" bootstrap'))|ConvertFrom-Json
    $step='Установка трея';Install-DiskBinary 'https://github.com/Martchus/syncthingtray/releases/download/v2.1.9/syncthingtray-2.1.9-x86_64-w64-mingw32.exe.zip' 'c20d74998cb84980b07cb00eca4c38d26643eaa69b8bef94f6841ded6c752cc5' tray syncthingtray.exe
    $step='Установка канала';Install-DiskBinary 'https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-windows-amd64.zip' '99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df' channel sing-box.exe
    $step='Конфигурация канала';$request=@{server=$script:Connection.serverAddress};$transport=[IO.File]::ReadAllText($script:Connection.configPath)
    if($transport -match '(?im)^\s*ProxyCommand\s+(.+)$'){$proxy=$Matches[1];if($proxy -notmatch '-W\s+%h:%p\s+([\w.-]+)\s*$'){throw 'Неизвестный формат промежуточного подключения'};$alias=$Matches[1];if($proxy -notmatch '-F\s+"([^"]+)"'){throw 'Нет конфигурации промежуточного хоста'};$request.hop=New-DiskHop (Invoke-DiskProcess $script:Connection.sshExecutable @('-G','-F',$Matches[1],$alias))}
    $config=Join-Path $channel 'config.json'
    # Preserve a working legacy channel (including H detours); installation is not a reset.
    if(-not (Test-Path -LiteralPath $config)){
        $hasChannel=Invoke-DiskSsh 'test -r /etc/sing-box/config.json && echo yes || echo no' -Direct
        if($hasChannel.Trim() -eq 'yes'){
            Invoke-DiskServer channel-config $request -Direct -OutputFile ($config+'.tmp')
            [void](Convert-DiskChannel ([IO.File]::ReadAllText($config+'.tmp')));Move-Item -LiteralPath ($config+'.tmp') -Destination $config -Force
        }else{
            . (Join-Path (Split-Path $PSScriptRoot -Parent) 'transport/Transport.Common.ps1')
            $p=$script:Connection
            $outbound=@{type='ssh';tag='server';server=$p.serverAddress;server_port=(Get-TransportServerPort $p);user=$p.login;private_key_path=$p.keyPath;host_key=@(Get-TransportHostKeys $p.sshExecutable $p.serverAddress $p.knownHostsPath)}
            $inbounds=@(@{type='direct';tag='ssh';listen='127.0.0.1';listen_port=2222;network='tcp';override_address='127.0.0.1';override_port=(Get-TransportServerPort $p)},@{type='direct';tag='sync';listen='127.0.0.1';listen_port=22001;network='tcp';override_address='127.0.0.1';override_port=[int]$remote.listen})
            if(-not $remote.listen){throw 'Сервер не сообщил порт Syncthing'}
            Write-TransportJson $config @{log=@{disabled=$true};inbounds=$inbounds;outbounds=@($outbound);route=@{final='server';auto_detect_interface=$true}}
        }
    }
    $step='Задача канала';$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name;$action=New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32/conhost.exe') -Argument ('--headless "'+(Join-Path $channel 'sing-box.exe')+'" run -c "'+$config+'"')
    $triggers=@((New-ScheduledTaskTrigger -AtLogOn -User $user),(New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)))
    $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName RemoteDiskChannel -Action $action -Trigger $triggers -Settings $settings -Principal $principal -Force | Out-Null;Start-ScheduledTask -TaskName RemoteDiskChannel
    $step='Конфигурация движка';$fresh=-not (Test-Path -LiteralPath (Join-Path $state 'config.xml'))
    if($fresh){[void](Invoke-DiskProcess $tray @('syncthing','generate','--home',$state))};Read-DiskState
    $options=@{globalAnnounceEnabled=$false;localAnnounceEnabled=$false;relaysEnabled=$false;natEnabled=$false;autoUpgradeIntervalH=0;reconnectionIntervalS=10;listenAddresses=@(('tcp://127.0.0.1:'+(Get-DiskPort)));startBrowser=$false}
    $running=$false;try{$running=[bool](Invoke-DiskApi 'system/status')}catch{}
    if($running){$options.Remove('listenAddresses');[void](Invoke-DiskApi 'config/options' PATCH $options)}else{
        if($fresh){foreach($folder in @($script:Engine.configuration.SelectNodes('folder'))){[void]$script:Engine.configuration.RemoveChild($folder)};$script:Engine.configuration.gui.address='127.0.0.1:'+(Get-DiskPort)}
        Save-DiskState $options;Read-DiskState
    }
    Write-DiskUtf8 (Join-Path $script:DiskHome 'tray/syncthingtray.ini') (New-DiskIni $tray $state $script:Gui $script:ApiKey);Set-DiskRegistration $true
    $step='Запуск трея';Get-Process -Name syncthingtray -ErrorAction SilentlyContinue|Where-Object {$_.Path -and [IO.Path]::GetFullPath($_.Path) -ieq [IO.Path]::GetFullPath($tray)}|ForEach-Object {Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue;[void]$_.WaitForExit(10000)};$created=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=('"'+$tray+'" --wait')};if($created.ReturnValue -ne 0){throw 'Не удалось запустить трей'}
    $local=$null;for($i=0;$i -lt 40;$i++){try{$local=Invoke-DiskApi 'system/status';if($local.myID){break}}catch{};Start-Sleep -Milliseconds 250};if(-not $local.myID){throw 'Движок не запустился'}
    $step='Подключение устройств';[void](Invoke-DiskApi ('config/devices/'+$remote.deviceId) PUT @{deviceID=$remote.deviceId;name='RemoteDisk Server';addresses=@('tcp://127.0.0.1:22001');autoAcceptFolders=$false})
    [void](Invoke-DiskServer add-device @{deviceId=$local.myID;deviceName=$env:COMPUTERNAME} -Direct);Write-DiskUtf8 (Join-Path $script:DiskHome 'server.txt') $remote.deviceId
    $step='Автоподключение папок'; & (Join-Path $app 'Enable-RemoteDiskFolders.ps1')
    $step='Проверка канала';Wait-DiskChannel
    Write-DiskLog 'Установка';Write-Output ('RemoteDisk установлен. Серверные папки появляются в '+(Get-DiskBase)+'; занятые пути остаются в ожидании.')
}catch{Write-DiskLog $step $_;Write-Error ('Установка RemoteDisk не выполнена: '+$_.Exception.Message+' Проверьте SSH-профиль, доступ к серверу и загрузкам.') -ErrorAction Continue;exit 1}
