#requires -Version 5.1
# The interactive legacy installer cannot be embedded without opening its console/askpass UI.
# Reuse its OpenSSH/key/profile contract; the wizard supplies a one-use in-memory askpass.
function Write-WizardProgress([string]$Text) {
    if($script:WizardProgressFile){[IO.File]::AppendAllText($script:WizardProgressFile,((@{text=$Text}|ConvertTo-Json -Compress)+"`n"),(New-Object Text.UTF8Encoding($false)))}
}
function Invoke-WizardLogin($Profile,[string]$User,[string]$Command,[string]$InputText='', $Credential=$null) {
    $args=@('-F',$Profile.configPath,'-T','-l',$User,'-i',$Profile.keyPath,'-o','IdentitiesOnly=yes','-o','ConnectTimeout=5','-o','ConnectionAttempts=1','-o',('UserKnownHostsFile="'+$Profile.knownHostsPath.Replace('\','/')+'"'),'-o','GlobalKnownHostsFile=none','-o','ForwardAgent=no','-o','ClearAllForwardings=yes')
    if(-not $Credential){return Invoke-DiskProcess $Profile.sshExecutable ($args+@('-o','BatchMode=yes','-o','StrictHostKeyChecking=accept-new',$Profile.serverAddress,$Command)) $InputText -TimeoutSeconds 20}
    $si=New-Object Diagnostics.ProcessStartInfo
    $si.FileName=$Profile.sshExecutable;$si.Arguments=(($args+@('-o','BatchMode=no','-o','StrictHostKeyChecking=accept-new','-o','NumberOfPasswordPrompts=1','-o','PreferredAuthentications=password','-o','PubkeyAuthentication=no',$Profile.serverAddress,$Command))|ForEach-Object {Quote-Disk $_}) -join ' '
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    $si.EnvironmentVariables['SSH_ASKPASS']=[string]$Credential.askpassExecutable
    $si.EnvironmentVariables['SSH_ASKPASS_REQUIRE']='force';$si.EnvironmentVariables['DISPLAY']='remoteagents:0'
    $si.EnvironmentVariables['REMOTEAGENTS_PASSWORD_PIPE']=[string]$Credential.passwordPipe
    $p=New-Object Diagnostics.Process;$p.StartInfo=$si
    try {
        [void]$p.Start();$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
        $bytes=[Text.Encoding]::UTF8.GetBytes((Convert-TransportLF $InputText));$task=$p.StandardInput.BaseStream.WriteAsync($bytes,0,$bytes.Length)
        if(-not $task.Wait(5000)){throw 'Таймаут отправки SSH'};$p.StandardInput.Close()
        if(-not $p.WaitForExit(30000)){throw 'SSH не отвечает (таймаут 30 с)'}
        if($p.ExitCode -ne 0){throw 'Вход по паролю не выполнен. Проверьте пароль; если root-вход по паролю запрещён, администратор должен разрешить ключ рабочего пользователя. Изменённый ключ сервера требует проверки known_hosts'}
        return Convert-TransportLF $out.GetAwaiter().GetResult()
    }finally{if($p.Id -and -not $p.HasExited){$p.Kill()};$p.Dispose()}
}
function Connect-WizardServer([string]$Root,[string]$Bundle,$Request) {
    $address=[string]$Request.address;$user=[string]$Request.login;if(-not $user){$user='root'}
    if($address -notmatch '\A[a-zA-Z0-9][a-zA-Z0-9.:-]{0,252}\z' -or $user -notmatch '\A[a-z_][a-z0-9_-]{0,31}\z'){throw 'Укажите адрес сервера и корректный логин SSH'}
    $old=Find-InstallProfile $Root;$previous=$null
    if($old -and (Test-Path $old)){$previous=Read-TransportJson $old}
    if($previous -and $previous.serverAddress -ceq $address -and $previous.login -ceq $user){
        try{[void](Invoke-WizardSsh $Root 'true' '' 10);Update-MigrationConfig $Root {param($c) if(-not $c.transport.profilePath -and -not $c.wizard.pendingProfile){Set-MigrationDefault $c transport ([pscustomobject]@{});$c.transport|Add-Member -Force profilePath $old}};return $old}catch{}
    }
    $id=(Get-TransportFingerprint $address $user).Substring(0,20)
    $dir=Join-Path $Root ('ssh-profiles/'+$id+'/project-connections/control')
    [void][IO.Directory]::CreateDirectory($dir);Protect-TransportPath $dir
    $file=Join-Path $dir 'ssh-transport.json'
    $p=[pscustomobject]@{sshExecutable=@(Get-Command ssh -CommandType Application -ErrorAction Stop)[0].Source;serverAddress=$address;login=$user;keyPath=(Join-Path $dir 'id_ed25519');knownHostsPath=(Join-Path $dir 'known_hosts');configPath=(Join-Path $dir 'ssh.conf')}
    if($env:OS -eq 'Windows_NT'){$p.sshExecutable=@(Get-Command ssh.exe -CommandType Application -ErrorAction Stop)[0].Source}
    Write-DiskUtf8 $p.configPath "Host *`n    Port 22`n    ConnectTimeout 5`n"
    if(-not (Test-Path $p.keyPath)){
        Write-WizardProgress 'Создаю ключ этого компьютера…'
        $keygen=@(Get-Command ssh-keygen -CommandType Application -ErrorAction Stop)[0].Source
        [void](Invoke-DiskProcess $keygen @('-q','-t','ed25519','-N','','-f',$p.keyPath));Protect-TransportPath $p.keyPath
    }
    # A successful previous root bootstrap is resumed directly as the worker, without a password.
    $worker=if($user -ceq 'root'){'remoteagents'}else{$user}
    Write-WizardProgress ('Подключаюсь к серверу '+$address+' по ключу…')
    $ready=$false;try{[void](Invoke-WizardLogin $p $worker 'true');$ready=$true}catch{}
    if(-not $ready){
        $key=(Convert-TransportLF ([IO.File]::ReadAllText($p.keyPath+'.pub'))).Trim()
        if($key -notmatch '\Assh-ed25519 [A-Za-z0-9+/=]+(?: [^\r\n]*)?\z'){throw 'Некорректный открытый ключ'}
        $script=Convert-TransportLF ([IO.File]::ReadAllText((Join-Path $Bundle 'build/server-ssh-user.sh')))
        $payload=$worker+"`n"+$key+"`n"+$script
        # read public parameters first, then execute the same idempotent server helper.
        $command='IFS= read -r ra_user; IFS= read -r ra_key; export ra_user ra_key; bash -s'
        try{[void](Invoke-WizardLogin $p $user $command $payload)}catch{
            if(-not $Request.passwordPipe){throw 'Ключ не принят. Введите пароль в этом окне. Новый сервер запоминается при первом входе; изменение его ключа не принимается'}
            Write-WizardProgress ('Вхожу как '+$user+' и настраиваю ключ рабочего пользователя…')
            [void](Invoke-WizardLogin $p $user $command $payload $Request)
        }
        [void](Invoke-WizardLogin $p $worker 'true')
    }
    $p.login=$worker
    $p|Add-Member arguments @('-F',$p.configPath,'-l',$worker,'-i',$p.keyPath,'-o','IdentitiesOnly=yes','-o',('UserKnownHostsFile="'+$p.knownHostsPath.Replace('\','/')+'"'),'-o','GlobalKnownHostsFile=none','-o','StrictHostKeyChecking=yes','-o','BatchMode=yes','-T',$address)
    Write-TransportJson $file $p -Private
    $changed=$previous -and ($previous.serverAddress -cne $address -or $previous.login -cne $worker)
    Update-MigrationConfig $Root {param($c)
        if($changed){
            Set-MigrationDefault $c wizard ([pscustomobject]@{})
            if(-not $c.wizard.diskPreviousProfile){$c.wizard|Add-Member -Force diskPreviousProfile $old}
            $c.wizard|Add-Member -Force configured $false
            $c.wizard.PSObject.Properties.Remove('localCatalog')
            foreach($flag in @('skipDisk','skipHappier','skipLan','diskKeepPrevious')){$c.wizard.PSObject.Properties.Remove($flag)}
            # Preserve other product settings, but never reuse another server's nodes or keys.
            $c.wizard|Add-Member -Force pendingProfile $file
        }else{Set-MigrationDefault $c transport ([pscustomobject]@{});$c.transport|Add-Member -Force profilePath $file}
    }
    if($changed){
        foreach($name in @('happier-account.json')){$state=Join-Path $Root ('state/'+$name);if(Test-Path $state){Move-Item $state ($state+'.previous-'+[guid]::NewGuid().ToString('N'))}}
    }
    return $file
}

function Initialize-WizardTransport([string]$Root,[string]$Bundle,$Transport) {
    $config=Read-TransportJson (Join-Path $Root 'config.json')
    $profile=Find-InstallProfile $Root;$p=Read-TransportJson $profile
    if(-not $Transport.profilePath){$Transport|Add-Member -Force profilePath $profile}
    # Preserve the existing H channel only when it belongs to this same server.
    $diskProfile=Join-Path $env:LOCALAPPDATA 'RemoteDisk/profile.txt'
    $legacy=Join-Path $env:LOCALAPPDATA 'RemoteDisk/channel/config.json'
    if(-not $Transport.channelPath -and -not $config.wizard.diskPreviousProfile -and (Test-Path $diskProfile) -and (Test-Path $legacy)){
        $dp=Read-TransportJson ([IO.File]::ReadAllText($diskProfile).Trim())
        if($dp.serverAddress -ceq $p.serverAddress -and $dp.login -ceq $p.login){$Transport|Add-Member -Force channelPath $legacy}
    }
    if(-not $Transport.channelPath){
        $file=Join-Path $Root ('state/wizard-channel-'+(Get-TransportFingerprint $p.serverAddress $p.login).Substring(0,16)+'.json')
        # Reuse the existing server channel exporter when the owner already has VLESS.
        Send-WizardHelpers $Root $Bundle
        $hasVless=Invoke-WizardSsh $Root 'test -r /etc/sing-box/config.json && echo yes || echo no'
        if($hasVless.Trim() -eq 'yes'){
            $request=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{server=$p.serverAddress}|ConvertTo-Json -Compress)))
            $channel=ConvertFrom-Json (Convert-TransportLF (Invoke-WizardSsh $Root ('bash "$HOME/.local/share/remote-disk/server-disk.sh" channel-config '+$request)))
        }else{
            $ports=ConvertFrom-Json (Convert-TransportLF (Invoke-WizardSsh $Root 'cat "$HOME/.local/share/remote-disk/ports.json"'))
            if([int]$ports.listen -lt 1 -or [int]$ports.listen -gt 65535){throw 'Нет порта сервера Disk. Включите установку недостающего на шаге «Сервер» и повторите'}
            $channel=@{inbounds=@(@{tag='sync';override_port=[int]$ports.listen});outbounds=@()}
        }
        Write-TransportJson $file $channel -Private
        $Transport|Add-Member -Force channelPath $file
    }
    if(-not $Transport.singBoxPath -or -not (Test-Path $Transport.singBoxPath)){
        Write-WizardProgress 'Подготавливаю программу связи (загрузка с проверкой SHA-256)…'
        . (Join-Path $Bundle 'disk/Disk.Binary.ps1')
        Install-DiskBinary 'https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-windows-amd64.zip' '99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df' 'transport-bin' 'sing-box.exe' $Root
        $Transport|Add-Member -Force singBoxPath (Join-Path $Root 'transport-bin/sing-box.exe')
    }
}
