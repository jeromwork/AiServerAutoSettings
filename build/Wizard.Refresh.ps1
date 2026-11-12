#requires -Version 5.1
# Fetch/stage without live resource locks; publication owns connection/vpn only. Trust comes ONLY from
# an already pinned SSH session, or the configuration access key.
function Get-WizardDeviceKey($Profile) {
    $keygen=Join-Path (Split-Path $Profile.sshExecutable -Parent) 'ssh-keygen.exe'
    if($env:OS -ne 'Windows_NT'){$keygen='ssh-keygen'}
    # Derive from the PRIVATE key; trusting a copied .pub would permit another PC.
    $text=Convert-TransportLF (Invoke-DiskProcess $keygen @('-y','-f',[string]$Profile.keyPath) -TimeoutSeconds 10)
    $parts=$text.Trim() -split '\s+'
    if($parts.Count -lt 2 -or $parts[0] -ne 'ssh-ed25519'){throw 'Нет собственного ключа ed25519 компьютера'}
    return ($parts[0]+' '+$parts[1])
}
# The server publishes ~worker/.config/remoteagents/config-sync.json on every `remoteagents config export` and
# `remoteagents config sync` (docs/CONFIG-SERVER.md «Автообновление»). The client only reads it with its own key.
# Shared bounded read-only request for config sync and server health, using the working channel.
function Invoke-WizardReadOnlySsh([string]$Root,[string]$Command,[string]$Context='Получение настроек',$Profile=$null) {
    # One attempt: channel-first installations must never fall back to direct SSH.
    if($null -eq $Profile){
        $file=Find-InstallProfile $Root
        if(-not $file){throw 'Настройте SSH на шаге «Сервер»'}
        $Profile=Read-TransportJson $file
    }
    $p=$Profile;$c=Read-TransportJson (Join-Path $Root 'config.json')
    $port=[int](Get-TransportValue $c.transport 'sshPort' 2222);$address='127.0.0.1';$path='канал'
    if($c.transport.channelFirst){
        $address=[string](Get-TransportValue $c.transport 'channelSshAddress' '127.0.0.2')
        $port=Get-TransportServerPort $p
    }
    elseif(-not $c.transport.channelPath){$address=[string]$p.serverAddress;$port=Get-TransportServerPort $p;$path='сохранённый SSH-маршрут'}
    $base=@(Get-TransportSshArguments $p $port -UseRoute:($path -ne 'канал'))
    try{
        return Invoke-DiskProcess $p.sshExecutable ($base+@($address,(Convert-TransportLF $Command))) '' -TimeoutSeconds 8
    }catch{
        $reason=Protect-TransportDiagnostic ([string]$_.Exception.Message) $c
        if($Context -eq 'Получение настроек' -and $reason -like '*код выхода 1)*'){$reason='Сервер не выдал снимок или каталог: проверьте наличие config-sync.json, формат и права'}
        throw ($Context+' через '+$path+': '+$reason)
    }
}
function Get-WizardConfigSettings([string]$Root,[string]$Command='cat "$HOME/.config/remoteagents/config-sync.json"',[string]$InputText='') {
    if($InputText){
        # A command payload avoids a second stdin timeout before authentication.
        if($Command -cne 'python3 - sync'){throw 'Неизвестная команда получения настроек'}
        $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Convert-TransportLF $InputText)))
        $Command='python3 -c ''import base64;exec(base64.b64decode("'+$encoded+'"))'' sync'
    }
    return Invoke-WizardReadOnlySsh $Root $Command
}

