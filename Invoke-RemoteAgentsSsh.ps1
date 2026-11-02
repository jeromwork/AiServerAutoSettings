[CmdletBinding()]
param([Parameter(Mandatory=$true)]$Request,[Parameter(Mandatory=$true)]$Connection,[Parameter(Mandatory=$true)][string]$DataDir)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Windows.Paths.ps1')
Set-StrictMode -Off
function Quote-Native([string]$Value) {
    $escaped=[regex]::Replace($Value,'(\\*)"','$1$1\"')
    $escaped=[regex]::Replace($escaped,'(\\+)$','$1$1')
    '"' + $escaped + '"'
}
function Quote-Shell([string]$Value) {
    $single=[string][char]39;$double=[string][char]34
    $single+$Value.Replace($single,($single+$double+$single+$double+$single))+$single
}
function Send-TransferProgress([long]$Done=-1,[long]$Total=-1,[string]$Stage,[string]$Message) {
    if(!$Stage){$Stage=if($Request.stage){[string]$Request.stage}else{[string]$Request.action}}
    if(!$Message){$Message=if($Request.message){[string]$Request.message}else{'Операция с сервером'}}
    if($Request.progress){& $Request.progress ([pscustomobject]@{stage=$Stage;message=$Message;doneBytes=$Done;totalBytes=$Total;doneFiles=-1;totalFiles=-1}) | Out-Null}
}
$file=$null;$process=$null;$cancel=$null;$started=$false
try {
    $action=[string]$Request.action
    if($action -notin @('exec','upload','download')){throw 'Неподдерживаемая операция передачи проекта.'}
    $command=[string]$Request.command
    if($action -ne 'exec'){
        $scope=[IO.Path]::GetFullPath((ConvertFrom-RemoteAgentsIOPath $DataDir)).TrimEnd('\')+'\'
        $path=[IO.Path]::GetFullPath((ConvertFrom-RemoteAgentsIOPath ([string]$Request.localPath)))
        if(-not $path.StartsWith($scope,[StringComparison]::OrdinalIgnoreCase)){throw 'Файл передачи находится вне данных проекта.'}
        $name=[IO.Path]::GetFileName($path)
        if($name -notmatch '\A(server-sync\.py|server-sync-runtime\.py|server-install-sync\.sh|seed\.zip|seed-manifest\.json|snapshot-[a-f0-9]{32}\.json)\z'){throw 'Этот файл не разрешён для передачи проекта.'}
        $remote=[string]$Request.remotePath
        if($remote -notmatch '\A/home/remoteagents/\.local/share/remote-agents-sync/[a-z0-9][a-z0-9_-]{0,63}/[a-z0-9][a-z0-9_-]{0,63}/(server-sync\.py|server-sync-runtime\.py|server-install-sync\.sh|seed\.zip|seed-manifest\.json|snapshot-[a-f0-9]{32}\.json)\z'){throw 'Неверный серверный путь передачи проекта.'}
        if($action -eq 'upload'){
            $command='umask 077; cat > '+(Quote-Shell $remote);$file=[IO.File]::OpenRead((ConvertTo-RemoteAgentsIOPath $path))
            if($name -eq 'seed.zip' -and $Request.resume){
                $checksum=[string]$Request.sha256
                if($checksum -cnotmatch '\A[a-f0-9]{64}\z'){throw 'Не задана проверенная контрольная сумма архива.'}
                $part=$remote+'.part-'+$checksum
                $probe=@'
# REMOTEAGENTS_SEED_PROBE
set -eu
part=@PART@; target=@TARGET@; expected=@HASH@
test ! -L "$part" && test ! -L "$target"
if test -f "$target"; then
    hash=$(sha256sum -- "$target")
    if test "${hash%% *}" = "$expected"; then printf 'complete'; exit 0; fi
fi
if test -e "$part"; then test -f "$part"; wc -c < "$part"; else printf '0'; fi
'@
                $probe=$probe.Replace('@PART@',(Quote-Shell $part)).Replace('@TARGET@',(Quote-Shell $remote)).Replace('@HASH@',(Quote-Shell $checksum))
                Send-TransferProgress -Stage 'upload-check' -Message 'Проверяем возможность продолжить отправку архива'
                $check=& $PSCommandPath -Request @{action='exec';command=$probe;timeoutSec=43200;idleTimeoutSec=300;longRunning=$true;stage='upload-check';message='Проверяем уже отправленный архив';progress=$Request.progress} -Connection $Connection -DataDir $DataDir
                if($check.exitCode -ne 0){
                    $detail=if($check.stderr -match 'syntax error|invalid option'){'Ошибка серверного скрипта Bash.'}elseif($check.exitCode -eq 255){'Ошибка SSH-соединения.'}else{'Сервер отклонил проверку состояния передачи.'}
                    throw ('Не удалось проверить незавершённую отправку архива: код '+$check.exitCode+'. '+$detail+' Подготовленный локальный архив сохранён.')
                }
                if($check.stdout.Trim() -eq 'complete'){
                    Send-TransferProgress $file.Length $file.Length -Stage 'upload' -Message 'Архив уже получен сервером и проверен'
                    return [pscustomobject]@{exitCode=0;stdout='';stderr='';resumedBytes=$file.Length;transferredBytes=0}
                }
                $offset=0L
                if(![long]::TryParse($check.stdout.Trim(),[ref]$offset) -or $offset -lt 0 -or $offset -gt $file.Length){throw 'Неверный размер незавершённой отправки; существующие данные сохранены.'}
                [void]$file.Seek($offset,[IO.SeekOrigin]::Begin)
                $command=@'
# REMOTEAGENTS_SEED_UPLOAD
set -eu
umask 077
part=@PART@; target=@TARGET@; expected=@HASH@; offset=@OFFSET@; length=@LENGTH@; rejected=@REJECTED@
test ! -L "$part" && test ! -L "$target" && test ! -L "$part.lock"
exec 9> "$part.lock"
flock -n 9
if test -e "$part"; then test -f "$part"; else test "$offset" = 0; : > "$part"; fi
test "$(wc -c < "$part")" -eq "$offset"
cat >> "$part"
test "$(wc -c < "$part")" -eq "$length"
hash=$(sha256sum -- "$part")
if test "${hash%% *}" != "$expected"; then mv -nT -- "$part" "$rejected"; exit 65; fi
mv -fT -- "$part" "$target"
'@
                $command=$command.Replace('@PART@',(Quote-Shell $part)).Replace('@TARGET@',(Quote-Shell $remote)).Replace('@HASH@',(Quote-Shell $checksum)).Replace('@OFFSET@',[string]$offset).Replace('@LENGTH@',[string]$file.Length).Replace('@REJECTED@',(Quote-Shell ($part+'.rejected-'+[guid]::NewGuid().ToString('N'))))
            }
        }
        else{
            if($name -notmatch '\Asnapshot-[a-f0-9]{32}\.json\z'){throw 'Разрешено получать только снимок состояния проекта.'}
            $command='cat -- '+(Quote-Shell $remote)
            $file=[IO.File]::Open((ConvertTo-RemoteAgentsIOPath $path),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
        }
    }
    if(-not $command){throw 'Не задана операция с проектом.'}
    if($Request.longRunning){
        $command="(while sleep 5 >/dev/null 2>&1; do printf 'REMOTEAGENTS_PROJECT_HEARTBEAT\n' >&2; done) >/dev/null &`nra_heartbeat=`$!`ntrap 'kill `"`$ra_heartbeat`" 2>/dev/null || true' EXIT`n"+$command
    }
    # PS5.1 here-strings retain CRLF from Windows source files. Bash must receive
    # LF-only script text (including nested probe/upload scripts and heartbeat).
    # This conversion never touches the binary stdin stream of an upload.
    $command=$command.Replace("`r`n","`n").Replace("`r","`n")
    # All home/workspace operations run as the managed ordinary Linux user.
    $quoted=Quote-Shell $command
    $remoteCommand='if [ "$(id -u)" -eq 0 ]; then exec runuser -u remoteagents -- env HOME=/home/remoteagents bash -c '+$quoted+'; elif [ "$(id -un)" = remoteagents ]; then exec env HOME=/home/remoteagents bash -c '+$quoted+'; else exec sudo -n -u remoteagents -- env HOME=/home/remoteagents bash -c '+$quoted+'; fi'
    $eventName='Local\RemoteAgents.Askpass.'+[guid]::NewGuid().ToString('N')
    $acl=New-Object Security.AccessControl.EventWaitHandleSecurity
    $acl.SetAccessRuleProtection($true,$false)
    $acl.AddAccessRule((New-Object Security.AccessControl.EventWaitHandleAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().User,'FullControl','Allow')))
    $created=$false
    $cancel=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$eventName,[ref]$created,$acl)
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=[string]$Connection.sshExecutable
    $info.Arguments=(@(@($Connection.arguments)+@($remoteCommand)|ForEach-Object{Quote-Native ([string]$_)}) -join ' ')
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
    $info.EnvironmentVariables['SSH_ASKPASS']=[string]$Connection.askpassExecutable
    $info.EnvironmentVariables['SSH_ASKPASS_REQUIRE']='force'
    $info.EnvironmentVariables['REMOTE_AGENTS_ASKPASS_CANCEL']=$eventName
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    [void]$process.Start()
    $started=$true;$processHandle=$process.Handle
    $resumeOffset=if($file){$file.Position}else{0L}
    $errorTask=$process.StandardError.ReadLineAsync();$errorComplete=$false;$errorText=New-Object Text.StringBuilder
    $outputTask=if($action -eq 'download'){$process.StandardOutput.BaseStream.CopyToAsync($file)}else{$process.StandardOutput.ReadToEndAsync()}
    $inputTask=$null
    if($action -eq 'upload'){$inputTask=$file.CopyToAsync($process.StandardInput.BaseStream)}
    else{$process.StandardInput.Close()}
    $timeout=if($Request.timeoutSec){[Math]::Min(43200,[Math]::Max(1,[int]$Request.timeoutSec))}else{30}
    $idleTimeout=if($Request.idleTimeoutSec){[Math]::Max(1,[int]$Request.idleTimeoutSec)}else{[Math]::Min(300,$timeout)}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $lastActivity=0.0;$lastReport=-1.0;$lastPosition=$resumeOffset
    $inputClosed=($action -ne 'upload')
    while($true){
        $exited=$process.WaitForExit(50)
        if($cancel.WaitOne(0)){throw 'Ввод отменён. Сохранённые проекты не удалены.'}
        if($clock.Elapsed.TotalSeconds -gt $timeout){throw ('Достигнут общий лимит этапа «'+$Request.stage+'»: '+$timeout+' с. Повторите пункт 13; подготовленный архив и частичная отправка сохранены.')}
        while(!$errorComplete -and $errorTask.IsCompleted){
            $line=$errorTask.GetAwaiter().GetResult()
            if($null -eq $line){$errorComplete=$true;break}
            if($line -eq 'REMOTEAGENTS_PROJECT_HEARTBEAT'){if($action -ne 'upload' -or $inputClosed){$lastActivity=$clock.Elapsed.TotalSeconds}}
            elseif($line.StartsWith('REMOTEAGENTS_PROJECT_PROGRESS=')){
                try{$update=$line.Substring(30)|ConvertFrom-Json -ErrorAction Stop}catch{$update=$null}
                if($update){if($Request.progress){& $Request.progress $update | Out-Null};$lastActivity=$clock.Elapsed.TotalSeconds}
            }else{
                [void]$errorText.AppendLine($line);if($errorText.Length -gt 8192){[void]$errorText.Remove(0,$errorText.Length-8192)}
            }
            $errorTask=$process.StandardError.ReadLineAsync()
        }
        if($file -and $file.Position -ne $lastPosition){$lastActivity=$clock.Elapsed.TotalSeconds;$lastPosition=$file.Position}
        if($clock.Elapsed.TotalSeconds-$lastReport -ge 1){
            if($action -eq 'upload'){
                # Completion is reported only after SSH exits successfully (including server SHA256).
                $reported=[Math]::Min($file.Position,[Math]::Max(0,$file.Length-1))
                Send-TransferProgress $reported $file.Length
            }elseif($action -eq 'download'){Send-TransferProgress -Done $file.Position}else{Send-TransferProgress}
            $lastReport=$clock.Elapsed.TotalSeconds
        }
        if($clock.Elapsed.TotalSeconds-$lastActivity -gt $idleTimeout){throw ('Нет активности на этапе «'+$Request.stage+'» '+$idleTimeout+' с. Повторите пункт 13; подготовленный архив и частичная отправка сохранены.')}
        if(-not $inputClosed -and $inputTask.IsCompleted){
            $inputTask.GetAwaiter().GetResult() | Out-Null
            $process.StandardInput.BaseStream.Flush();$process.StandardInput.Close();$inputClosed=$true
        }
        if($exited){break}
    }
    if($inputTask){$inputTask.GetAwaiter().GetResult() | Out-Null}
    $outputTask.GetAwaiter().GetResult() | Out-Null
    # Drain remaining bounded error lines, separating private stderr from status.
    while(!$errorComplete){
        $line=$errorTask.GetAwaiter().GetResult();if($null -eq $line){break}
        if(!$line.StartsWith('REMOTEAGENTS_PROJECT_')){[void]$errorText.AppendLine($line);if($errorText.Length -gt 8192){[void]$errorText.Remove(0,$errorText.Length-8192)}}
        $errorTask=$process.StandardError.ReadLineAsync()
    }
    $stderr=$errorText.ToString()
    $stdout=if($action -eq 'download'){''}else{$outputTask.Result}
    if($action -eq 'upload' -and $process.ExitCode -eq 0){Send-TransferProgress $file.Length $file.Length}
    [pscustomobject]@{exitCode=$process.ExitCode;stdout=$stdout;stderr=$stderr;resumedBytes=$resumeOffset;transferredBytes=($lastPosition-$resumeOffset)}
} catch {
    if($action -eq 'upload' -and $Request.resume -and $inputTask -and $inputTask.IsFaulted){throw 'Чтение или отправка архива прервались. Подготовленный архив и полученная сервером часть сохранены; повторите пункт 13 для продолжения.'}
    throw
} finally {
    if($process){if($started -and -not $process.HasExited){$process.Kill();$process.WaitForExit()};$process.Dispose()}
    if($file){$file.Dispose()}
    if($cancel){$cancel.Dispose()}
}
