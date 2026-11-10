#requires -Version 5.1
# Одна точка входа: SSH-профиль, диск (трей и синхронизация), мост управления (MCP).
# Повторный запуск безопасен: каждый шаг сохраняет существующие настройки.
[CmdletBinding()]
param([string]$Profile,[string]$DiskUser='remoteagents',[switch]$LauncherSetup)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'disk\Disk.Common.ps1')
function Write-Step([string]$Text) {Write-Host '';Write-Host ('=== '+$Text+' ===') -ForegroundColor Cyan}
function Find-RootProfiles {@(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'RemoteAgents\ssh-profiles\*\project-connections\*\ssh-transport.json') -File -ErrorAction SilentlyContinue)}
function Invoke-Child([string]$Script,[string[]]$Arguments) {
    $all=@('-NoLogo','-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot $Script))+$Arguments
    $p=Start-Process powershell.exe -ArgumentList (($all|ForEach-Object {Quote-Disk ([string]$_)}) -join ' ') -NoNewWindow -Wait -PassThru
    $p.ExitCode
}
$results=[ordered]@{}

Write-Step '1. Вход на сервер по SSH'
if(-not $Profile){
    $files=Find-RootProfiles
    if($files.Count -eq 0){
        Write-Host 'SSH-профиля нет. Сейчас откроется настройка входа: укажите сервер и пароль.'
        Write-Host 'Когда вход проверен и появится меню «Работа с сервером», введите 0 и затем 0.'
        [void](Invoke-Child 'setup-vps-ssh.ps1' @())
        $files=Find-RootProfiles
        if($files.Count -eq 0){throw 'SSH-профиль не создан, продолжить нельзя.'}
    }
    if($files.Count -eq 1){$Profile=$files[0].FullName} else {
        for($i=0;$i -lt $files.Count;$i++){$j=Get-Content -LiteralPath $files[$i].FullName -Raw|ConvertFrom-Json;Write-Host ('{0}. {1}@{2}  ({3})' -f ($i+1),$j.login,$j.serverAddress,$files[$i].FullName)}
        $n=0;if(-not [int]::TryParse((Read-Host 'Номер профиля'),[ref]$n) -or $n -lt 1 -or $n -gt $files.Count){throw 'Неверный номер профиля'}
        $Profile=$files[$n-1].FullName
    }
}
$Profile=[IO.Path]::GetFullPath($Profile)
$root=Get-Content -LiteralPath $Profile -Raw|ConvertFrom-Json
Write-Host ('Профиль: {0}@{1}' -f $root.login,$root.serverAddress)
$results['SSH']='готово'

Write-Step ('2. Вход для синхронизации (пользователь '+$DiskUser+')')
$diskProfile=Join-Path $env:LOCALAPPDATA 'RemoteDisk\profile\ssh-transport.json'
$saved=Join-Path $env:LOCALAPPDATA 'RemoteDisk\profile.txt'
if(Test-Path -LiteralPath $saved){$candidate=[IO.File]::ReadAllText($saved).Trim();if(Test-Path -LiteralPath $candidate){$diskProfile=$candidate}}
if($root.login.Trim() -ine 'root'){$diskProfile=$Profile;Write-Host 'Профиль уже входит не под root, используем его.'}
elseif(Test-Path -LiteralPath $diskProfile){Write-Host ('Используем сохранённый профиль диска: '+$diskProfile)}
else{
    if($DiskUser -cnotmatch '^[a-z_][a-z0-9_-]*$' -or $DiskUser -eq 'root'){throw 'Недопустимый -DiskUser'}
    $pub=([IO.File]::ReadAllText($root.keyPath+'.pub')).Trim() -split '\s+'
    if($pub.Count -lt 2 -or $pub[0] -cnotmatch '^ssh-[a-z0-9-]+$' -or $pub[1] -cnotmatch '^[A-Za-z0-9+/=]+$'){throw 'Не удалось прочитать открытый ключ профиля'}
    $line=$pub[0]+' '+$pub[1]+' '+$DiskUser+'-'+$env:COMPUTERNAME.ToLowerInvariant()
    $script="set -eu`nu='$DiskUser'`nh=`$(getent passwd `"`$u`" | cut -d: -f6)`n[ -n `"`$h`" ] || { echo 'Нет пользователя '`$u >&2; exit 1; }`ninstall -d -m 700 -o `"`$u`" -g `"`$u`" `"`$h/.ssh`"`nf=`"`$h/.ssh/authorized_keys`"`ntouch `"`$f`"`ngrep -qF '$($pub[1])' `"`$f`" || printf '%s\n' '$line' >> `"`$f`"`nchown `"`$u:`$u`" `"`$f`"`nchmod 600 `"`$f`"`necho ok`n"
    Write-Host 'Разрешаем этот ключ пользователю на сервере (через вход root)…'
    $out=Invoke-DiskProcess $root.sshExecutable (@('-o','BatchMode=yes','-o','ConnectTimeout=15')+@($root.arguments)+@('bash -s')) $script
    if($out -notmatch 'ok'){throw 'Сервер не подтвердил добавление ключа'}
    $args=@($root.arguments);for($i=0;$i -lt $args.Count-1;$i++){if($args[$i] -ceq '-l'){$args[$i+1]=$DiskUser}}
    $args=@($args|ForEach-Object {([string]$_) -replace '^root@',($DiskUser+'@')})
    $copy=$root|Select-Object *;$copy.login=$DiskUser;$copy.arguments=$args
    [void][IO.Directory]::CreateDirectory((Split-Path $diskProfile -Parent))
    Write-DiskUtf8 $diskProfile ($copy|ConvertTo-Json -Depth 5)
    $who=Invoke-DiskProcess $copy.sshExecutable (@('-o','BatchMode=yes','-o','ConnectTimeout=15')+$args+@('id -un'))
    if($who.Trim() -cne $DiskUser){throw ('Проверка входа '+$DiskUser+' не прошла')}
    Write-Host ('Вход '+$DiskUser+' работает.')
}
$results['Вход для диска']='готово'

Write-Step '3. Диск: трей Syncthing и синхронизация папок'
$code=Invoke-Child 'disk\Install-RemoteDisk.ps1' @('-Profile',$diskProfile)
if($LauncherSetup -and $code -ne 0){throw 'Установка диска не выполнена'}
$results['Диск и трей']=$(if($code -eq 0){'готово'}else{'ОШИБКА (код '+$code+'), см. выше и %LOCALAPPDATA%\RemoteDisk\install.log'})

Write-Step '4. Управление компьютером (MCP-мост)'
$code=Invoke-Child 'Start-WindowsControl.ps1' @('-Install','-Profile',$Profile,'-AgentUser',$(if($root.login -eq 'root'){$DiskUser}else{$root.login}))
if($LauncherSetup -and $code -ne 0){throw 'Установка моста не выполнена'}
$results['Мост управления']=$(if($code -eq 0){'готово'}else{'ОШИБКА (код '+$code+'), см. %LOCALAPPDATA%\RemoteAgents\control\logs\control.log'})

Write-Step 'Итог'
foreach($k in $results.Keys){Write-Host ('{0,-18} {1}' -f $k,$results[$k])}
Write-Host ''
Write-Host 'Всё запускается само при входе в Windows: трей диска, канал, подключение новых папок и мост.'
Write-Host 'Папки с сервера появляются в %USERPROFILE%\Disk в течение 1–2 минут.'
