#requires -Version 5.1
. (Join-Path $PSScriptRoot 'FirstInstall.ps1') -LibraryOnly
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'disk/Disk.Common.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'disk/Disk.Union.ps1')
# All state is observed again. This model is also exercised with fake SSH on Linux.
function Get-WizardPlan($Server,$Local) {
    @(
        @{id='server';ready=[bool]$Server.ssh;repair=(-not $Server.disk -or -not $Server.happier -or -not $Server.bridge -or -not $Server.catalog)}
        @{id='connection';ready=[bool]$Local.transport}
        @{id='disk';ready=([bool]$Local.disk -and [bool]$Server.disk)}
        @{id='happier';ready=[bool]$Local.account}
        @{id='bridge';ready=(-not $Local.bridgeEnabled -or [bool]$Local.bridge)}
        @{id='vpn';ready=(-not $Local.vpnEnabled -or [bool]$Local.vpn)}
    )
}
function Invoke-WizardSsh([string]$Root,[string]$Command,[string]$InputText='',[int]$Timeout=60) {
    $profile=Find-InstallProfile $Root
    if(-not $profile){throw 'Настройте SSH на шаге «Сервер»'}
    $p=Read-TransportJson $profile
    Invoke-DiskProcess $p.sshExecutable (@('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=10')+@($p.arguments)+@($Command)) (Convert-TransportLF $InputText) -TimeoutSeconds $Timeout
}
function Send-WizardHelpers([string]$Root,[string]$Bundle) {
    $upload='set -eu; umask 077;'+"`n"
    $files=@{
        'build/server-wizard.sh'='.local/share/remoteagents-wizard/server-wizard.sh'
        'transport/server-transport-catalog.py'='.local/share/remoteagents-wizard/server-transport-catalog.py'
        'accounts/server-account.mjs'='.local/share/remoteagents-accounts/server-account.mjs'
        'accounts/bootstrap.sh'='.local/share/remoteagents-accounts/bootstrap.sh'
        'disk/server-disk.sh'='.local/share/remote-disk/server-disk.sh'
        'disk/stignore.txt'='.local/share/remote-disk/stignore.txt'
        'disk/legacy-ignores.sha256'='.local/share/remote-disk/legacy-ignores.sha256'
        'codex-windows-bridge.py'='.local/share/codex-remote/codex-windows-bridge.py'
        'codex-bridge-session.py'='.local/share/codex-remote/codex-bridge-session.py'
        'server_node_catalog.py'='.local/share/codex-remote/server_node_catalog.py'
    }
    foreach($key in $files.Keys){
        $dest='$HOME/'+$files[$key];$directory='$HOME/'+(Split-Path $files[$key] -Parent).Replace('\','/')
        $bytes=[Text.Encoding]::UTF8.GetBytes((Convert-TransportLF ([IO.File]::ReadAllText((Join-Path $Bundle $key)))))
        $bridgeHelper=$key -in @('codex-windows-bridge.py','codex-bridge-session.py','server_node_catalog.py')
        if($bridgeHelper){$upload+='if [ ! -f "'+$dest+'" ]; then '+"`n"}
        $temp=$dest+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        $upload+='mkdir -p "'+$directory+'"; test ! -L "'+$dest+'"; printf %s '+[Convert]::ToBase64String($bytes)+' | base64 -d > "'+$temp+'"; mv -f -- "'+$temp+'" "'+$dest+'"'+"`n"
        if($bridgeHelper){$upload+='fi'+"`n"}
    }
    [void](Invoke-WizardSsh $Root 'bash -s' $upload)
}
function Get-WizardServer([string]$Root,[string]$Bundle) {
    # Read-only script is streamed, so observing a configured server installs nothing.
    $text=Invoke-WizardSsh $Root 'bash -s' ([IO.File]::ReadAllText((Join-Path $Bundle 'build/server-wizard.sh')))
    $server=ConvertFrom-Json (Convert-TransportLF $text);$server|Add-Member -Force ssh $true;return $server
}
function Get-WizardCatalog([string]$Root,[string]$Bundle) {
    $source=Convert-TransportLF ([IO.File]::ReadAllText((Join-Path $Bundle 'transport/server-transport-catalog.py')))
    $text=Invoke-WizardSsh $Root 'python3 -' $source
    $catalog=ConvertFrom-Json (Convert-TransportLF $text)
    Assert-WizardCatalog $catalog
    return $catalog
}
function Assert-WizardCatalog($Catalog) {
    if($Catalog.schema -ne 1){throw 'Неизвестная схема каталога'}
    # A deliberately narrow public schema prevents a secret or a Windows private path in shared settings.
    $fields=@{entries=@('name','ssh','enabled','kinds');hops=@('name','ssh','enabled','hostKey');relays=@('name','host','port','enabled');cdn=@('name','domain','entry','path','enabled')}
    foreach($property in $Catalog.PSObject.Properties){if($property.Name -notin @('schema','entries','hops','relays','cdn')){throw 'В каталоге недопустимое поле'}}
    foreach($group in $fields.Keys){
        foreach($row in @($Catalog.$group)){
            if($null -eq $row){continue}
            foreach($property in $row.PSObject.Properties){if($property.Name -notin $fields[$group]){throw 'Каталог содержит приватное или неизвестное поле'}}
            foreach($value in @($row.PSObject.Properties.Value)){if($value -is [string] -and ($value -match '[\x00-\x1f]' -or $value.Length -gt 512)){throw 'Неверное значение каталога'}}
        }
    }
    Assert-TransportLists $Catalog
}
function Merge-WizardCatalog($Server,$Local) {
    Assert-WizardCatalog $Server;Assert-WizardCatalog $Local
    $result=[pscustomobject]@{schema=1}
    foreach($group in @('entries','hops','relays','cdn')){
        $rows=@($Server.$group|Where-Object {$null -ne $_})
        foreach($row in @($Local.$group|Where-Object {$null -ne $_})){$rows=@($rows|Where-Object {$_.name -cne $row.name})+@($row)}
        $result|Add-Member $group $rows
    }
    Assert-WizardCatalog $result;return $result
}
function Get-WizardPublicTransport($Transport) {
    $out=[pscustomobject]@{schema=1}
    foreach($g in @('entries','hops','relays','cdn')){
        $rows=@();foreach($row in @($Transport.$g)){if($null -ne $row -and -not $row.legacyOutbound){$copy=$row|Select-Object * -ExcludeProperty configPath;$rows+=@($copy)}}
        $out|Add-Member $g $rows
    };return $out
}
function Register-WizardRollback([string]$Root,[string]$Bundle,[string]$Kind,[string]$Session,[string]$Task) {
    # Recovery is independent of both the UI and the prunable current bundle.
    $recovery=Join-Path $Root ('state/wizard-recovery/'+$Session)
    foreach($name in @('build/Wizard.ps1','build/Wizard.Common.ps1','build/FirstInstall.ps1','build/Migrate.Common.ps1','transport/Transport.Common.ps1','disk/Disk.Common.ps1','disk/Disk.Union.ps1','disk/Disk.Selective.ps1','disk/stignore.txt','disk/legacy-ignores.sha256')){
        $dest=Join-Path $recovery $name;[void][IO.Directory]::CreateDirectory((Split-Path $dest -Parent))
        Copy-Item -LiteralPath (Join-Path $Bundle $name) -Destination $dest
    }
    $args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $recovery 'build/Wizard.ps1'),'-Home',$Root,'-Action',('Rollback'+$Kind),'-Session',$Session)
    $action=New-ScheduledTaskAction -Execute (Get-TransportPowerShell) -Argument (($args|ForEach-Object {Quote-Transport $_}) -join ' ')
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $Task -Action $action -Trigger @((New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(3)),(New-ScheduledTaskTrigger -AtLogOn -User $user)) -Principal $principal -Settings $settings -Force|Out-Null
    $registered=Get-MigrationTask $Task
    if(-not $registered.exists -or -not $registered.enabled){throw 'Не зарегистрирован независимый откат настроек'}
}
function Get-WizardBridgeCommand([string]$Root,[string]$Run) {
    if($Run){return $Run}
    # A manually started bridge may have no Run entry; retain its actual command too.
    foreach($base in @((Join-Path $Root 'managed-control'),(Join-Path $env:LOCALAPPDATA 'RemoteAgents/control'))){
        $pidFile=Join-Path $base 'control.pid';if(-not (Test-Path $pidFile)){continue}
        $id=0;if(-not [int]::TryParse([IO.File]::ReadAllText($pidFile).Trim(),[ref]$id)){continue}
        $process=Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop
        if($process -and $process.CommandLine -match 'Start-WindowsControl\.ps1'){return [string]$process.CommandLine}
    }
    return ''
}
function Undo-WizardBridge([string]$Root,[string]$Session) {
    $file=Join-Path $Root 'state/wizard-bridge.json';if(-not (Test-Path $file)){return}
    $receipt=Read-TransportJson $file;if($receipt.session -cne $Session){return}
    # Restore intent first, so the launcher cannot restart the rejected version.
    Update-MigrationConfig $Root {param($c)
        if($null -ne $receipt.bridge){$c|Add-Member -Force bridge $receipt.bridge}else{$c.PSObject.Properties.Remove('bridge')}
        if($null -ne $receipt.control){Set-MigrationDefault $c components ([pscustomobject]@{});$c.components|Add-Member -Force control $receipt.control}else{if($c.components){$c.components.PSObject.Properties.Remove('control')}}
    }
    Stop-MigrationControl $Root
    $config=Join-Path $env:LOCALAPPDATA 'RemoteAgents/control/config.json'
    if($null -ne $receipt.controlConfig){Write-TransportJson $config $receipt.controlConfig -Durable}else{if(Test-Path $config){Remove-Item -LiteralPath $config -Force}}
    Set-MigrationRun 'RemoteAgentsControl' $receipt.run
    $command=$receipt.run;if($receipt.command){$command=$receipt.command};Start-MigrationRun $command
    Remove-Item -LiteralPath $file -Force
    Unregister-ScheduledTask -TaskName $receipt.task -Confirm:$false -ErrorAction SilentlyContinue
}
function Set-WizardBridge([string]$Root,[string]$Bundle,[bool]$Enabled,[bool]$Shell) {
    $file=Join-Path $Root 'state/wizard-bridge.json'
    if(Test-Path $file){throw 'Есть незавершённая настройка моста; дождитесь отката'}
    $config=Read-TransportJson (Join-Path $Root 'config.json')
    # Prove the requested policy without changing the currently working intent.
    if($Enabled -and (Test-WizardBridge $Root) -and $config.bridge -and $config.bridge.enabled -eq $Enabled -and $config.bridge.allowShell -eq $Shell){return}
    $task='RemoteAgents bridge rollback '+(Get-TransportFingerprint 'settings' $Root.ToLowerInvariant()).Substring(0,16)
    $session=[guid]::NewGuid().ToString('N');$oldControl=$null
    $oldFile=Join-Path $env:LOCALAPPDATA 'RemoteAgents/control/config.json';if(Test-Path $oldFile){$oldControl=Read-TransportJson $oldFile}
    $run=Get-MigrationRun 'RemoteAgentsControl';$command=Get-WizardBridgeCommand $Root $run
    Write-TransportJson $file @{schema=1;session=$session;task=$task;bridge=$config.bridge;control=$config.components.control;run=$run;command=$command;controlConfig=$oldControl} -Private -Durable
    try{Register-WizardRollback $Root $Bundle Bridge $session $task}catch{Remove-Item -LiteralPath $file -Force;throw}
    try{
        Update-MigrationConfig $Root {param($c)
            $c|Add-Member -Force bridge ([pscustomobject]@{enabled=$Enabled;allowShell=$Shell})
            Set-MigrationDefault $c components ([pscustomobject]@{});Set-MigrationDefault $c.components control ([pscustomobject]@{});$c.components.control|Add-Member -Force enabled $Enabled
        }
        # The old and managed executors share a mutex. Stop the old owner only
        # after recovery is armed, and restore its exact Run command on failure.
        Invoke-InstallChild $Bundle 'Start-WindowsControl.ps1' @('-Uninstall','-KeepState')
        $args=@('-LauncherHome',$Root)
        if($Enabled){$args+=@('-Install','-Profile',(Find-InstallProfile $Root))}else{$args+=@('-Uninstall')}
        Invoke-InstallChild $Bundle 'Start-WindowsControl.ps1' $args
        if($Enabled -and -not (Test-WizardBridge $Root)){throw 'Новый мост не подтверждён; прежние настройки восстанавливаются'}
        Remove-Item -LiteralPath $file -Force
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
    }catch{Undo-WizardBridge $Root $session;throw}
}
function Test-WizardNetworkManaged([string]$Root) {
    if(Test-MigrationFresh $Root transport){return $true}
    $state=Get-MigrationStatePath $Root
    # A dead heartbeat must never turn off preflight/rollback for an installed PC.
    if(Test-Path $state){if((Read-TransportJson $state).phase -in @('accepted','pending','activating')){return $true}}
    return $false
}
function Test-WizardNetworkProof([string]$Root,[DateTime]$Mark) {
    $status=Join-Path $Root 'status/transport.json'
    if(-not (Test-Path $status) -or (Get-Item $status).LastWriteTimeUtc -le $Mark -or -not (Test-MigrationFresh $Root transport)){return $false}
    $observed=Read-TransportJson $status
    if($observed.configError -or $observed.configRevision -cne (Get-TransportRevision $Root)){return $false}
    $config=Read-TransportJson (Join-Path $Root 'config.json')
    return Test-MigrationSsh $Root ([int](Get-TransportValue $config.transport 'sshPort' 2222))
}
function Set-WizardNetwork([string]$Root,[string]$Bundle,$Transport) {
    # Separate ports and real SSH check BEFORE touching the working daemon.
    if(Test-Path (Join-Path $Root 'state/wizard-network.json')){throw 'Есть незавершённая настройка связи; дождитесь отката'}
    $candidate=Read-TransportJson (Join-Path $Root 'config.json');$candidate|Add-Member -Force transport $Transport
    Invoke-MigrationPreflight $Root $Bundle $candidate
    $file=Join-Path $Root 'state/wizard-network.json';$session=[guid]::NewGuid().ToString('N')
    $previous=(Read-TransportJson (Join-Path $Root 'config.json')).transport
    $task='RemoteAgents settings rollback '+(Get-TransportFingerprint 'settings' $Root.ToLowerInvariant()).Substring(0,16)
    Write-TransportJson $file @{schema=1;session=$session;previous=$previous;task=$task} -Private -Durable
    try{Register-WizardRollback $Root $Bundle Network $session $task}catch{Remove-Item -LiteralPath $file -Force;throw}
    try{
        $mark=[DateTime]::UtcNow
        Update-MigrationConfig $Root {param($c) $c|Add-Member -Force transport $Transport}
        $healthy=$false
        for($i=0;$i -lt 90;$i++){
            if(Test-WizardNetworkProof $Root $mark){$healthy=$true;break}
            Start-Sleep -Seconds 1
        }
        if(-not $healthy){throw 'Новая связь не подтверждена; настройки возвращены'}
        # Clear receipt before unregister; a late task cannot undo a confirmed transaction.
        Remove-Item -LiteralPath $file -Force
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
    }catch{Undo-WizardNetwork $Root $session;throw}
}
function Undo-WizardNetwork([string]$Root,[string]$Session) {
    $file=Join-Path $Root 'state/wizard-network.json';if(-not (Test-Path $file)){return}
    $receipt=Read-TransportJson $file;if($receipt.session -cne $Session){return}
    Update-MigrationConfig $Root {param($c) $c|Add-Member -Force transport $receipt.previous}
    Remove-Item -LiteralPath $file -Force
    Unregister-ScheduledTask -TaskName $receipt.task -Confirm:$false -ErrorAction SilentlyContinue
}
function Test-WizardBridge([string]$Root) {
    try {
        $hostId=Split-Path (Split-Path (Find-InstallProfile $Root) -Parent) -Leaf
        $config=Read-TransportJson (Join-Path $Root 'config.json')
        $expected=@{hostId=$hostId;workspace=(Join-Path $env:LOCALAPPDATA 'RemoteAgents/control/workspace');allowShell=[bool]$config.bridge.allowShell}
        $data=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($expected|ConvertTo-Json -Compress)))
        $code=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-MigrationBridgeProbe)))
        $reply=Invoke-WizardSsh $Root ('python3 -c ''import base64;exec(base64.b64decode("'+$code+'"))'' '''+$data+'''')
        return $reply.Trim() -ceq 'migration-bridge-ok'
    }catch{return $false}
}
function Invoke-WizardStep([string]$Root,[string]$Bundle,[string]$Action,$Request) {
    $diskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk';$script:DiskHome=$diskHome
    switch($Action){
        'Server' {
            $profile=Find-InstallProfile $Root
            if($profile){
                $p=Read-TransportJson $profile
                if(($Request.address -and $Request.address -cne $p.serverAddress) -or ($Request.login -and $Request.login -cne $p.login)){throw 'Сначала отключите диск и перенесите профиль: смена сервера не должна соединять чужие файлы. Существующий сервер сохранён'}
            }else{
                Invoke-InstallChild $Bundle 'setup-vps-ssh.ps1' @('-ServerAddress',[string]$Request.address,'-Login',[string]$Request.login,'-ProfileName',[string]$Request.address,'-DataDir',(Join-Path $Root 'ssh-profiles'),'-SetupOnly')
                $profile=Find-InstallProfile $Root;if(-not $profile){throw 'Ключ SSH не создан'}
            }
            $p=Read-TransportJson $profile
            if($p.login -ieq 'root'){throw 'Укажите рабочего пользователя SSH, не root. Администратор сервера должен создать пользователя и разрешить вход ключом'}
            $server=Get-WizardServer $Root $Bundle
            if($Request.installMissing){
                Send-WizardHelpers $Root $Bundle
                $flags=@([int](-not $server.disk),[int](-not $server.happier),[int](-not $server.catalog)) -join ' '
                try{[void](Invoke-WizardSsh $Root ('bash "$HOME/.local/share/remoteagents-wizard/server-wizard.sh" repair '+$flags) '' 110)}catch{
                    $observed=Get-WizardServer $Root $Bundle
                    if(-not $observed.userManager){throw 'Нет user systemd. Администратору: sudo loginctl enable-linger <пользователь>; sudo systemctl start user@<uid>.service. Повторите проверку'}
                    throw 'Установка не завершена. Нужны curl, tar, flock, python3, systemd и доступ к официальным загрузкам; проверьте сервер и повторите шаг'
                }
                $server=Get-WizardServer $Root $Bundle
            }
            if(-not $server.userManager){throw 'Нет user systemd. Администратору сервера: sudo loginctl enable-linger <пользователь>; sudo systemctl start user@<uid>.service. Затем повторите шаг'}
            return $server
        }
        'Catalog' {return Get-WizardCatalog $Root $Bundle}
        'Connection' {
            $server=Get-WizardCatalog $Root $Bundle;$local=$Request.catalog
            Assert-WizardCatalog $local
            $file=Join-Path $Root 'config.json';$config=Read-TransportJson $file
            $t=Copy-TransportObject $config.transport;if(-not $t){$t=[pscustomobject]@{}}
            foreach($g in @('entries','hops','relays','cdn')){
                # Preserve H's opaque legacy references: they are local and never published.
                $legacy=@($t.$g|Where-Object {$_.legacyOutbound})
                $rows=@();foreach($row in @($local.$g)){
                    $copy=Copy-TransportObject $row
                    $existing=@($t.$g|Where-Object {$_.name -ceq $row.name -and $_.configPath})
                    if($existing.Count){$copy|Add-Member -Force configPath ([string]$existing[0].configPath)}
                    $rows+=@($copy)
                }
                $t|Add-Member -Force $g ($rows+$legacy)
            }
            if($Request.shared){
                # CAS must succeed before any local route changes. A concurrent editor
                # cannot leave this computer on a catalog which failed publication.
                Send-WizardHelpers $Root $Bundle
                $payload=@{expected=$Request.expected;catalog=$local}|ConvertTo-Json -Depth 30 -Compress
                [void](Invoke-WizardSsh $Root 'python3 "$HOME/.local/share/remoteagents-wizard/server-transport-catalog.py" put' $payload)
            }
            try{
                if(Test-WizardNetworkManaged $Root){Set-WizardNetwork $Root $Bundle $t}
                else{Update-MigrationConfig $Root {param($c) $c|Add-Member -Force transport $t}}
            }catch{
                if($Request.shared){
                    try{
                        $restore=@{expected=$local;catalog=$server}|ConvertTo-Json -Depth 30 -Compress
                        [void](Invoke-WizardSsh $Root 'python3 "$HOME/.local/share/remoteagents-wizard/server-transport-catalog.py" put' $restore)
                    }catch{Write-MigrationLog $Root 'wizard.catalog.restore.failed'}
                }
                throw
            }
            $overlay=[pscustomobject]@{schema=1}
            foreach($g in @('entries','hops','relays','cdn')){
                $different=@();foreach($row in @($local.$g)){
                    $original=@($server.$g|Where-Object {$_.name -ceq $row.name})
                    if(-not $original.Count -or (ConvertTo-Json -InputObject $row -Depth 20 -Compress) -cne (ConvertTo-Json -InputObject $original[0] -Depth 20 -Compress)){$different+=@($row)}
                };$overlay|Add-Member $g $different
            }
            if($Request.shared){$overlay=[pscustomobject]@{schema=1;entries=@();hops=@();relays=@();cdn=@()}}
            Update-MigrationConfig $Root {param($c) Set-MigrationDefault $c wizard ([pscustomobject]@{});$c.wizard|Add-Member -Force localCatalog $overlay}
            return @{ok=$true;summary='Каталог сохранён; работоспособность пути проверяется отдельно'}
        }
        'DiskTree' {
            Send-WizardHelpers $Root $Bundle
            $relative=[string]$Request.path
            $command=Get-DiskTreeCommand $relative
            $server=ConvertFrom-Json (Convert-TransportLF (Invoke-WizardSsh $Root $command))
            $base=[string]$Request.base;if(-not $base){$base=Get-DiskBase}
            $union=Get-DiskUnion $server $base $relative;$selection=Read-DiskSelection
            if($null -eq $selection){$selection=@{schema=1;paths=@($union.rows|Where-Object {$_.path -notmatch '/' -and $_.kind -eq 'directory'}|ForEach-Object {$_.path})}}
            return @{union=$union;selection=$selection;base=$base}
        }
        'Disk' {
            $base=[IO.Path]::GetFullPath([string]$Request.base)
            $profile=Find-InstallProfile $Root
            if(Test-Path (Join-Path $diskHome 'state/config.xml')){
                Read-DiskState
                [void](Set-DiskBase $base)
            }
            [void][IO.Directory]::CreateDirectory($diskHome);[void][IO.Directory]::CreateDirectory($base)
            Write-DiskUtf8 (Join-Path $diskHome 'base.txt') $base
            $choice=Join-Path $Root 'state/wizard-selection.json';Write-TransportJson $choice @{schema=1;paths=@($Request.paths)}
            $needsInstall= -not (Test-Path (Join-Path $diskHome 'state/config.xml')) -or -not (Test-Path (Join-Path $diskHome 'channel/config.json')) -or -not (Test-Path (Join-Path $diskHome 'tray/syncthingtray.exe'))
            if(-not $needsInstall){try{Read-DiskState;$probe=Invoke-DiskApi 'system/status';$needsInstall= -not $probe.myID}catch{$needsInstall=$true}}
            if($needsInstall){
                # Install starts the old autoaccept worker: freeze selection until explicit Apply below.
                if(-not (Test-Path (Join-Path $diskHome 'selection.json'))){Write-TransportJson (Join-Path $diskHome 'selection.json') @{schema=1;paths=@()}}
                Invoke-InstallChild $Bundle 'disk/Install-RemoteDisk.ps1' @('-Profile',$profile)
            }
            Read-DiskState;$local=Invoke-DiskApi 'system/status';if(-not $local.myID){throw 'Syncthing не отвечает; повторите установку диска'}
            Invoke-InstallChild $Bundle 'disk/Select-Disk.ps1' @('-Home',$Root,'-Action','Apply','-SelectionFile',$choice)
            return @{ok=$true;summary='Выбор применён; передача файлов продолжается. Это ещё не подтверждение завершённой синхронизации'}
        }
        'AccountList' {
            # Public adapter only, no vendor/bootstrap/login needed to list account names.
            Send-WizardHelpers $Root $Bundle
            $text=Invoke-WizardSsh $Root 'export PATH="$HOME/.local/share/remoteagents-accounts/node:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"; node "$HOME/.local/share/remoteagents-accounts/server-account.mjs"' '{"action":"list"}'
            return ConvertFrom-Json (Convert-TransportLF $text)
        }
        'Account' {
            if(-not $Request.label){throw 'Укажите имя аккаунта'}
            $oldConfig=Read-TransportJson (Join-Path $Root 'config.json');$previous=$oldConfig.happier
            $oldState=$null;$stateFile=Join-Path $Root 'state/happier-account.json';if(Test-Path $stateFile){$oldState=Read-TransportJson $stateFile}
            try{
                Update-MigrationConfig $Root {param($c) $c|Add-Member -Force happier ([pscustomobject]@{serverUrl=$Request.serverUrl;webappUrl=$Request.webappUrl;label=$Request.label})}
                Invoke-InstallChild $Bundle 'accounts/Account.ps1' @('-Home',$Root,'-ExpectedAccount',[string]$Request.expectedAccount)
                return Read-TransportJson (Join-Path $Root 'state/happier-account.json')
            }catch{
                Update-MigrationConfig $Root {param($c) if($null -ne $previous){$c|Add-Member -Force happier $previous}else{$c.PSObject.Properties.Remove('happier')}}
                if($oldState -and $oldState.account){$oldState|Add-Member -Force ok $false;$oldState|Add-Member -Force summary 'Предыдущий аккаунт сохранён; повторите живую проверку после неудачной попытки';Write-TransportJson $stateFile $oldState}
                throw
            }
        }
        'Bridge' {
            Set-WizardBridge $Root $Bundle ([bool]$Request.enabled) ([bool]$Request.shell)
            return @{ok=$true;summary=$(if($Request.enabled){'Мост и разрешение shell проверены'}else{'Запрос выключения выполнен'})}
        }
        'Vpn' {
            $previous=(Read-TransportJson (Join-Path $Root 'config.json')).vpn
            $changed=([string]$previous.checkUrl -cne [string]$Request.checkUrl) -or ([string]$previous.dnsServer -cne [string]$Request.dnsServer)
            if($Request.enabled -and $previous.enabled -and $changed){throw 'Сначала выключите VPN и дождитесь очистки наших маршрутов, затем измените DNS/адрес проверки и включите снова. Работающий VPN сохранён'}
            if($Request.enabled){
                $uri=$null
                if(-not [Uri]::TryCreate([string]$Request.checkUrl,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or -not $Request.dnsServer){throw 'Укажите свой HTTPS-адрес проверки без пароля и выбранный DNS для VPN'}
                if(-not $changed -and $previous.enabled -and (Test-MigrationFresh $Root vpn)){return @{ok=$true;summary='VPN уже включён и проверен; действующая сессия сохранена'}}
            }
            Update-MigrationConfig $Root {param($c)
                Set-MigrationDefault $c vpn ([pscustomobject]@{enabled=$false})
                foreach($key in @('checkUrl','dnsServer')){if($Request.$key){$c.vpn|Add-Member -Force $key ([string]$Request.$key)}}
            }
            try{
                if($Request.enabled){
                    $conflict=ConvertFrom-Json (& (Join-Path $Bundle 'transport/Test-VpnConflict.ps1') -Home $Root|Out-String)
                    if($conflict.conflict){throw 'Работает другой VPN. Отключите его сами и повторите проверку; RemoteAgents не менял чужой VPN'}
                    Invoke-InstallChild $Bundle 'transport/Vpn.Tun.ps1' @('-Home',$Root,'-Enable')
                    return @{ok=$false;summary='Запрос VPN передан. Дождитесь живого статуса TUN; включение ещё не подтверждено'}
                }
                if($previous.enabled){Invoke-InstallChild $Bundle 'transport/Vpn.Tun.ps1' @('-Home',$Root,'-Disable')}
                return @{ok=$true;summary='VPN выключен в настройках; состояние маршрутов — в живом статусе VPN'}
            }catch{
                Update-MigrationConfig $Root {param($c) if($null -ne $previous){$c|Add-Member -Force vpn $previous}else{$c.PSObject.Properties.Remove('vpn')}}
                throw
            }
        }
        'Inspect' {
            $server=Get-WizardServer $Root $Bundle
            $config=Read-TransportJson (Join-Path $Root 'config.json')
            $disk=$false
            try{Read-DiskState;$engine=Invoke-DiskApi 'system/status';$peer=[IO.File]::ReadAllText((Join-Path $diskHome 'server.txt')).Trim();$connections=Invoke-DiskApi 'system/connections';$disk=[bool]($engine.myID -and $connections.connections.PSObject.Properties[$peer].Value.connected)
                if($disk){foreach($folder in @(Invoke-DiskApi 'config/folders')){if(@($folder.devices|Where-Object {$_.deviceID -ceq $peer}).Count){Assert-SelectionSynced (Invoke-DiskApi ('db/status?folder='+[Uri]::EscapeDataString($folder.id)))}}}
            }catch{$disk=$false}
            $account=$false
            $state=Join-Path $Root 'state/happier-account.json'
            if(Test-Path $state){
                $id=[string](Read-TransportJson $state).account
                if($id -cmatch '^[a-f0-9]{64}$'){
                    try{
                        $request=@{action='inspect';account=$id}|ConvertTo-Json -Compress
                        $out=Invoke-WizardSsh $Root 'export PATH="$HOME/.local/share/remoteagents-accounts/node:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"; node "$HOME/.local/share/remoteagents-accounts/server-account.mjs"' $request
                        $account=[bool](ConvertFrom-Json (Convert-TransportLF $out)).ok
                    }catch{}
                }
            }
            $bridgeIntent=[bool]$config.bridge.enabled;if(-not $config.bridge){$bridgeIntent=[bool]$config.components.control.enabled -or (Test-Path (Join-Path $Root 'control/config.json'))}
            $local=[pscustomobject]@{transport=(Test-WizardNetworkProof $Root ([DateTime]::UtcNow.AddSeconds(-15)));disk=$disk;account=$account;bridgeEnabled=$bridgeIntent;bridge=(Test-WizardBridge $Root);vpnEnabled=[bool]$config.vpn.enabled;vpn=(Test-MigrationFresh $Root vpn)}
            $plan=@(Get-WizardPlan $server $local)
            return @{ok=(@($plan|Where-Object {-not $_.ready}).Count -eq 0);steps=$plan;summary='Живое состояние проверено сейчас. Отсутствующая связь и незавершённая передача не считаются готовностью';phase=$(if(Test-Path (Get-MigrationStatePath $Root)){(Read-TransportJson (Get-MigrationStatePath $Root)).phase}else{'not-started'})}
        }
        'Activate' {
            Update-MigrationConfig $Root {param($c) Set-MigrationDefault $c wizard ([pscustomobject]@{});$c.wizard|Add-Member -Force configured $true}
            if(-not (Test-Path (Join-Path $Root 'RemoteAgents.exe'))){return @{ok=$false;summary='Общие настройки сохранены. Для запуска связи откройте RemoteAgents.exe; второй мастер не потребуется. Пока связь не проверена'}}
            # Existing migration owns the independent rollback, preflight and legacy H import.
            Invoke-InstallChild $Bundle 'build/Migrate.ps1' @('-Home',$Root)
            return @{ok=$false;summary='Переход запущен. Дождитесь трёх зелёных минут и подтверждения в трее; до этого возможен автоматический откат'}
        }
        default {throw 'Неизвестный шаг мастера'}
    }
}

function Invoke-WizardLock([string]$Root,[scriptblock]$Body,[int]$TimeoutMs=1000) {
    $mutex=New-Object Threading.Mutex($false,('Global\RemoteAgentsSettings-'+(Get-TransportFingerprint 'settings' $Root.ToLowerInvariant())))
    $locked=$false
    try{
        try{$locked=$mutex.WaitOne($TimeoutMs)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){throw 'Настройки уже применяются; повторите после завершения'}
        & $Body
    }finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
