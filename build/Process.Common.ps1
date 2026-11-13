#requires -Version 5.1
$ErrorActionPreference='Stop'
# .NET Framework writes Console.InputEncoding's BOM into every redirected stdin; on a UTF-8 console that corrupts the first line sent to ssh.
try{[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false);if([Console]::InputEncoding.GetPreamble().Length){[Console]::InputEncoding=New-Object Text.UTF8Encoding($false)}}catch{}
function Write-DiskUtf8($File,[string]$Text) {[IO.File]::WriteAllText($File,$Text.Replace("`r",''),(New-Object Text.UTF8Encoding($false)))}
function Write-DiskProgress([string]$Text) {
    if(-not $env:REMOTEAGENTS_WIZARD_PROGRESS){Write-Output $Text;return}
    try{[IO.File]::AppendAllText($env:REMOTEAGENTS_WIZARD_PROGRESS,((@{text=$Text}|ConvertTo-Json -Compress)+"`n"),(New-Object Text.UTF8Encoding($false)))}catch{}
}
function Quote-Disk([string]$Value) {'"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'}
function Get-DiskServerFailure([string]$Text) {
    foreach($line in ($Text.Replace("`r",'') -split "`n")){
        $clean=($line -replace '\x1b\[[0-9;]*[a-zA-Z]','').Trim()
        if(-not $clean -or $clean -match '^(Warning: Permanently added|Connection to .* closed\.?$)'){continue}
        return Protect-TransportText $clean
    }
    return ''
}
function Invoke-DiskProcess($Exe,$Arguments,[string]$InputText='',[string]$OutputFile='',[int]$TimeoutSeconds=45) {
    $si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=$Exe;$si.Arguments=($Arguments|ForEach-Object {Quote-Disk ([string]$_)}) -join ' '
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true;$si.StandardOutputEncoding=New-Object Text.UTF8Encoding($false);$si.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
    $p=New-Object Diagnostics.Process;$p.StartInfo=$si;$file=$null;$err=$null
    # The wizard journal (Write-WizardTrace) gets every SSH run with its stderr; elsewhere nothing is traced.
    $trace=if([IO.Path]::GetFileNameWithoutExtension([string]$Exe) -match '\A(ssh|scp|sftp)\z'){Get-Command Write-WizardTrace -ErrorAction SilentlyContinue};$watch=[Diagnostics.Stopwatch]::StartNew()
    try {[void]$p.Start();$err=$p.StandardError.ReadToEndAsync()
        if($OutputFile){$file=[IO.File]::Create($OutputFile);$out=$p.StandardOutput.BaseStream.CopyToAsync($file)}else{$out=$p.StandardOutput.ReadToEndAsync()}
        $bytes=[Text.Encoding]::UTF8.GetBytes($InputText.Replace("`r",''));$write=$p.StandardInput.BaseStream.WriteAsync($bytes,0,$bytes.Length)
        # ssh reads stdin only after the session is up; via a hop that alone can exceed 15 s.
        $inputFailure=$null
        try{if(-not $write.Wait([Math]::Max(15,$TimeoutSeconds)*1000)){throw 'Таймаут ввода'}}catch{
            # A server can refuse before reading stdin. Its stderr/exit code is more useful than Broken pipe.
            if(-not $p.WaitForExit(1000)){throw};$inputFailure=$_
        }
        try{$p.StandardInput.Close()}catch{if(-not $p.HasExited){throw};if(-not $inputFailure){$inputFailure=$_}}
        if(-not $p.WaitForExit($TimeoutSeconds*1000)){$p.Kill();throw 'Таймаут команды'};$out.GetAwaiter().GetResult() | Out-Null
        if($p.ExitCode -ne 0){$reason='Внешняя команда не выполнена';if($p.ExitCode -eq 255 -and [IO.Path]::GetFileNameWithoutExtension($Exe) -ieq 'ssh'){$reason=if($err.Result -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed'){"Ключ хоста не совпал с приглашением или known_hosts. Подключение остановлено; попросите администратора проверить ключ сервера"}elseif($err.Result -match 'Permission denied'){'Сервер отклонил вход'}elseif($err.Result -match 'Remote protocol version' -and $err.Result -match 'timed out|Connection reset'){'Сервер ответил, но сеть глушит SSH после рукопожатия — нужен обход (канал через промежуточный сервер)'}elseif($err.Result -match 'banner exchange|kex_exchange_identification|Connection closed|Connection reset|timed out'){'Нет SSH-баннера от сервера'}else{'Нет связи с сервером'};if($err.Result -match 'proxy-connect: ([^\r\n]+)'){$reason+=': '+$Matches[1]}}elseif([IO.Path]::GetFileNameWithoutExtension($Exe) -ieq 'ssh'){$detail=Get-DiskServerFailure $err.Result;if($detail){$reason=$detail}};throw ($reason+' (код выхода '+$p.ExitCode+')')}
        if($inputFailure){throw $inputFailure}
        if(-not $OutputFile){$out.Result.Replace("`r",'').TrimStart([char]0xFEFF).Trim()}
    }finally{if($file){$file.Dispose()};if($p.Id -and -not $p.HasExited){$p.Kill()}
        if($trace){try{$code=if($p.HasExited){[string]$p.ExitCode}else{'прервано'};$text=if($err -and $err.Wait(2000)){$err.Result}else{''};Write-WizardTrace $Exe $si.Arguments $code $watch.ElapsedMilliseconds $text}catch{}}
        $p.Dispose()}
}
function Read-DiskProfile([string]$Profile) {
    # For Happier and first run the launcher's chosen profile wins: an older setup may leave a second one.
    if(-not $Profile){$launcher=Join-Path $env:LOCALAPPDATA 'RemoteAgents/config.json';if(Test-Path -LiteralPath $launcher){try{$c=[IO.File]::ReadAllText($launcher)|ConvertFrom-Json;$chosen=[string]$c.wizard.pendingProfile;if(-not $chosen){$chosen=[string]$c.transport.profilePath};if($chosen -and (Test-Path -LiteralPath $chosen)){$Profile=$chosen}}catch{}}}
    if(-not $Profile){$files=@(Get-ChildItem -Path "$env:LOCALAPPDATA/RemoteAgents/ssh-profiles/*/project-connections/*/ssh-transport.json" -File);if($files.Count -ne 1){throw 'Укажите -Profile: нужен один SSH-профиль'};$Profile=$files[0].FullName}
    $script:ProfilePath=[IO.Path]::GetFullPath($Profile);$script:Connection=[IO.File]::ReadAllText($script:ProfilePath)|ConvertFrom-Json
    foreach($f in @('sshExecutable','arguments','serverAddress','login','keyPath','knownHostsPath','configPath')){if(-not $script:Connection.$f){throw 'Неполный SSH-профиль'}}
    if($script:Connection.login.Trim() -ieq 'root'){throw 'SSH-профиль должен входить как рабочий пользователь, не root'}
}
function Invoke-DiskSsh($Command,[switch]$Direct,[string]$InputText='',[string]$OutputFile='',[int]$TimeoutSeconds=45) {
    $c=$script:Connection;$args=@('-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes')
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'transport/Transport.Common.ps1')
    $root=Join-Path $env:LOCALAPPDATA 'RemoteAgents';$launcher=Join-Path $root 'config.json'
    $localPort=[int](Get-TransportEffectivePort $root 'sshPort')
    if($Direct){
        $root=Split-Path $launcher -Parent
        # A manually selected profile must never inherit another server's personal route.
        if(Test-Path -LiteralPath $launcher){
            $config=Read-TransportJson $launcher
            $routeProfile=[string]$config.transport.profilePath;if($config.wizard.pendingProfile){$routeProfile=[string]$config.wizard.pendingProfile}
            if($routeProfile -and $script:ProfilePath -eq [IO.Path]::GetFullPath($routeProfile)){
                if($script:WizardRoute){$args+=@($script:WizardRoute.options)}else{$args+=@(Get-TransportSavedRouteOptions $root $c)}
            }
        }
        $args+=@($c.arguments)
    }else{$args+=@('-F','NUL','-p',[string]$localPort,'-i',$c.keyPath,'-o',('HostKeyAlias='+$c.serverAddress),'-o',('UserKnownHostsFile="'+$c.knownHostsPath.Replace('\','/')+'"'),'-o','IdentitiesOnly=yes',($c.login+'@127.0.0.1'))}
    Invoke-DiskProcess $c.sshExecutable ($args+@($Command)) $InputText $OutputFile -TimeoutSeconds $TimeoutSeconds
}
