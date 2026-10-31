[CmdletBinding()]
param([Parameter(Mandatory=$true)]$Request,[Parameter(Mandatory=$true)]$Connection,[Parameter(Mandatory=$true)][string]$DataDir)
$ErrorActionPreference='Stop'
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
$file=$null;$process=$null;$cancel=$null;$started=$false
try {
    $action=[string]$Request.action
    if($action -notin @('exec','upload','download')){throw 'Неподдерживаемая операция передачи проекта.'}
    $command=[string]$Request.command
    if($action -ne 'exec'){
        $scope=[IO.Path]::GetFullPath($DataDir).TrimEnd('\')+'\'
        $path=[IO.Path]::GetFullPath([string]$Request.localPath)
        if(-not $path.StartsWith($scope,[StringComparison]::OrdinalIgnoreCase)){throw 'Файл передачи находится вне данных проекта.'}
        $name=[IO.Path]::GetFileName($path)
        if($name -notmatch '\A(server-sync\.py|server-sync-runtime\.py|server-install-sync\.sh|seed\.zip|seed-manifest\.json|snapshot-[a-f0-9]{32}\.json)\z'){throw 'Этот файл не разрешён для передачи проекта.'}
        $remote=[string]$Request.remotePath
        if($remote -notmatch '\A/home/remoteagents/\.local/share/remote-agents-sync/[a-z0-9][a-z0-9_-]{0,63}/[a-z0-9][a-z0-9_-]{0,63}/(server-sync\.py|server-sync-runtime\.py|server-install-sync\.sh|seed\.zip|seed-manifest\.json|snapshot-[a-f0-9]{32}\.json)\z'){throw 'Неверный серверный путь передачи проекта.'}
        if($action -eq 'upload'){$command='umask 077; cat > '+(Quote-Shell $remote);$file=[IO.File]::OpenRead($path)}
        else{
            if($name -notmatch '\Asnapshot-[a-f0-9]{32}\.json\z'){throw 'Разрешено получать только снимок состояния проекта.'}
            $command='cat -- '+(Quote-Shell $remote)
            $file=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
        }
    }
    if(-not $command){throw 'Не задана операция с проектом.'}
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
    $started=$true
    $errorTask=$process.StandardError.ReadToEndAsync()
    $outputTask=if($action -eq 'download'){$process.StandardOutput.BaseStream.CopyToAsync($file)}else{$process.StandardOutput.ReadToEndAsync()}
    $inputTask=$null
    if($action -eq 'upload'){$inputTask=$file.CopyToAsync($process.StandardInput.BaseStream)}
    else{$process.StandardInput.Close()}
    $timeout=if($Request.timeoutSec){[Math]::Min(1800,[Math]::Max(1,[int]$Request.timeoutSec))}else{30}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $inputClosed=($action -ne 'upload')
    while(-not $process.WaitForExit(50)){
        if($cancel.WaitOne(0)){throw 'Ввод отменён. Сохранённые проекты не удалены.'}
        if($clock.Elapsed.TotalSeconds -gt $timeout){throw 'Операция с проектом заняла слишком много времени. Повторите подключение.'}
        if(-not $inputClosed -and $inputTask.IsCompleted){
            $inputTask.GetAwaiter().GetResult() | Out-Null
            $process.StandardInput.BaseStream.Flush();$process.StandardInput.Close();$inputClosed=$true
        }
    }
    if($inputTask){$inputTask.GetAwaiter().GetResult() | Out-Null}
    $outputTask.GetAwaiter().GetResult() | Out-Null
    $stderr=$errorTask.GetAwaiter().GetResult()
    if($stderr.Length -gt 8192){$stderr=$stderr.Substring($stderr.Length-8192)}
    $stdout=if($action -eq 'download'){''}else{$outputTask.Result}
    [pscustomobject]@{exitCode=$process.ExitCode;stdout=$stdout;stderr=$stderr}
} finally {
    if($process){if($started -and -not $process.HasExited){$process.Kill();$process.WaitForExit()};$process.Dispose()}
    if($file){$file.Dispose()}
    if($cancel){$cancel.Dispose()}
}