function Confirm-WizardConfigSettings([string]$Root) {
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
# config-sync.json (partial config of the paste format, secrets as plain text in a 0600 file of the worker) ->
# the internal settings snapshot of Update-WizardConfigSettings. Absent fields stay as they are on this computer:
# no server key, no vpn.enabled, no device/happier/bridge/disk/proxyOut/lan in a snapshot.
function ConvertFrom-WizardPrivateJson([string]$Text) {
    try{ConvertFrom-Json (Convert-TransportLF $Text)}catch{throw 'Повреждён JSON закрытых настроек канала или узла сервера'}
}
function ConvertFrom-WizardConfigSync($Snapshot) {
    if($Snapshot.kind -cne 'remoteagents-config-sync' -or $Snapshot.schema -ne 1){throw 'Неизвестный формат снимка настроек сервера'}
    $c=$Snapshot.config
    if($c.kind -cne 'remoteagents-config' -or $c.schema -ne 1 -or -not $c.server){throw 'Неизвестный формат снимка настроек сервера'}
    $secrets=$c.secrets
    $value={param($Reference)
        $name=[string]$Reference.secret
        if(-not $name -or -not $secrets -or -not $secrets.PSObject.Properties[$name]){throw ('В снимке сервера нет секрета '+$name)}
        [string]$secrets.PSObject.Properties[$name].Value
    }
    $routes=@();foreach($route in @($c.server.routes|Where-Object {$null -ne $_})){
        switch([string]$route.kind){
            'direct' {$routes+=[pscustomobject]@{kind='direct'}}
            'proxy' {$routes+=[pscustomobject]@{kind='proxy';proxy=[pscustomobject]@{type=[string]$route.proxy.type;host=[string]$route.proxy.server;port=[int]$route.proxy.port}}}
            'hop' {
                $h=$route.hop;$port=$(if($h.port){[int]$h.port}else{22})
                $hop=[pscustomobject]@{ssh=([string]$h.user+'@'+$h.host+$(if($port -ne 22){':'+$port}else{''}));hostKey=[string]$h.hostKey}
                if($h.key){$hop|Add-Member privateKey (& $value $h.key)}
                if($h.password){$hop|Add-Member password (& $value $h.password)}
                $routes+=[pscustomobject]@{kind='hop';hop=$hop}
            }
            default {throw 'Неизвестный маршрут в снимке сервера'}
        }
    }
    if(-not $routes.Count){$routes=@([pscustomobject]@{kind='direct'})}
    $b=$c.vpn.bootstrap;$entries=[pscustomobject]@{};$hops=[pscustomobject]@{};$channel=$null
    if($b.channel){$channel=ConvertFrom-WizardPrivateJson (& $value $b.channel)}
    if($b.entries){foreach($p in $b.entries.PSObject.Properties){Assert-TransportName $p.Name;$entries|Add-Member $p.Name (ConvertFrom-WizardPrivateJson (& $value $p.Value))}}
    if($b.hops){foreach($p in $b.hops.PSObject.Properties){Assert-TransportName $p.Name;$hops|Add-Member $p.Name ([pscustomobject]@{host=[string]$p.Value.host;port=$(if($p.Value.port){[int]$p.Value.port}else{22});user=[string]$p.Value.user;privateKey=(& $value $p.Value.key)})}}
    $catalog=$b.catalog;if(-not $catalog){$catalog=[pscustomobject]@{schema=1;entries=@();hops=@();relays=@();cdn=@()}}
    $bootstrap=[pscustomobject]@{catalog=$catalog;entries=$entries;hops=$hops}
    if($channel){$bootstrap|Add-Member channel $channel}
    if($c.vpn.checkUrl -or $c.vpn.dnsServer){$bootstrap|Add-Member vpn ([pscustomobject]@{checkUrl=[string]$c.vpn.checkUrl;dnsServer=[string]$c.vpn.dnsServer})}
    [pscustomobject]@{schema=1;type='settings';revision=[string]$Snapshot.revision;serverAddress=[string]$c.server.address;serverPort=$(if($c.server.port){[int]$c.server.port}else{22});workerUser=[string]$c.server.login;hostKeys=@($c.server.hostKeys);routes=$routes;bootstrap=$bootstrap}
}
# Stable content hash: metadata and JSON property order are not a network change.
function ConvertTo-WizardCanonicalJson($Value) {
    if($null -eq $Value){return 'null'}
    if($Value -is [string]){return ConvertTo-Json -InputObject (Convert-TransportLF $Value) -Compress}
    if($Value -is [Collections.IDictionary]){
        $pairs=@(foreach($key in @($Value.Keys|Sort-Object)){(ConvertTo-Json -InputObject ([string]$key) -Compress)+':'+(ConvertTo-WizardCanonicalJson $Value[$key])})
        return '{'+($pairs -join ',')+'}'
    }
    if($Value -is [pscustomobject]){
        $pairs=@(foreach($p in @($Value.PSObject.Properties|Sort-Object Name)){(ConvertTo-Json -InputObject $p.Name -Compress)+':'+(ConvertTo-WizardCanonicalJson $p.Value)})
        return '{'+($pairs -join ',')+'}'
    }
    if($Value -is [Collections.IEnumerable]){return '['+(@(foreach($item in $Value){ConvertTo-WizardCanonicalJson $item}) -join ',')+']'}
    return ConvertTo-Json -InputObject $Value -Compress
}
function Get-WizardSettingsHash($Data) {
    $content=Copy-TransportObject $Data
    foreach($name in @('revision','id')){$content.PSObject.Properties.Remove($name)}
    Get-TransportFingerprint 'config-settings-v2' (ConvertTo-WizardCanonicalJson $content)
}
function Sync-WizardConfigSettings([string]$Root,[string]$Bundle,$Request) {
    $step='Проверка незавершённого обновления';$snapshot=$null
    try{
        $confirmed=$true
        if(Test-Path (Join-Path $Root 'state/wizard-network.json')){
            $confirmed=Invoke-WizardResourceSet $Root @('connection','vpn') {Confirm-WizardConfigSettings $Root} 1000
        }
        if(-not $confirmed){return @{ok=$true;changed=$false;summary='Ожидается проверка обновлённой связи; независимый откат включён'}}
        $step='Получение снимка и каталога сервера'
        # Both files in one authenticated round trip. The catalog stays authoritative
        # even if the administrator has not republished config-sync.json yet.
        $source=Convert-TransportLF ([IO.File]::ReadAllText((Join-Path $Bundle 'transport/server-transport-catalog.py')))
        $text=Get-WizardConfigSettings $Root 'python3 - sync' $source
        if($text.Length -gt 2097152){throw 'Слишком большой снимок настроек и каталога'}
        $step='Разбор снимка и каталога сервера'
        try{$snapshot=ConvertFrom-Json (Convert-TransportLF $text)}catch{throw 'Сервер вернул повреждённый JSON настроек или каталога'}
        $data=ConvertFrom-WizardConfigSync $snapshot.snapshot
        Assert-WizardCatalog $snapshot.catalog
        $data.bootstrap|Add-Member -Force catalog $snapshot.catalog
        $step='Применение изменённых настроек'
        $request=[pscustomobject]@{data=$data;trustedSsh=$true;askpassExecutable=[string]$Request.askpassExecutable}
        return Update-WizardConfigSettings $Root $Bundle $request
    }catch{
        throw ($step+': '+(Protect-TransportDiagnostic ([string]$_.Exception.Message) $snapshot))
    }
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
function Update-WizardConfigSettings([string]$Root,[string]$Bundle,$Request) {
    $data=$Request.data;if(-not $data){$data=Read-TransportJson ([string]$Request.path)}
    if($data.schema -ne 1 -or $data.type -ne 'settings'){throw 'Неизвестная схема обновления'}
    $profileFile=Find-InstallProfile $Root
    if(-not $profileFile){throw 'Этот компьютер ещё не подключён. Примените конфиг с ключом доступа'}
    $profile=Read-TransportJson $profileFile
    if($data.type -ne 'settings' -or -not $Request.trustedSsh){throw 'Настройки разрешены только через уже доверенный SSH-канал'}
    if($data.workerUser -cne $profile.login){throw 'Обновление не может сменить рабочего пользователя'}
    $fingerprint=Get-WizardSettingsHash $data
    $lastFile=Join-Path $Root 'state/config-settings-version.json'
    if(Test-Path $lastFile){
        $last=Read-TransportJson $lastFile
        $same=$last.hash -ceq $fingerprint
        # A successful older sync already proved this exact content. Upgrade its
        # receipt without spawning another daemon just because the hash format changed.
        if(-not $same -and -not $last.schema){
            $legacy=Get-TransportFingerprint 'config-settings' (ConvertTo-Json $data -Depth 40 -Compress)
            if($last.hash -ceq $legacy){
                Invoke-WizardResourceSet $Root @('connection','vpn') {
                    if(Test-Path (Join-Path $Root 'state/wizard-network.json')){throw 'Есть незавершённая настройка связи'}
                    Write-TransportJson $lastFile @{schema=2;hash=$fingerprint}
                } 1000
                $same=$true
            }
        }
        if($same){return @{ok=$true;changed=$false;summary='Настройки и каталог сервера не изменились'}}
    }
    [void](Get-WizardDeviceKey $profile)
    $stage=Join-Path $Root ('state/connection-generations/'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage);Protect-TransportPath $stage
    $previous=Read-TransportJson (Join-Path $Root 'config.json')
    Write-TransportJson (Join-Path $stage 'config.json') $previous -Private
    $copy=Copy-TransportObject $data;$copy|Add-Member -Force id ([guid]::NewGuid().ToString('N'))
    $source=Join-Path $stage 'settings.json';Write-TransportJson $source $copy -Private
    $r=[pscustomobject]@{path=$source;hostId=(Split-Path (Split-Path $profileFile -Parent) -Leaf);keyPath=[string]$profile.keyPath;askpassExecutable=[string]$Request.askpassExecutable;hopPasswordPipe=[string]$Request.hopPasswordPipe}
    # Stage pins/profile without ever generating a replacement device key.
    $prepared=Initialize-WizardSettingsProfile $stage $r
    Update-LauncherConfig $stage {param($c) $c.transport|Add-Member -Force profilePath $prepared.file}
    Set-WizardRefreshSnapshot $stage $copy
    # With a channel, the isolated daemon proves the routes with the new pins.
    # Do not repeat direct SSH handshakes before that proof.
    if($copy.bootstrap.channel){
        $r|Add-Member deferProof $true
        [void](Connect-WizardSnapshot $stage $r)
    }else{
        try{[void](Connect-WizardSnapshot $stage $r)}catch{
            # Other cached transport paths can still work after explicit SSH fails.
            $r|Add-Member deferProof $true
            [void](Connect-WizardSnapshot $stage $r)
        }
    }
    $candidate=Read-TransportJson (Join-Path $stage 'config.json');$nextProfile=Read-TransportJson $candidate.transport.profilePath
    # Replace the previous transport overlay with the route proved by this snapshot.
    $overlay=Get-TransportRouteOverlay $candidate.wizard.serverRoute $Root
    if($overlay){$candidate.transport|Add-Member -Force serverRoute $overlay}else{$candidate.transport.PSObject.Properties.Remove('serverRoute')}
    Write-TransportJson (Join-Path $stage 'config.json') $candidate -Private
    # Expensive staging/proof owns no live resource lock.
    Invoke-TransportPreflight $stage $Bundle $candidate
    $available=$null
    if((Read-TransportPin $Root).mode -eq 'pinned'){$available=Get-TransportCandidates (Read-TransportSettings $stage) $stage}
    Invoke-WizardResourceSet $Root @('connection','vpn') {
        $current=Read-TransportJson (Join-Path $Root 'config.json')
        $before=@($previous.transport,$previous.vpn,$previous.wizard.serverRoute,$profile)
        $now=@($current.transport,$current.vpn,$current.wizard.serverRoute,(Read-TransportJson $profileFile))
        if((ConvertTo-WizardCanonicalJson $before) -cne (ConvertTo-WizardCanonicalJson $now)){
            throw 'Настройки связи изменились во время сверки; повторите после завершения настройки'
        }
        $networkReceipt=Join-Path $Root 'state/wizard-network.json'
        if(Test-Path $networkReceipt){throw 'Есть незавершённая настройка связи; дождитесь проверки или отката'}
        $oldPin=Read-TransportPin $Root;$resetPin=$false
        if($oldPin.mode -eq 'pinned'){
            if(-not $available){throw 'Режим выбора пути изменился во время сверки; повторите после завершения настройки'}
            $resetPin=([string]$oldPin.tag -notin @($available.Candidates|ForEach-Object {$_.tag}))
        }
        # A removed pinned path must not prevent proving its replacement. The stage
        # has its own automatic selector; live pin intent changes only after proof.
        $session=[guid]::NewGuid().ToString('N');$mark=[DateTime]::UtcNow
        $task='RemoteAgents settings rollback '+(Get-TransportFingerprint 'settings' $Root.ToLowerInvariant()).Substring(0,16)
        Write-TransportJson $networkReceipt @{schema=1;session=$session;task=$task;mark=$mark.ToString('o');previous=$previous.transport;profileFile=$profileFile;profile=$profile;vpn=$previous.vpn;serverRoute=$previous.wizard.serverRoute;versionFile=$lastFile;pin=$(if($resetPin){$oldPin}else{$null})} -Private -Durable
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
            Wait-WizardWorkingProof $Root $mark 45
            Remove-Item -LiteralPath $networkReceipt -Force
            Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
            Write-TransportJson $lastFile @{schema=2;hash=$fingerprint}
            return @{ok=$true;changed=$true;summary='Настройки связи обновлены; VPN подхватит новые пути автоматически'}
        }catch{
            Undo-WizardNetwork $Root $session
            throw
        }
    } 1000
}
