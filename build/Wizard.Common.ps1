#requires -Version 5.1
. (Join-Path $PSScriptRoot 'Setup.Common.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'disk/Disk.Common.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'disk/Disk.Union.ps1')
. (Join-Path $PSScriptRoot 'Wizard.Server.ps1')
. (Join-Path $PSScriptRoot 'Wizard.Engine.ps1')
. (Join-Path $PSScriptRoot 'Wizard.Session.ps1')
. (Join-Path $PSScriptRoot 'Wizard.Bootstrap.ps1')
. (Join-Path $PSScriptRoot 'Wizard.Refresh.ps1')
. (Join-Path $PSScriptRoot 'Wizard.Lan.ps1')
. (Join-Path $PSScriptRoot 'Wizard.Network.ps1')
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
    $routeOptions=if($script:WizardRoute){@($script:WizardRoute.options)}else{@(Get-TransportSavedRouteOptions $Root $p)}
    if($env:REMOTEAGENTS_WIZARD_SESSION -eq '1'){return Invoke-WizardControlSession $Root $p $routeOptions $Command $InputText $Timeout}
    Invoke-DiskProcess $p.sshExecutable ($routeOptions+@('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=5')+@($p.arguments)+@($Command)) (Convert-TransportLF $InputText) -TimeoutSeconds $Timeout
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
        'disk/stignore-previous.sha256'='.local/share/remote-disk/stignore-previous.sha256'
        'codex-windows-bridge.py'='.local/share/codex-remote/codex-windows-bridge.py'
        'codex-bridge-session.py'='.local/share/codex-remote/codex-bridge-session.py'
        'server_node_catalog.py'='.local/share/codex-remote/server_node_catalog.py'
    }
    # Query content hashes first; unchanged helper bytes never cross SSH again.
    $manifest=@();$contents=@{}
    foreach($key in $files.Keys){
        $bytes=[Text.Encoding]::UTF8.GetBytes((Convert-TransportLF ([IO.File]::ReadAllText((Join-Path $Bundle $key)))))
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        $contents[$key]=@{bytes=$bytes;hash=$hash}
        $manifest+=@{source=$key;path=$files[$key];hash=$hash;keep=($key -in @('codex-windows-bridge.py','codex-bridge-session.py','server_node_catalog.py'))}
    }
    $probe=@'
import json,sys,hashlib,os,base64
from pathlib import Path
rows=json.loads(base64.b64decode("MANIFEST_BASE64"));missing=[]
for row in rows:
 p=Path.home()/row['path']
 if any(x.is_symlink() for x in (p,*p.parents)):raise ValueError('symlink')
 if not p.is_file() or (not row['keep'] and hashlib.sha256(p.read_bytes()).hexdigest()!=row['hash']):missing.append(row['source'])
