#requires -Version 5.1
# Called under the existing wizard lock. Reuse New-WizardRoutes/Invoke-WizardLogin,
# but invitation enrollment never probes with the one-use key or accepts new hosts.
function Connect-WizardInvite([string]$Root,$Request) {
    $invite=Read-TransportJson ([string]$Request.path)
    if($invite.schema -ne 1){throw 'Неизвестная схема приглашения. Попросите новое приглашение'}
    if([string]$invite.id -cnotmatch '\A[a-f0-9]{32}\z' -or [string]$invite.serverAddress -notmatch '\A[a-zA-Z0-9][a-zA-Z0-9.:-]{0,252}\z' -or [string]$invite.workerUser -notmatch '\A[a-z_][a-z0-9_-]{0,31}\z' -or [string]$invite.enrollUser -notmatch '\A[a-z_][a-z0-9_-]{0,31}\z'){throw 'Повреждённое приглашение'}
    $port=[int]$invite.serverPort;if($port -lt 1 -or $port -gt 65535){throw 'Некорректный порт приглашения'}
    $id=(Get-TransportFingerprint ([string]$invite.serverAddress+':'+$port) ([string]$invite.workerUser)).Substring(0,20)
    $dir=Join-Path $Root ('ssh-profiles/'+$id+'/project-connections/control')
    [void][IO.Directory]::CreateDirectory($dir);Protect-TransportPath $dir
    $p=[pscustomobject]@{sshExecutable=@(Get-Command ssh -CommandType Application -ErrorAction Stop)[0].Source;serverAddress=[string]$invite.serverAddress;login=[string]$invite.workerUser;keyPath=(Join-Path $dir 'id_ed25519');knownHostsPath=(Join-Path $dir 'known_hosts');configPath=(Join-Path $dir 'ssh.conf');strictHostKey=$true}
    $file=Join-Path $dir 'ssh-transport.json'
    Write-DiskUtf8 $p.configPath ("Host *`n    Port "+$port+"`n    ConnectTimeout 5`n")
    $hostName=if($port -eq 22){$p.serverAddress}else{'['+$p.serverAddress+']:'+$port}
    $pins=@();foreach($key in @($invite.hostKeys)){
        if([string]$key -cnotmatch '\A(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+\z'){throw 'Некорректный ключ хоста в приглашении'}
        $pins+=($hostName+' '+$key);if($port -ne 22){$pins+=($p.serverAddress+' '+$key)}
    }
    if(-not $pins.Count){throw 'Приглашение не содержит ключей хоста'}
    Write-DiskUtf8 $p.knownHostsPath (($pins -join "`n")+"`n")
    if(-not (Test-Path -LiteralPath $p.keyPath)){
        $keygen=@(Get-Command ssh-keygen -CommandType Application -ErrorAction Stop)[0].Source
        [void](Invoke-DiskProcess $keygen @('-q','-t','ed25519','-N','','-f',$p.keyPath));Protect-TransportPath $p.keyPath
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'secrets'));Protect-TransportPath (Join-Path $Root 'secrets')
    $pass=Join-Path $Root 'secrets/invite-pass';$ok=$false;$lastReason='Нет связи ни одним из маршрутов приглашения';$chosenRequest=$null
    try{
        foreach($route in @($invite.routes)){
            $r=[pscustomobject]@{askpassExecutable=[string]$Request.askpassExecutable;strictHostKey=$true}
            if($route.kind -eq 'proxy'){$r|Add-Member proxy $route.proxy}
            elseif($route.kind -eq 'hop'){
                $hop=$route.hop.PSObject.Copy()
                if(-not $hop.hostKey){throw 'Нет ключа промежуточного сервера'}
                if($hop.privateKey){$hopKey=Join-Path $Root 'secrets/invite-hop';Write-DiskUtf8 $hopKey ([string]$hop.privateKey);Protect-TransportPath $hopKey;$hop|Add-Member -Force keyFile $hopKey}
                if($hop.password){$hop|Add-Member -Force passwordPipe ([string]$Request.hopPasswordPipe)}
                $r|Add-Member hop $hop
            }elseif($route.kind -ne 'direct'){throw 'Неизвестный маршрут приглашения'}
            $variants=New-WizardRoutes $r $p;$variants=@($variants|Where-Object {$_.kind -eq $route.kind})
            foreach($variant in $variants){
                $script:WizardRoute=$variant
                Write-WizardProgress ('Подключаюсь: '+$variant.title)
                # Resuming a lost reply is safe: first check this computer's own key.
                try{[void](Invoke-WizardLogin $p $p.login 'true');$ok=$true}catch{
                    if($_.Exception.Message -like '*Ключ хоста*'){throw}
                }
                if(-not $ok){
                    if([DateTimeOffset]::Parse([string]$invite.expiresUtc) -le [DateTimeOffset]::UtcNow){throw 'Срок приглашения истёк. Попросите администратора создать новое'}
                    Write-DiskUtf8 $pass ([string]$invite.passKey);Protect-TransportPath $pass
                    $q=$p.PSObject.Copy();$q.keyPath=$pass
                    try{
                        $reply=ConvertFrom-Json (Convert-TransportLF (Invoke-WizardLogin $q ([string]$invite.enrollUser) 'enroll' ([IO.File]::ReadAllText($p.keyPath+'.pub'))))
                        if(-not $reply.ok){throw ([string]$reply.reason)}
                        [void](Invoke-WizardLogin $p $p.login 'true');$ok=$true
                    }catch{
                        if($_.Exception.Message -like '*Ключ хоста*'){throw}
                        $lastReason=if($_.Exception.Message -like '*отклонил вход*' -or $_.Exception.Message -like '*код выхода 1)*'){'Приглашение уже использовано, отозвано или регистрация отклонена сервером. Попросите администратора проверить invite list и создать новое'}else{'Нет связи по маршрутам приглашения. Проверьте интернет, локальный прокси или промежуточный сервер и нажмите «Повторить»'}
                        continue
                    }
                }
                if($ok){$chosenRequest=$r;break}
            }
            if($ok){break}
        }
        if(-not $ok){throw $lastReason}
        if($script:WizardRoute.kind -eq 'hop' -and $chosenRequest.hop.password){
            $m=[regex]::Match([string]$chosenRequest.hop.ssh,'\A(?:([a-z_][a-z0-9_-]{0,31})@)?([a-zA-Z0-9][a-zA-Z0-9.-]{0,252})(?::(\d{1,5}))?\z')
            if(-not $m.Groups[1].Success){throw 'В приглашении нужен явный логин промежуточного сервера'}
            $hopSettings=Join-Path $Root 'secrets/invite-hop.json'
            Write-TransportJson $hopSettings @{sshExecutable=$p.sshExecutable;configPath=$p.configPath;knownHostsPath=(Join-Path $dir 'known_hosts-hop');host=$m.Groups[2].Value;port=$(if($m.Groups[3].Success){[int]$m.Groups[3].Value}else{22});user=$m.Groups[1].Value;password=[string]$chosenRequest.hop.password} -Private
            $script:WizardRoute.options=@('-o',('ProxyCommand='+(Quote-Disk ([string]$Request.askpassExecutable))+' --invite-hop '+(Quote-Disk $hopSettings)+' %h %p'))
        }
        $proxyOption=@($script:WizardRoute.options|Where-Object {$_ -like 'ProxyCommand=*'})
        if($proxyOption.Count){$p|Add-Member inviteProxyCommand ($proxyOption[0].Substring(13))}
        $p|Add-Member arguments (@('-F',$p.configPath,'-p',[string]$port,'-l',$p.login,'-i',$p.keyPath,'-o','IdentitiesOnly=yes','-o',('UserKnownHostsFile="'+$p.knownHostsPath.Replace('\','/')+'"'),'-o','GlobalKnownHostsFile=none','-o','StrictHostKeyChecking=yes','-o','BatchMode=yes','-o','ForwardAgent=no')+@($script:WizardRoute.options)+@('-T',$p.serverAddress))
        Write-TransportJson $file $p -Private
        Save-WizardRoute $Root $chosenRequest $p
        Update-LauncherConfig $Root {param($c) Set-ConfigDefault $c transport ([pscustomobject]@{});$c.transport|Add-Member -Force profilePath $file}
        return @{ok=$true;profile=$file;summary='Ключ компьютера зарегистрирован; вход своим ключом проверен'}
    }finally{if(Test-Path -LiteralPath $pass){Remove-Item -LiteralPath $pass -Force};$script:WizardRoute=$null}
}
function Connect-WizardInviteAccount([string]$Root,[string]$Bundle,$Request) {
    $rows=@((Invoke-WizardStep $Root $Bundle 'AccountList' ([pscustomobject]@{})).accounts)
    if($Request.account){$rows=@($rows|Where-Object {$_.account -ceq [string]$Request.account})}
    if($rows.Count -ne 1){throw 'На сервере несколько аккаунтов Happier или нет аккаунта. Администратору: задайте happierAccount в настройках приглашений'}
    $row=$rows[0]
    if($Request.mode -eq 'same'){
        $body=@{action='inspect';account=[string]$row.account}|ConvertTo-Json -Compress
        $status=ConvertFrom-Json (Convert-TransportLF (Invoke-WizardSsh $Root 'export PATH="$HOME/.local/share/remoteagents-accounts/node:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"; node "$HOME/.local/share/remoteagents-accounts/server-account.mjs"' $body))
        if(-not $status.ok){throw 'Happier на сервере не подтвердил работу выбранного аккаунта'}
        # Same workstation: the existing server daemon and its subscriptions are reused.
        # No recovery secret exists on the server and none needs to travel to the PC.
        $row|Add-Member -Force ok $true;$row|Add-Member -Force updatedUtc ([DateTime]::UtcNow.ToString('o'))
        Write-TransportJson (Join-Path $Root 'state/happier-account.json') $row
        Update-LauncherConfig $Root {param($c) $c|Add-Member -Force happier ([pscustomobject]@{label=[string]$row.label;serverUrl=[string]$row.serverUrl;webappUrl=[string]$row.webappUrl})}
        return @{ok=$true;summary='Существующий аккаунт Happier проверен'}
    }
    if([string]$Request.mode -notlike 'new:*'){throw 'Некорректный выбор Happier'}
    return Invoke-WizardAccount $Root $Bundle ([pscustomobject]@{label=([string]$Request.mode).Substring(4);serverUrl=[string]$row.serverUrl;webappUrl=[string]$row.webappUrl;expectedAccount=''}) $true
}
