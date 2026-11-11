#requires -Version 5.1
# Both entry points run under Invoke-WizardLock. Network trust comes ONLY from
# an already pinned SSH session, or the administrator-delivered refresh EXE.
function Get-WizardDeviceKey($Profile) {
    $keygen=Join-Path (Split-Path $Profile.sshExecutable -Parent) 'ssh-keygen.exe'
    if($env:OS -ne 'Windows_NT'){$keygen='ssh-keygen'}
    # Derive from the PRIVATE key; trusting a copied .pub would permit another PC.
    $text=Convert-TransportLF (Invoke-DiskProcess $keygen @('-y','-f',[string]$Profile.keyPath) -TimeoutSeconds 10)
    $parts=$text.Trim() -split '\s+'
    if($parts.Count -lt 2 -or $parts[0] -ne 'ssh-ed25519'){throw 'Нет собственного ключа ed25519 компьютера'}
    return ($parts[0]+' '+$parts[1])
}
function Get-WizardInviteSettings([string]$Root,[string]$Command='cat "$HOME/.config/remoteagents/invite-settings.json"',[string]$InputText='') {
    # Local transport may reach the server when its former direct address is down.
    $p=Read-TransportJson (Find-InstallProfile $Root);$c=Read-TransportJson (Join-Path $Root 'config.json')
    try{
        $args=@('-o','ProxyCommand=none')+@(Get-TransportSshArguments $p ([int](Get-TransportValue $c.transport 'sshPort' 2222)))+@('127.0.0.1',$command)
        return Invoke-DiskProcess $p.sshExecutable $args (Convert-TransportLF $InputText) -TimeoutSeconds 15
    }catch{}
    # No keyscan, accept-new, HTTP or other unverified fallback.
    return Invoke-WizardSsh $Root $Command $InputText 20
}
function Confirm-WizardInviteSettings([string]$Root) {
    $pending=Join-Path $Root 'state/wizard-network.json'
    if(Test-Path $pending){
        $transaction=Read-TransportJson $pending
        if($transaction.profileFile){
            if(Test-WizardNetworkProof $Root ([DateTime]::Parse([string]$transaction.mark))){
                Remove-Item -LiteralPath $pending -Force
                Unregister-ScheduledTask -TaskName $transaction.task -Confirm:$false -ErrorAction SilentlyContinue
            }else{return $false}
        }else{throw 'Есть незавершённая настройка связи'}
    }
    return $true
}
function Sync-WizardInviteSettings([string]$Root,[string]$Bundle,$Request) {
    if(-not (Confirm-WizardInviteSettings $Root)){return @{ok=$true;changed=$false;summary='Ожидается проверка обновлённой связи; независимый откат включён'}}
    $device=Join-Path $Root 'state/invite-device.json'
    if(-not (Test-Path $device)){return @{ok=$true;changed=$false}}
    $text=Get-WizardInviteSettings $Root
    if($text.Length -gt 1048576){throw 'Слишком большой снимок настроек'}
    $data=ConvertFrom-Json (Convert-TransportLF $text)
    if($data.type -ne 'settings'){throw 'Неизвестный формат настроек сервера'}
    # The public catalog remains authoritative. Admin sync publishes the private
    # caches/routes/channel; a later catalog removal needs no new invitation.
    $source=Convert-TransportLF ([IO.File]::ReadAllText((Join-Path $Bundle 'transport/server-transport-catalog.py')))
    $catalog=ConvertFrom-Json (Convert-TransportLF (Get-WizardInviteSettings $Root 'python3 -' $source))
    Assert-WizardCatalog $catalog
    $data.bootstrap|Add-Member -Force catalog $catalog
    $request=[pscustomobject]@{data=$data;trustedSsh=$true;askpassExecutable=[string]$Request.askpassExecutable}
    return Update-WizardInviteSettings $Root $Bundle $request
}
function Set-WizardRefreshSnapshot([string]$Stage,$Data) {
    $initial=$Data.bootstrap;Assert-WizardCatalog $initial.catalog
    $c=Read-TransportJson (Join-Path $Stage 'config.json');$t=$c.transport
    foreach($group in @('entries','hops','relays','cdn')){$t|Add-Member -Force $group @($initial.catalog.$group|Where-Object {$null -ne $_})}
    $t|Add-Member -Force cacheRoot $Stage
    if($initial.channel){
        $channel=Join-Path $Stage 'secrets/channel.json';Write-TransportJson $channel $initial.channel -Private
        $t|Add-Member -Force channelPath $channel
    }
    foreach($property in $initial.entries.PSObject.Properties){
        Assert-TransportName $property.Name
        Write-TransportJson (Join-Path $Stage ('secrets/entries/'+$property.Name+'.json')) $property.Value -Private
    }
    foreach($hop in @($t.hops|Where-Object {$_ -and $_.enabled -ne $false})){
        $snapshot=$initial.hops.PSObject.Properties[$hop.name].Value
        if(-not $snapshot -or -not $hop.hostKey){throw 'Нет переносимых настроек и ключа SSH-перехода'}
        $key=Join-Path $Stage ('secrets/hop-'+$hop.name);Write-DiskUtf8 $key ([string]$snapshot.privateKey);Protect-TransportPath $key
        $conf=$key+'.conf';$known=$key+'.known_hosts'
        $target=if([int]$snapshot.port -eq 22){[string]$snapshot.host}else{'['+$snapshot.host+']:'+$snapshot.port}
        foreach($pin in @($hop.hostKey)){if([string]$pin -cnotmatch '\A(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+\z'){throw 'Некорректный ключ перехода'}}
        Write-DiskUtf8 $known ((@($hop.hostKey|ForEach-Object {$target+' '+$_}) -join "`n")+"`n")
        Write-DiskUtf8 $conf ('Host '+$hop.ssh+"`n HostName "+$snapshot.host+"`n Port "+[int]$snapshot.port+"`n User "+$snapshot.user+"`n IdentityFile "+(Quote-Disk $key)+"`n IdentitiesOnly yes`n StrictHostKeyChecking yes`n GlobalKnownHostsFile none`n UserKnownHostsFile "+(Quote-Disk $known)+"`n")
        $hop|Add-Member -Force configPath $conf
    }
    if($initial.vpn){
        # Keep this computer's on/off choice and local route/interface settings.
        Set-ConfigDefault $c vpn ([pscustomobject]@{enabled=$false})
        foreach($field in @('checkUrl','dnsServer')){$c.vpn|Add-Member -Force $field ([string]$initial.vpn.$field)}
    }
    Write-TransportJson (Join-Path $Stage 'config.json') $c -Private
}
function Update-WizardInviteSettings([string]$Root,[string]$Bundle,$Request) {
    $data=$Request.data;if(-not $data){$data=Read-TransportJson ([string]$Request.path)}
    if($data.schema -ne 1 -or $data.type -notin @('settings','refresh')){throw 'Неизвестная схема обновления'}
    $profileFile=Find-InstallProfile $Root
    if(-not $profileFile){throw 'Этот компьютер ещё не подключён. Попросите приглашение для регистрации'}
    $profile=Read-TransportJson $profileFile;$own=Get-WizardDeviceKey $profile
    $receipt=Join-Path $Root ('state/refresh-used-'+[string]$data.id+'.json')
    if($data.type -eq 'refresh'){
        if($own -cne [string]$data.deviceKey){throw 'Обновление выдано другому компьютеру. Попросите файл для этого устройства'}
        if([string]$data.id -cnotmatch '\A[a-f0-9]{32}\z'){throw 'Повреждён идентификатор обновления'}
        if(Test-Path $receipt){return @{ok=$true;changed=$false;summary='Это обновление уже применено'}}
        if([DateTimeOffset]::Parse([string]$data.expiresUtc) -le [DateTimeOffset]::UtcNow){throw 'Срок обновления истёк. Попросите администратора выдать новое обновление'}
    }elseif(-not $Request.trustedSsh){throw 'Настройки разрешены только через уже доверенный SSH-канал'}
    if($data.workerUser -cne $profile.login){throw 'Обновление не может сменить рабочего пользователя'}
    $fingerprint=Get-TransportFingerprint 'invite-settings' (ConvertTo-Json $data -Depth 40 -Compress)
    $lastFile=Join-Path $Root 'state/invite-settings-version.json'
    if((Test-Path $lastFile) -and (Read-TransportJson $lastFile).hash -ceq $fingerprint){return @{ok=$true;changed=$false}}
    $stage=Join-Path $Root ('state/connection-generations/'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage);Protect-TransportPath $stage
    $previous=Read-TransportJson (Join-Path $Root 'config.json')
    Write-TransportJson (Join-Path $stage 'config.json') $previous -Private
    $copy=Copy-TransportObject $data;$copy|Add-Member -Force id ([guid]::NewGuid().ToString('N'))
    $source=Join-Path $stage 'settings.json';Write-TransportJson $source $copy -Private
    $r=[pscustomobject]@{path=$source;refresh=$true;keyPath=[string]$profile.keyPath;askpassExecutable=[string]$Request.askpassExecutable;hopPasswordPipe=[string]$Request.hopPasswordPipe}
    # Stage pins/profile without ever generating a replacement device key.
    $prepared=Initialize-WizardInvite $stage $r
    Update-LauncherConfig $stage {param($c) $c.transport|Add-Member -Force profilePath $prepared.file}
    Set-WizardRefreshSnapshot $stage $copy
    # First try every explicit route. If none connects, the transport preflight
    # must prove a new VPN/relay path with this same key before any live edit.
    try{[void](Connect-WizardInvite $stage $r)}catch{
        $r|Add-Member deferProof $true
        [void](Connect-WizardInvite $stage $r)
    }
    $candidate=Read-TransportJson (Join-Path $stage 'config.json');$nextProfile=Read-TransportJson $candidate.transport.profilePath
    # Existing independent rollback/preflight protects the live transport.
    $networkReceipt=Join-Path $Root 'state/wizard-network.json'
    if(Test-Path $networkReceipt){throw 'Есть незавершённая настройка связи; дождитесь проверки или отката'}
    $oldPin=Read-TransportPin $Root;$resetPin=$false
    if($oldPin.mode -eq 'pinned'){
        $available=Get-TransportCandidates (Read-TransportSettings $stage) $stage
        $resetPin=([string]$oldPin.tag -notin @($available.Candidates|ForEach-Object {$_.tag}))
    }
    # A removed pinned path must not prevent proving its replacement. The stage
    # has its own automatic selector; live pin intent changes only after proof.
    Invoke-TransportPreflight $stage $Bundle $candidate
    $session=[guid]::NewGuid().ToString('N');$mark=[DateTime]::UtcNow
    $task='RemoteAgents settings rollback '+(Get-TransportFingerprint 'settings' $Root.ToLowerInvariant()).Substring(0,16)
    Write-TransportJson $networkReceipt @{schema=1;session=$session;task=$task;mark=$mark.ToString('o');previous=$previous.transport;profileFile=$profileFile;profile=$profile;vpn=$previous.vpn;serverRoute=$previous.wizard.serverRoute;refreshReceipt=$(if($data.type -eq 'refresh'){$receipt}else{''});versionFile=$lastFile;pin=$(if($resetPin){$oldPin}else{$null})} -Private -Durable
    try{Register-WizardRollback $Root $Bundle Network $session $task}catch{Remove-Item -LiteralPath $networkReceipt -Force;throw}
    try{
        # Stable profile filename is shared by Disk/control; their next reconnect
        # reads the new pins/options while keeping the exact same private key.
        if($resetPin){Write-TransportJson (Join-Path $Root 'state/transport-pin.json') @{mode='auto';tag=$null} -Private}
        Write-TransportJson $profileFile $nextProfile -Private
        Update-LauncherConfig $Root {param($c)
            $c|Add-Member -Force transport $candidate.transport
            $c.transport|Add-Member -Force profilePath $profileFile
            if($candidate.vpn){$c|Add-Member -Force vpn $candidate.vpn}
            if($candidate.wizard.serverRoute){$c.wizard|Add-Member -Force serverRoute $candidate.wizard.serverRoute}
        }
        if(-not $Request.offlineInstaller){
            $healthy=$false;$watch=[Diagnostics.Stopwatch]::StartNew()
            while($watch.Elapsed.TotalSeconds -lt 120){
                if(Test-WizardNetworkProof $Root $mark){$healthy=$true;break};Start-Sleep -Seconds 1
            }
            if(-not $healthy){throw 'Новая связь не подтверждена; прежние настройки восстанавливаются'}
            Remove-Item -LiteralPath $networkReceipt -Force
            Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
        }
        Write-TransportJson $lastFile @{hash=$fingerprint}
        if($data.type -eq 'refresh'){Write-TransportJson $receipt @{ok=$true;deviceId=[string]$data.deviceId}}
        return @{ok=$true;changed=$true;summary='Настройки связи обновлены; VPN подхватит новые пути автоматически'}
    }catch{
        Undo-WizardNetwork $Root $session
        throw
    }
}