print(json.dumps(missing))
'@
    $json=ConvertTo-Json -InputObject @($manifest) -Depth 5 -Compress
    $probe=$probe.Replace('MANIFEST_BASE64',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)))
    $code=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($probe))
    $reply=Invoke-WizardSsh $Root ('python3 -c ''import base64;exec(base64.b64decode("'+$code+'"))''')
    if([string]::IsNullOrWhiteSpace($reply)){$reply=ConvertTo-Json -InputObject @($files.Keys) -Compress}
    $received=ConvertFrom-Json (Convert-TransportLF $reply);$missing=@()
    foreach($item in $received){if($null -ne $item){$missing+=[string]$item}}
    if(-not $missing.Count){return}
    foreach($key in $files.Keys){
        if($key -notin $missing){continue}
        $dest='$HOME/'+$files[$key];$directory='$HOME/'+(Split-Path $files[$key] -Parent).Replace('\','/')
        $bytes=$contents[$key].bytes
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
    $server=ConvertFrom-Json (Convert-TransportLF $text);$server|Add-Member -Force ssh $true
    if($server.operations){Add-WizardOperationText $server.operations}
    return $server
}
function Add-WizardOperationText($Operations) {
    foreach($p in @($Operations.PSObject.Properties)){$title=if($p.Name -eq 'disk'){'установка сервера диска'}else{'установка Happier'};$p.Value|Add-Member -Force text (Get-WizardOperationText $p.Value $title)}
}
function Get-WizardOperation([string]$Root,[string]$Bundle,[string]$Verb,[string[]]$Operations) {
    # Long server installs run detached (server-wizard.sh start/run); the window only makes short calls.
    foreach($op in $Operations){if($op -notin @('happier','disk')){throw 'Неизвестная операция сервера'}}
    if($Verb -eq 'status'){
        # Read-only and streamed: works before the helpers are uploaded.
        $text=Invoke-WizardSsh $Root ('bash -s -- status '+($Operations -join ' ')) ([IO.File]::ReadAllText((Join-Path $Bundle 'build/server-wizard.sh'))) 30
    }else{
        $text=Invoke-WizardSsh $Root ('bash "$HOME/.local/share/remoteagents-wizard/server-wizard.sh" '+$Verb+' '+$Operations[0]) '' 60
    }
    return ConvertFrom-Json (Convert-TransportLF $text)
}
function Get-WizardOperationText($Status,[string]$Title) {
    # Only observed facts: state, current step and elapsed time; no invented forecast.
    $minutes=[int][Math]::Floor([double]$Status.elapsedSec/60)
    $elapsed=if($minutes -lt 1){'меньше минуты'}else{[string]$minutes+' мин'}
    switch([string]$Status.state){
        'running' {
            $stage=if([int]$Status.stages -gt 0){', этап '+[int]$Status.stage+' из '+[int]$Status.stages}else{''}
            $step=if($Status.step){': '+$Status.step}else{''}
            return 'Идёт '+$Title+' на сервере'+$stage+$step+' (прошло '+$elapsed+'). Можно настраивать дальше — раздел завершится сам'
        }
        'finished' {return ($Title.Substring(0,1).ToUpper()+$Title.Substring(1))+' на сервере завершена ('+$elapsed+')'}
        'failed' {return 'Ошибка: '+$Title+' на сервере не выполнена: '+[string]$Status.reason+'. Повторите шаг'}
        default {return ''}
    }
}
function Get-WizardPendingAccount([string]$Root) {
    $file=Join-Path $Root 'state/happier-pending.json'
    if(Test-Path -LiteralPath $file){return Read-TransportJson $file};return $null
}
function Invoke-WizardAccount([string]$Root,[string]$Bundle,$Request,[bool]$Explicit) {
    # The pending request is public; the key waits only in secrets/happier-pending.key.
    $pendingFile=Join-Path $Root 'state/happier-pending.json'
    $secrets=Join-Path $Root 'secrets';$keyFile=Join-Path $secrets 'happier-account.key';$pendingKey=Join-Path $secrets 'happier-pending.key'
    if($Explicit){
        if(-not $Request.label){throw 'Укажите имя аккаунта'}
        if(-not (Test-Path -LiteralPath $pendingKey) -and -not (Test-Path -LiteralPath $keyFile)){throw 'Вставьте секретный ключ аккаунта или выберите «Создать новый аккаунт»'}
        Write-TransportJson $pendingFile @{schema=1;label=[string]$Request.label;serverUrl=[string]$Request.serverUrl;webappUrl=[string]$Request.webappUrl;expectedAccount=[string]$Request.expectedAccount;requestedUtc=[DateTime]::UtcNow.ToString('o')}
    }else{
        $Request=Get-WizardPendingAccount $Root
        if(-not $Request){return @{ok=$true;idle=$true;summary='Нет отложенного подключения Happier'}}
    }
    Send-WizardHelpers $Root $Bundle
    # Explicit apply starts (or retries) the install; automatic resume only observes it.
    if($Explicit){$op=Get-WizardOperation $Root $Bundle 'ensure' @('happier')}
    else{
        $op=(Get-WizardOperation $Root $Bundle 'status' @('happier')).happier
        $installed=Invoke-WizardSsh $Root 'test -x "$HOME/.local/bin/happier" && systemctl --user show-environment >/dev/null 2>&1 && echo yes || echo no' '' 30
        $op|Add-Member -Force ready ($installed.Trim() -eq 'yes' -and $op.state -ne 'running')
    }
    if(-not $op.ready){
        if($op.state -eq 'failed'){throw ('Установка Happier на сервере не выполнена: '+[string]$op.reason+'. Нажмите «Применить», чтобы повторить; ключ сохранён')}
        if($op.state -ne 'running'){throw 'Happier на сервере не установлен. Нажмите «Применить», чтобы установить; ключ сохранён'}
        return @{ok=$false;pending='happier';operation=$op;summary=(Get-WizardOperationText $op 'установка Happier')+'. Подключение аккаунта применится автоматически'}
    }
    Write-WizardProgress 'Happier на сервере установлен. Подключаю аккаунт…'
    $previousKey=$null;if(Test-Path -LiteralPath $keyFile){$previousKey=[IO.File]::ReadAllText($keyFile)}
    $tried=Test-Path -LiteralPath $pendingKey
    if($tried){
        if($null -ne $previousKey){Write-DiskUtf8 (Join-Path $secrets ('happier-backup-'+[guid]::NewGuid().ToString('N')+'.key')) $previousKey}
        Write-DiskUtf8 $keyFile ([IO.File]::ReadAllText($pendingKey))
    }
    $oldConfig=Read-TransportJson (Join-Path $Root 'config.json');$previous=$oldConfig.happier
    $oldState=$null;$stateFile=Join-Path $Root 'state/happier-account.json';if(Test-Path $stateFile){$oldState=Read-TransportJson $stateFile}
    try{
        Update-LauncherConfig $Root {param($c) $c|Add-Member -Force happier ([pscustomobject]@{serverUrl=[string]$Request.serverUrl;webappUrl=[string]$Request.webappUrl;label=[string]$Request.label})}
        Invoke-InstallChild $Bundle 'accounts/Account.ps1' @('-Home',$Root,'-ExpectedAccount',[string]$Request.expectedAccount) -TimeoutSeconds 300
        Update-LauncherConfig $Root {param($c) if($c.wizard){$c.wizard.PSObject.Properties.Remove('skipHappier')}}
        if($tried){Remove-Item -LiteralPath $pendingKey -Force}
        Remove-Item -LiteralPath $pendingFile -Force
        $result=Read-TransportJson $stateFile
        $result|Add-Member -Force webappUrl ([string]$Request.webappUrl)
        $result|Add-Member -Force summary ('Аккаунт «'+[string]$Request.label+'» подключён ✓')
        return $result
    }catch{
        # The tried key is kept for recovery; the working one is restored.
        if($tried){
            Move-Item -LiteralPath $pendingKey -Destination (Join-Path $secrets ('happier-unconfirmed-'+[guid]::NewGuid().ToString('N')+'.key'))
            if($null -ne $previousKey){Write-DiskUtf8 $keyFile $previousKey}elseif(Test-Path -LiteralPath $keyFile){Remove-Item -LiteralPath $keyFile -Force}
        }
        if(Test-Path -LiteralPath $pendingFile){Remove-Item -LiteralPath $pendingFile -Force}
        Update-LauncherConfig $Root {param($c) if($null -ne $previous){$c|Add-Member -Force happier $previous}else{$c.PSObject.Properties.Remove('happier')}}
        if($oldState -and $oldState.account){$oldState|Add-Member -Force ok $false;$oldState|Add-Member -Force summary 'Предыдущий аккаунт сохранён; повторите живую проверку после неудачной попытки';Write-TransportJson $stateFile $oldState}
        throw
    }
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
        $rows=@();foreach($row in @($Transport.$g)){if($null -ne $row){$copy=$row|Select-Object * -ExcludeProperty configPath,keyFile,knownHostsPath;$rows+=@($copy)}}
        $out|Add-Member $g $rows
    };return $out
}
function Register-WizardRollback([string]$Root,[string]$Bundle,[string]$Kind,[string]$Session,[string]$Task) {
    # Recovery is independent of both the UI and the prunable current bundle.
    $recovery=Join-Path $Root ('state/wizard-recovery/'+$Session)
    foreach($name in @(Get-WizardRuntimeFiles)){
        $dest=Join-Path $recovery $name;[void][IO.Directory]::CreateDirectory((Split-Path $dest -Parent))
        Copy-Item -LiteralPath (Join-Path $Bundle $name) -Destination $dest
    }
    $args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $recovery 'build/Wizard.ps1'),'-Home',$Root,'-Action',('Rollback'+$Kind),'-Session',$Session)
    $action=New-ScheduledTaskAction -Execute (Get-TransportPowerShell) -Argument (($args|ForEach-Object {Quote-Transport $_}) -join ' ')
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $Task -Action $action -Trigger @((New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(3)),(New-ScheduledTaskTrigger -AtLogOn -User $user)) -Principal $principal -Settings $settings -Force|Out-Null
    $registered=Get-TaskState $Task
    if(-not $registered.exists -or -not $registered.enabled){throw 'Не зарегистрирован независимый откат настроек'}
}
function Get-WizardBridgeCommand([string]$Root,[string]$Run) {
    if($Run){return $Run}
    # A manually started bridge may have no Run entry; retain its actual command too.
    foreach($base in @((Join-Path $Root 'managed-control'))){
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
    Update-LauncherConfig $Root {param($c)
        if($null -ne $receipt.bridge){$c|Add-Member -Force bridge $receipt.bridge}else{$c.PSObject.Properties.Remove('bridge')}
        if($null -ne $receipt.control){Set-ConfigDefault $c components ([pscustomobject]@{});$c.components|Add-Member -Force control $receipt.control}else{if($c.components){$c.components.PSObject.Properties.Remove('control')}}
    }
    Stop-ManagedControl $Root
    $config=Join-Path $env:LOCALAPPDATA 'RemoteAgents/control/config.json'
    if($null -ne $receipt.controlConfig){Write-TransportJson $config $receipt.controlConfig -Durable}else{if(Test-Path $config){Remove-Item -LiteralPath $config -Force}}
    Set-RunValue 'RemoteAgentsControl' $receipt.run
    $command=$receipt.run;if($receipt.command){$command=$receipt.command};Start-RunCommand $command
    Remove-Item -LiteralPath $file -Force
    Unregister-ScheduledTask -TaskName $receipt.task -Confirm:$false -ErrorAction SilentlyContinue
}
function Set-WizardBridge([string]$Root,[string]$Bundle,[bool]$Enabled,[bool]$Shell,[string]$DeviceName='') {
    if($DeviceName -and ($DeviceName.Length -gt 80 -or $DeviceName -match '[\x00-\x1f\x7f]')){throw 'Название компьютера: от 1 до 80 символов, без управляющих символов'}
    $file=Join-Path $Root 'state/wizard-bridge.json'
    if(Test-Path $file){throw 'Есть незавершённая настройка моста; дождитесь отката'}
    $config=Read-TransportJson (Join-Path $Root 'config.json')
    # Prove the requested policy without changing the currently working intent.
    if($Enabled -and (Test-WizardBridge $Root) -and $config.bridge -and $config.bridge.enabled -eq $Enabled -and $config.bridge.allowShell -eq $Shell){if($DeviceName){Register-WizardDeviceName $Root $DeviceName};return}
    $task='RemoteAgents bridge rollback '+(Get-TransportFingerprint 'settings' $Root.ToLowerInvariant()).Substring(0,16)
    $session=[guid]::NewGuid().ToString('N');$oldControl=$null
    $controlFile=Join-Path $env:LOCALAPPDATA 'RemoteAgents/control/config.json';if(Test-Path $controlFile){$oldControl=Read-TransportJson $controlFile}
    $run=Get-RunValue 'RemoteAgentsControl';$command=Get-WizardBridgeCommand $Root $run
    Write-TransportJson $file @{schema=1;session=$session;task=$task;bridge=$config.bridge;control=$config.components.control;run=$run;command=$command;controlConfig=$oldControl} -Private -Durable
    try{Register-WizardRollback $Root $Bundle Bridge $session $task}catch{Remove-Item -LiteralPath $file -Force;throw}
    try{
        Update-LauncherConfig $Root {param($c)
            $c|Add-Member -Force bridge ([pscustomobject]@{enabled=$Enabled;allowShell=$Shell})
            Set-ConfigDefault $c components ([pscustomobject]@{});Set-ConfigDefault $c.components control ([pscustomobject]@{});$c.components.control|Add-Member -Force enabled $Enabled
        }
        # Recovery is armed first; its receipt restores the exact Run command on failure.
        $args=@('-LauncherHome',$Root)
        if($Enabled){$args+=@('-Install','-Profile',(Find-InstallProfile $Root))}else{$args+=@('-Uninstall')}
        Invoke-InstallChild $Bundle 'Start-WindowsControl.ps1' $args -TimeoutSeconds 300
        if($Enabled -and -not (Test-WizardBridge $Root)){throw 'Новый мост не подтверждён; прежние настройки восстанавливаются'}
        if($Enabled -and $DeviceName){Register-WizardDeviceName $Root $DeviceName}
        Remove-Item -LiteralPath $file -Force
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
    }catch{Undo-WizardBridge $Root $session;throw}
}
function Test-WizardNetworkManaged([string]$Root) {
    if(Test-StatusFresh $Root transport){return $true}
    # A dead heartbeat must never turn off preflight/rollback for an installed PC.
    $file=Join-Path $Root 'config.json'
    if(Test-Path $file){
        $c=Read-TransportJson $file
        if($c.wizard.configured){return $true}
        if(-not $c.transport.bootstrap -and $c.transport.channelPath -and ((Test-Path (Join-Path $Root 'state/transport-sing-box.json')) -or $c.wizard.pendingProfile)){return $true}
    }
    return $false
}
function Test-WizardNetworkProof([string]$Root,[DateTime]$Mark) {
    $status=Join-Path $Root 'status/transport.json'
    if(-not (Test-Path $status) -or (Get-Item $status).LastWriteTimeUtc -le $Mark -or -not (Test-StatusFresh $Root transport)){return $false}
    $observed=Read-TransportJson $status
    if($observed.configError -or $observed.configRevision -cne (Get-TransportRevision $Root)){return $false}
    $config=Read-TransportJson (Join-Path $Root 'config.json')
    return Test-LocalSsh $Root ([int](Get-TransportValue $config.transport 'sshPort' 2222))
}
function Set-WizardNetwork([string]$Root,[string]$Bundle,$Transport) {
    # Separate ports and real SSH check BEFORE touching the working daemon.
    if(Test-Path (Join-Path $Root 'state/wizard-network.json')){throw 'Есть незавершённая настройка связи; дождитесь отката'}
    $candidate=Read-TransportJson (Join-Path $Root 'config.json');$candidate|Add-Member -Force transport $Transport
    Invoke-TransportPreflight $Root $Bundle $candidate
    $file=Join-Path $Root 'state/wizard-network.json';$session=[guid]::NewGuid().ToString('N')
    $previous=(Read-TransportJson (Join-Path $Root 'config.json')).transport
    $task='RemoteAgents settings rollback '+(Get-TransportFingerprint 'settings' $Root.ToLowerInvariant()).Substring(0,16)
    Write-TransportJson $file @{schema=1;session=$session;previous=$previous;task=$task} -Private -Durable
    try{Register-WizardRollback $Root $Bundle Network $session $task}catch{Remove-Item -LiteralPath $file -Force;throw}
    try{
        $mark=[DateTime]::UtcNow
        Update-LauncherConfig $Root {param($c) $c|Add-Member -Force transport $Transport}
        $healthy=$false;$watch=[Diagnostics.Stopwatch]::StartNew()
        while($watch.Elapsed.TotalSeconds -lt 120){
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
    if($receipt.pin){Write-TransportJson (Join-Path $Root 'state/transport-pin.json') $receipt.pin -Private}
    if($receipt.profileFile){Write-TransportJson ([string]$receipt.profileFile) $receipt.profile -Private}
    Update-LauncherConfig $Root {param($c)
        $c|Add-Member -Force transport $receipt.previous
        if($receipt.profileFile){
            if($receipt.vpn){$c|Add-Member -Force vpn $receipt.vpn}else{$c.PSObject.Properties.Remove('vpn')}
            if($receipt.serverRoute){$c.wizard|Add-Member -Force serverRoute $receipt.serverRoute}else{if($c.wizard){$c.wizard.PSObject.Properties.Remove('serverRoute')}}
        }
    }
    foreach($path in @($receipt.versionFile)){if($path -and (Test-Path $path)){Remove-Item -LiteralPath $path -Force}}
    Remove-Item -LiteralPath $file -Force
    Unregister-ScheduledTask -TaskName $receipt.task -Confirm:$false -ErrorAction SilentlyContinue
}
function Test-WizardBridge([string]$Root) {
    try {
        $hostId=Split-Path (Split-Path (Find-InstallProfile $Root) -Parent) -Leaf
        $config=Read-TransportJson (Join-Path $Root 'config.json')
        $expected=@{hostId=$hostId;workspace=(Join-Path $env:LOCALAPPDATA 'RemoteAgents/control/workspace');allowShell=[bool]$config.bridge.allowShell}
        $data=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($expected|ConvertTo-Json -Compress)))
        $code=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-BridgeProbe)))
        $reply=Invoke-WizardSsh $Root ('python3 -c ''import base64;exec(base64.b64decode("'+$code+'"))'' '''+$data+'''')
        return $reply.Trim() -ceq 'bridge-probe-ok'
    }catch{return $false}
}
function Invoke-WizardStep([string]$Root,[string]$Bundle,[string]$Action,$Request) {
    $diskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk';$script:DiskHome=$diskHome
    switch($Action){
        'Bootstrap' {return Start-WizardBootstrap $Root $Bundle $Request}
        'ConfigSync' {return Sync-WizardConfigSettings $Root $Bundle $Request}
        'Server' {
            $profile=Connect-WizardServer $Root $Bundle $Request
            Write-WizardProgress 'Проверяю службы сервера…'
            $server=Get-WizardServer $Root $Bundle
            if($Request.installMissing){
                Write-WizardProgress 'Устанавливаю недостающие службы сервера…'
                Send-WizardHelpers $Root $Bundle
                $flags=@([int](-not $server.disk),[int](-not $server.happier),[int](-not $server.catalog)) -join ' '
                # Happier/Disk installs only START here, detached on the server (closing the window or
                # the PC does not stop them); their sections follow them with short «status» calls.
                try{[void](Invoke-WizardSsh $Root ('bash "$HOME/.local/share/remoteagents-wizard/server-wizard.sh" repair '+$flags) '' 120)}catch{
                    $observed=Get-WizardServer $Root $Bundle
                    if(-not $observed.userManager){throw 'Нет user systemd. Администратору: sudo loginctl enable-linger <пользователь>; sudo systemctl start user@<uid>.service. Повторите проверку'}
                    throw 'Установка не запущена. Нужны curl, tar, flock, setsid, python3, systemd и доступ к официальным загрузкам; проверьте сервер и повторите шаг'
                }
                $server=Get-WizardServer $Root $Bundle
            }
            if(-not $server.userManager){throw 'Нет user systemd. Администратору сервера: sudo loginctl enable-linger <пользователь>; sudo systemctl start user@<uid>.service. Затем повторите шаг'}
            $running=@(foreach($op in @('disk','happier')){if($server.operations -and $server.operations.$op.state -eq 'running'){$(if($op -eq 'disk'){'Диск'}else{'Happier'})}})
            $server|Add-Member -Force summary ('Подключено ✓'+$(if($running.Count){'. На сервере устанавливается: '+($running -join ', ')+' — разделы завершатся сами'}else{''}))
            if((Read-TransportJson (Join-Path $Root 'config.json')).profile){$server|Add-Member -Force configSync (Install-WizardConfigSync $Root $Bundle)}
            return $server
        }
        'Lan' {if($Request.host){return Add-WizardLan $Root $Bundle $Request};return Send-WizardLan $Root $Bundle ([string]$Request.file)}
        'LanRemove' {return Remove-WizardLan $Root $Bundle $Request}
        'NetStatus' {return Get-WizardNetStatus $Root}
        'AdminProbe' {return @{mode=(Get-WizardAdminMode $Root ([pscustomobject]@{}))}}
        'Proxy' {return Set-WizardProxy $Root $Bundle $Request}
        'Catalog' {Write-WizardProgress 'Загружаю узлы с сервера…';return Get-WizardCatalog $Root $Bundle}
        'Connection' {
            $server=Get-WizardCatalog $Root $Bundle;$local=$Request.catalog
            Assert-WizardCatalog $local
            $file=Join-Path $Root 'config.json';$config=Read-TransportJson $file
            $t=Copy-TransportObject $config.transport;if(-not $t){$t=[pscustomobject]@{}}
            if($config.wizard.pendingProfile){$t=[pscustomobject]@{profilePath=[string]$config.wizard.pendingProfile}}
            foreach($g in @('entries','hops','relays','cdn')){
                $rows=@();foreach($row in @($local.$g)){
                    $copy=Copy-TransportObject $row
                    $existing=@($t.$g|Where-Object {$_.name -ceq $row.name})
                    if($existing.Count){foreach($field in @('configPath','keyFile','knownHostsPath')){if($existing[0].$field){$copy|Add-Member -Force $field ([string]$existing[0].$field)}}}
                    $rows+=@($copy)
                }
                $t|Add-Member -Force $g $rows
            }
            if($Request.shared){
                # CAS must succeed before any local route changes. A concurrent editor
                # cannot leave this computer on a catalog which failed publication.
                Send-WizardHelpers $Root $Bundle
                $payload=@{expected=$Request.expected;catalog=$local}|ConvertTo-Json -Depth 30 -Compress
                [void](Invoke-WizardSsh $Root 'python3 "$HOME/.local/share/remoteagents-wizard/server-transport-catalog.py" put' $payload)
            }
            try{
                Initialize-WizardTransport $Root $Bundle $t
                $t.PSObject.Properties.Remove('bootstrap');$t|Add-Member -Force openSsh $true
                if(Test-WizardNetworkManaged $Root){Set-WizardNetwork $Root $Bundle $t}
                else{Set-WizardInitialNetwork $Root $Bundle $t}
            }catch{
                if($Request.shared){
                    try{
                        $restore=@{expected=$local;catalog=$server}|ConvertTo-Json -Depth 30 -Compress
                        [void](Invoke-WizardSsh $Root 'python3 "$HOME/.local/share/remoteagents-wizard/server-transport-catalog.py" put' $restore)
                    }catch{Write-SetupLog $Root 'wizard.catalog.restore.failed'}
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
            Update-LauncherConfig $Root {param($c) Set-ConfigDefault $c wizard ([pscustomobject]@{});$c.wizard|Add-Member -Force localCatalog $overlay;$c.wizard.PSObject.Properties.Remove('pendingProfile');if($c.vpn){$c.vpn.PSObject.Properties.Remove('bootstrapTag')}}
            $statusFile=Join-Path $Root 'status/transport.json'
            $active='проверенный путь';if(Test-Path $statusFile){$status=Read-TransportJson $statusFile;$row=@($status.candidates|Where-Object {$_.tag -ceq $status.active});if($row.Count){$active=[string]$row[0].title}}
            return @{ok=$true;summary=('Работает через '+$active)}
        }
        'Skip' {
            if($Request.step -notin @('Disk','Happier','Lan','Proxy')){throw 'Обязательный шаг нельзя пропустить'}
            if($Request.step -eq 'Disk' -and (Read-TransportJson (Join-Path $Root 'config.json')).wizard.diskPreviousProfile){Suspend-WizardDisk $Root $Bundle}
            Update-LauncherConfig $Root {param($c) Set-ConfigDefault $c wizard ([pscustomobject]@{});$c.wizard|Add-Member -Force ('skip'+$Request.step) $true;if($Request.step -eq 'Disk' -and $c.wizard.diskPreviousProfile){$c.wizard|Add-Member -Force diskKeepPrevious $true}}
            if($Request.step -eq 'Proxy'){return @{ok=$true;summary='Пропущено: сервер выходит в интернет как сейчас, прокси не менялся'}}
            return @{ok=$true;summary='Пропущено по вашему выбору'}
        }
        'DiskTree' {
            Send-WizardHelpers $Root $Bundle
            $relative=[string]$Request.path
            $command=Get-DiskTreeCommand $relative
            $server=ConvertFrom-Json (Convert-TransportLF (Invoke-WizardSsh $Root $command))
            $base=[string]$Request.base;if(-not $base){$base=Get-DiskBase}
            $union=Get-DiskUnion $server $base $relative;$selection=Read-DiskSelection
            if($Request.fresh){$selection=@{schema=1;paths=@()}}
            # The install-time freeze placeholder is not a user choice: show the default again.
            if($null -eq $selection -or $selection.placeholder){$selection=@{schema=1;paths=@($union.rows|Where-Object {$_.path -notmatch '/' -and $_.kind -eq 'directory'}|ForEach-Object {$_.path})}}
            $result=@{union=$union;selection=$selection;base=$base}
            if($server.unsupportedName){$result.unsupportedName=[string]$server.unsupportedName}
            return $result
        }
        'Disk' {
            Send-WizardHelpers $Root $Bundle
            $server=Get-WizardServer $Root $Bundle
            if(-not $server.disk){
                $op=(Get-WizardOperation $Root $Bundle 'status' @('disk')).disk
                if($op.state -ne 'running'){$op=(Get-WizardOperation $Root $Bundle 'start' @('disk')).disk}
                return @{ok=$false;pending='disk';operation=$op;summary=(Get-WizardOperationText $op 'установка сервера диска')}
            }
            Resolve-WizardDiskServer $Root $Bundle $Request
            $base=[IO.Path]::GetFullPath([string]$Request.base)
            $profile=Find-InstallProfile $Root
            if(Test-Path (Join-Path $diskHome 'state/config.xml')){
                Read-DiskState
                [void](Set-DiskBase $base)
            }
            [void][IO.Directory]::CreateDirectory($diskHome);[void][IO.Directory]::CreateDirectory($base)
            Write-DiskUtf8 (Join-Path $diskHome 'base.txt') $base
            $choice=Join-Path $Root 'state/wizard-selection.json';Write-TransportJson $choice @{schema=1;paths=@($Request.paths)}
            $needsInstall= -not (Test-Path (Join-Path $diskHome 'state/config.xml')) -or -not (Test-Path (Join-Path $diskHome 'tray/syncthingtray.exe'))
            if(-not $needsInstall){try{Read-DiskState;$probe=Invoke-DiskApi 'system/status';$needsInstall= -not $probe.myID}catch{$needsInstall=$true}}
            if($needsInstall){
                # Freeze selection until the explicit Apply below.
                # The placeholder flag keeps it distinguishable from an explicit empty choice after an interruption.
                if(-not (Test-Path (Join-Path $diskHome 'selection.json'))){Write-TransportJson (Join-Path $diskHome 'selection.json') @{schema=1;paths=@();placeholder=$true}}
                Invoke-InstallChild $Bundle 'disk/Install-RemoteDisk.ps1' @('-Profile',$profile,'-HelpersReady') -TimeoutSeconds 900
            }
            Set-WizardDiskChannel $Root
            Read-DiskState;$local=Invoke-DiskApi 'system/status';if(-not $local.myID){throw 'Syncthing не отвечает; повторите установку диска'}
            Invoke-InstallChild $Bundle 'disk/Select-Disk.ps1' @('-Home',$Root,'-Action','Apply','-SelectionFile',$choice) -TimeoutSeconds 900
            Update-LauncherConfig $Root {param($c) if($c.wizard){$c.wizard.PSObject.Properties.Remove('skipDisk')};Set-ConfigDefault $c components ([pscustomobject]@{});Set-ConfigDefault $c.components disk ([pscustomobject]@{});$c.components.disk|Add-Member -Force enabled $true}
            $hold=Join-Path $Root 'state/disk-reconfigure';if(Test-Path $hold){Remove-Item -LiteralPath $hold}
            try{Install-DiskNavPane $base}catch{Write-DiskLog 'Значок Disk в Проводнике' $_} # cosmetic: never fails the Disk step
            return @{ok=$true;summary='Выбор применён; передача файлов продолжается. Это ещё не подтверждение завершённой синхронизации'}
        }
        'AccountList' {
            # Public adapter only, no vendor/bootstrap/login needed to list account names.
            Send-WizardHelpers $Root $Bundle
            $text=Invoke-WizardSsh $Root 'export PATH="$HOME/.local/share/remoteagents-accounts/node:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"; node "$HOME/.local/share/remoteagents-accounts/server-account.mjs"' '{"action":"list"}'
            return ConvertFrom-Json (Convert-TransportLF $text)
        }
        'Account' {if($Request.mode -eq 'same'){return Connect-WizardProfileAccount $Root $Bundle $Request};return Invoke-WizardAccount $Root $Bundle $Request $true}
        'ResumeAccount' {return Invoke-WizardAccount $Root $Bundle $null $false}
        'Operation' {
            $ops=@($Request.operations|Where-Object {$_})
            # «Повторить» in the «Установка» list: an explicit restart of a failed detached install.
            if($Request.start){Send-WizardHelpers $Root $Bundle;[void](Get-WizardOperation $Root $Bundle 'start' @([string]$Request.start))}
            $status=Get-WizardOperation $Root $Bundle 'status' $ops
            Add-WizardOperationText $status
            return @{operations=$status;pendingAccount=[bool](Get-WizardPendingAccount $Root)}
        }
        'Bridge' {
            if((Read-TransportJson (Join-Path $Root 'config.json')).wizard.pendingProfile){throw 'Сначала проверьте связь с новым сервером на шаге «Связь»'}
            Set-WizardBridge $Root $Bundle ([bool]$Request.enabled) ([bool]$Request.shell) ([string]$Request.deviceName)
            return @{ok=$true;summary=$(if($Request.enabled){'Мост и разрешение shell проверены'}else{'Запрос выключения выполнен'})}
        }
        'Vpn' {
            $config=Read-TransportJson (Join-Path $Root 'config.json')
            $previous=$config.vpn
            if(($Request.enabled -or $config.transport.bootstrap -or $previous.bootstrapTag) -and -not (Test-WizardNetworkProof $Root ([DateTime]::UtcNow.AddSeconds(-15)))){
                return @{ok=$false;pending='connection';summary='Сначала дождитесь живой связи; начальный VPN сохранён'}
            }
            $changed=([string]$previous.checkUrl -cne [string]$Request.checkUrl) -or ([string]$previous.dnsServer -cne [string]$Request.dnsServer)
            if($Request.enabled -and $previous.enabled -and $changed){throw 'Сначала выключите VPN и дождитесь очистки наших маршрутов, затем измените DNS/адрес проверки и включите снова. Работающий VPN сохранён'}
            if($Request.enabled){
                $uri=$null
                if(-not [Uri]::TryCreate([string]$Request.checkUrl,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or -not $Request.dnsServer){throw 'Укажите свой HTTPS-адрес проверки без пароля и выбранный DNS для VPN'}
                if(-not $changed -and $previous.enabled -and (Test-StatusFresh $Root vpn)){return @{ok=$true;summary='VPN уже включён и проверен; действующая сессия сохранена'}}
            }
            Update-LauncherConfig $Root {param($c)
                Set-ConfigDefault $c vpn ([pscustomobject]@{enabled=$false})
                foreach($key in @('checkUrl','dnsServer')){if($Request.$key){$c.vpn|Add-Member -Force $key ([string]$Request.$key)}}
            }
            try{
                if($Request.enabled){
                    $conflict=ConvertFrom-Json (& (Join-Path $Bundle 'transport/Test-VpnConflict.ps1') -Home $Root|Out-String)
                    if($conflict.conflict){throw 'Работает другой VPN. Отключите его сами и повторите проверку; RemoteAgents не менял чужой VPN'}
                    Invoke-InstallChild $Bundle 'transport/Vpn.Tun.ps1' @('-Home',$Root,'-Enable') -TimeoutSeconds 420
                    return @{ok=$false;summary='Запрос VPN передан. Дождитесь живого статуса TUN; включение ещё не подтверждено'}
                }
                if($previous.enabled){Invoke-InstallChild $Bundle 'transport/Vpn.Tun.ps1' @('-Home',$Root,'-Disable') -TimeoutSeconds 420}
                return @{ok=$true;summary='VPN выключен в настройках; состояние маршрутов — в живом статусе VPN'}
            }catch{
                Update-LauncherConfig $Root {param($c) if($null -ne $previous){$c|Add-Member -Force vpn $previous}else{$c.PSObject.Properties.Remove('vpn')}}
                throw
            }
        }
        'Inspect' {
            $server=[pscustomobject]@{ssh=$false;disk=$false;happier=$false;bridge=$false;catalog=$false}
            try{$server=Get-WizardServer $Root $Bundle}catch{$server|Add-Member -Force reason (Protect-TransportText ([string]$_.Exception.Message))}
            $config=Read-TransportJson (Join-Path $Root 'config.json')
            $disk=$false
            try{Read-DiskState;$engine=Invoke-DiskApi 'system/status';$peer=[IO.File]::ReadAllText((Join-Path $diskHome 'server.txt')).Trim();$connections=Invoke-DiskApi 'system/connections';$disk=[bool]($engine.myID -and $connections.connections.PSObject.Properties[$peer].Value.connected)

            }catch{$disk=$false}
            $account=$false
            $state=Join-Path $Root 'state/happier-account.json'
            if($server.ssh -and (Test-Path $state)){
                $id=[string](Read-TransportJson $state).account
                if($id -cmatch '^[a-f0-9]{64}$'){
                    try{
                        $request=@{action='inspect';account=$id}|ConvertTo-Json -Compress
                        $out=Invoke-WizardSsh $Root 'export PATH="$HOME/.local/share/remoteagents-accounts/node:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"; node "$HOME/.local/share/remoteagents-accounts/server-account.mjs"' $request
                        $account=[bool](ConvertFrom-Json (Convert-TransportLF $out)).ok
                    }catch{}
                }
            }
            # An interrupted install leaves the freeze placeholder: the disk choice is still open.
            try{$saved=Read-DiskSelection;if($saved -and $saved.placeholder){$disk=$false}}catch{$disk=$false}
            $bridgeIntent=[bool]$config.bridge.enabled;if(-not $config.bridge){$bridgeIntent=[bool]$config.components.control.enabled -or -not $config.components.PSObject.Properties['control']}
            $transport=Test-WizardNetworkProof $Root ([DateTime]::UtcNow.AddSeconds(-15))
            $local=[pscustomobject]@{transport=$transport;disk=$disk;account=$account;bridgeEnabled=$bridgeIntent;bridge=($server.ssh -and $bridgeIntent -and (Test-WizardBridge $Root));vpnEnabled=[bool]$config.vpn.enabled;vpn=(Test-StatusFresh $Root vpn)}
            $plan=@(Get-WizardPlan $server $local)
            if($config.wizard.pendingProfile){foreach($i in @(1,2,3,4)){$plan[$i].ready=$false}}
            if($config.wizard.diskPreviousProfile){$plan[2].ready=[bool]$config.wizard.diskKeepPrevious}
            if($config.wizard.skipDisk -and -not $config.wizard.diskPreviousProfile){$plan[2].ready=$true}
            if($config.wizard.skipHappier){$plan[3].ready=$true}
            return @{ok=(@($plan|Where-Object {-not $_.ready}).Count -eq 0);server=$server;steps=$plan;pendingAccount=[bool](Get-WizardPendingAccount $Root);summary='Подключения проверены сейчас. Завершение передачи файлов видно в статусе Диска'}
        }
        'Activate' {
            $config=Read-TransportJson (Join-Path $Root 'config.json')
            if($config.wizard.pendingProfile){throw 'Сначала проверьте связь с новым сервером на шаге «Связь»'}
            if(-not (Test-WizardNetworkProof $Root ([DateTime]::UtcNow.AddSeconds(-15)))){throw 'Нет рабочего пути: дождитесь живой проверки связи в трее и повторите'}
            $bridgeIntent=if($config.bridge){[bool]$config.bridge.enabled}else{[bool]$config.components.control.enabled -or -not $config.components.PSObject.Properties['control']}
            if($bridgeIntent -and -not (Test-WizardBridge $Root)){throw 'Мост ещё не подтверждён: проверьте шаг «Мост» либо явно выключите его'}
            Set-RunValue 'RemoteAgents' ('"'+(Join-Path $Root 'RemoteAgents.exe')+'" --tray --home "'+$Root+'"')
            Update-LauncherConfig $Root {param($c) Set-ConfigDefault $c wizard ([pscustomobject]@{});$c.wizard|Add-Member -Force configured $true}
            return @{ok=$true;summary='Настройки сохранены. Связь проверена; приложение работает в трее'}
        }
        default {throw 'Неизвестный шаг мастера'}
    }
}

