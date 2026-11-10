[CmdletBinding()]
param([string]$Profile,[string]$AgentUser,[switch]$LibraryOnly,[switch]$Install,[switch]$Uninstall,[string]$LauncherHome,[switch]$KeepState)
$ErrorActionPreference='Stop'
function Convert-ControlLF([string]$Text) { $Text.Replace("`r`n","`n").Replace("`r","`n") }
function Quote-ControlNative([string]$Text) { '"'+([regex]::Replace([regex]::Replace($Text,'(\\*)"','$1$1\"'),'(\\+)$','$1$1'))+'"' }
function Read-ControlProfile([string]$Path) {
    if(-not $Path) {
        $files=@(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'RemoteAgents/ssh-profiles/*/project-connections/*/ssh-transport.json') -File -ErrorAction SilentlyContinue)
        if($files.Count -eq 0){throw 'SSH-профиль не найден. Укажите -Profile с путём к ssh-transport.json.'}
        if($files.Count -eq 1){$Path=$files[0].FullName} else {
            for($i=0;$i -lt $files.Count;$i++){Write-Host (('{0}. {1}' -f ($i+1),$files[$i].FullName))}
            $choice=0
            if(-not [int]::TryParse((Read-Host 'Номер профиля'),[ref]$choice) -or $choice -lt 1 -or $choice -gt $files.Count){throw 'Неверный номер профиля'}
            $Path=$files[$choice-1].FullName
        }
    }
    $source=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $result=@{hostId=(Split-Path (Split-Path ([IO.Path]::GetFullPath($Path)) -Parent) -Leaf);port=22;profilePath=[IO.Path]::GetFullPath($Path)}
    foreach($field in @('sshExecutable','serverAddress','login','keyPath','knownHostsPath','configPath')) {
        if(-not $source.PSObject.Properties[$field] -or -not $source.$field){throw "В профиле отсутствует $field"}
        $result[$field]=[string]$source.$field
    }
    $arguments=@($source.arguments)
    for($i=0;$i -lt $arguments.Count;$i++) {if($arguments[$i] -ceq '-p') {if($i+1 -ge $arguments.Count){throw 'Нет порта после -p'};$result.port=[int]$arguments[++$i]}}
    if($result.port -lt 1 -or $result.port -gt 65535){throw 'Недопустимый SSH-порт'}
    if($result.hostId -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$'){throw 'Недопустимый hostId профиля'}
    # Managed launcher route must also override the legacy explicit -p argument.
    $sshText='';if($result.configPath -and (Test-Path -LiteralPath $result.configPath)){$sshText=[IO.File]::ReadAllText($result.configPath)}
    $managed=[regex]::Match($sshText,'(?ms)^# BEGIN RemoteAgents transport [^\r\n]+\r?\n(.*?)^# END RemoteAgents transport [^\r\n]+')
    if($managed.Success -and $managed.Groups[1].Value -match ('(?m)^Host "'+[regex]::Escape($result.serverAddress)+'"\r?$') -and $managed.Groups[1].Value -match '(?m)^    Port (\d+)\r?$'){$result.port=[int]$Matches[1]}
    [pscustomobject]$result
}
function Get-ControlLabel([string]$HostId) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try {'win-'+([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('control/'+$HostId)))).Replace('-','').ToLowerInvariant().Substring(0,28)} finally {$sha.Dispose()}
}
function Get-ControlSshArguments($Connection) {
    @('-F',$Connection.configPath,'-i',$Connection.keyPath,'-p',[string]$Connection.port,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile="'+$Connection.knownHostsPath.Replace('\','/')+'"'),'-T',($Connection.login+'@'+$Connection.serverAddress),'bash -s')
}
function New-ControlPayload($Connection,[string]$Label,[string]$Workspace,[string]$User) {
    $data=@{projectId='control';hostId=$Connection.hostId;deviceLabel=$Label;deviceName=$env:COMPUTERNAME;windowsReplica=$Workspace}|ConvertTo-Json -Compress
    $values=@{CONTROL_USER=$User;CONTROL_DATA=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($data))}
    foreach($pair in @(@('CONTROL_BRIDGE','codex-windows-bridge.py'),@('CONTROL_SESSION','codex-bridge-session.py'),@('CONTROL_CATALOG','server_node_catalog.py'))) {
        $values[$pair[0]]=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Convert-ControlLF ([IO.File]::ReadAllText((Join-Path $PSScriptRoot $pair[1]))))))
    }
    if($User -and $User -cnotmatch '^[a-z_][a-z0-9_-]*$'){throw 'Недопустимый -AgentUser'}
    $lines=@(foreach($key in $values.Keys){"$key='"+$values[$key]+"'"})
    Convert-ControlLF (($lines -join "`n")+"`n"+[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'server-control.sh'))+"`n")
}
function Invoke-ControlPrepare($Connection,[string]$Payload) {
    $si=New-Object Diagnostics.ProcessStartInfo
    $si.FileName=$Connection.sshExecutable
    $si.Arguments=((Get-ControlSshArguments $Connection | ForEach-Object {Quote-ControlNative ([string]$_)}) -join ' ')
    $si.UseShellExecute=$false;$si.CreateNoWindow=$true
    $si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    $p=New-Object Diagnostics.Process;$p.StartInfo=$si
    try {
        $deadline=[DateTime]::UtcNow.AddSeconds(60)
        [void]$p.Start();$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
        $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes((Convert-ControlLF $Payload))
        $write=$p.StandardInput.BaseStream.WriteAsync($bytes,0,$bytes.Length)
        if(-not $write.Wait(60000)){$p.Kill();throw 'Таймаут передачи серверу (60 с)'}
        $p.StandardInput.BaseStream.Flush()
        $p.StandardInput.Close()
        if(-not $p.WaitForExit([Math]::Max(1,[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds))){$p.Kill();throw 'Таймаут подготовки сервера (60 с)'}
        $stderr=Convert-ControlLF $err.Result
        if($stderr){Write-Host $stderr}
        if($p.ExitCode -ne 0){throw ('Подготовка сервера завершилась с ошибкой: '+$stderr)}
        $last=@((Convert-ControlLF $out.Result).Trim() -split "`n")[-1]
        $last | ConvertFrom-Json
    } finally {$p.Dispose()}
}
function Write-ControlLog([string]$Path,[string]$Message) {
    try {
        if((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -gt 1048576){Move-Item -LiteralPath $Path -Destination ($Path+'.old') -Force}
        [IO.File]::AppendAllText($Path,((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+' '+$Message+"`r`n"))
    } catch {}
}
function Read-ControlConfig([string]$Path) {
    if(Test-Path -LiteralPath $Path){Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}else{[pscustomobject]@{agentUser='';profile=''}}
}
function Save-ControlConfig([string]$Path,[string]$User,[string]$ProfilePath) {
    @{schema=1;agentUser=$User;profile=$ProfilePath}|ConvertTo-Json|Set-Content -LiteralPath $Path -Encoding UTF8
}
function Test-ControlLock($Lock) {
    try {$Lock.WaitOne(0)} catch [Threading.AbandonedMutexException] {$true}
}
function Stop-ControlInstance([string]$PidFile,[switch]$KeepPid) {
    if(-not (Test-Path -LiteralPath $PidFile)){return}
    $id=0
    if([int]::TryParse((Get-Content -LiteralPath $PidFile -Raw).Trim(),[ref]$id)){
        $found=Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
        if($found -and [string]$found.CommandLine -match 'Start-WindowsControl\.ps1'){& taskkill.exe /T /F /PID $id *> $null}
    }
    if(-not $KeepPid){Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue}
}
if($LibraryOnly){return}
$base=Join-Path $env:LOCALAPPDATA 'RemoteAgents/control'
$originalBase=$base
$workspace=Join-Path $base 'workspace'
if($LauncherHome){$base=Join-Path ([IO.Path]::GetFullPath($LauncherHome)) 'managed-control'}
$logs=Join-Path $base 'logs';$app=Join-Path $base 'app'
[void][IO.Directory]::CreateDirectory($workspace);[void][IO.Directory]::CreateDirectory($logs)
$logFile=Join-Path $logs 'control.log';$pidFile=Join-Path $base 'control.pid';$configPath=Join-Path $originalBase 'config.json'
$runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if($Uninstall){
    Remove-ItemProperty -Path $runKey -Name RemoteAgentsControl -ErrorAction SilentlyContinue
    Stop-ControlInstance $pidFile -KeepPid:$KeepState
    if(-not $KeepState){Write-ControlLog $logFile 'uninstall'}
    Write-Host 'Автозапуск снят, мост остановлен.'
    return
}
if($Install){
    $config=Read-ControlConfig $configPath
    if(-not $Profile){$Profile=$config.profile}
    if(-not $AgentUser){$AgentUser=$config.agentUser}
    $connection=Read-ControlProfile $Profile
    if(-not $LauncherHome){Save-ControlConfig $configPath $AgentUser $connection.profilePath}
    if(-not $LauncherHome){
    [void][IO.Directory]::CreateDirectory($app)
    foreach($name in @('Start-WindowsControl.ps1','Start-CodexWindowsBridge.ps1','windows-bridge-executor.ps1','Windows.Paths.ps1','server-control.sh','codex-windows-bridge.py','codex-bridge-session.py','server_node_catalog.py')){
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $app $name) -Force
    }
    }
    Stop-ControlInstance $pidFile
    $command=(Quote-ControlNative (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'))+' -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $app 'Start-WindowsControl.ps1')+'"'
    if($LauncherHome){
        # A private added copy survives bundle pruning. The original control/app stays untouched.
        $contentHashes=@('Start-WindowsControl.ps1','Start-CodexWindowsBridge.ps1','windows-bridge-executor.ps1','Windows.Paths.ps1','server-control.sh','codex-windows-bridge.py','codex-bridge-session.py','server_node_catalog.py')|ForEach-Object {(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_) -Algorithm SHA256).Hash}
        $sha=[Security.Cryptography.SHA256]::Create();try{$version=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($contentHashes -join ''))))).Replace('-','').Substring(0,24)}finally{$sha.Dispose()}
        $managedApp=Join-Path $base ('app/'+$version);[void][IO.Directory]::CreateDirectory($managedApp)
        foreach($name in @('Start-WindowsControl.ps1','Start-CodexWindowsBridge.ps1','windows-bridge-executor.ps1','Windows.Paths.ps1','server-control.sh','codex-windows-bridge.py','codex-bridge-session.py','server_node_catalog.py')){
            $source=Join-Path $PSScriptRoot $name;$target=Join-Path $managedApp $name
            if(-not (Test-Path -LiteralPath $target) -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash){Copy-Item -LiteralPath $source -Destination $target -Force}
        }
        $command=(Quote-ControlNative (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'))+' -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File '+(Quote-ControlNative (Join-Path $managedApp 'Start-WindowsControl.ps1'))+' -LauncherHome '+(Quote-ControlNative $LauncherHome)
    }
    Set-ItemProperty -Path $runKey -Name RemoteAgentsControl -Value $command
    $mark=(Get-Date).AddSeconds(-1)
    $started=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command}
    if($started.ReturnValue -ne 0){throw ('Не удалось запустить мост: '+$started.ReturnValue)}
    Write-ControlLog $logFile 'install'
    Write-Host 'Мост установлен: работает без окна и запускается при входе в Windows.'
    Write-Host ('Журнал: '+$logFile)
    for($i=0;$i -lt 45;$i++){
        Start-Sleep -Seconds 1
        if((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).LastWriteTime -gt $mark -and ((Get-Content -LiteralPath $logFile -Tail 3) -join ' ') -match 'bridge\.connected'){Write-Host 'Связь с сервером есть.';return}
    }
    Write-Host 'Связь пока не установилась, мост продолжает попытки. Смотрите журнал.'
    return
}
$lock=New-Object Threading.Mutex($false,'Local\RemoteAgentsControl')
if(-not (Test-ControlLock $lock)){Write-ControlLog $logFile 'already running';return}
Set-Content -LiteralPath $pidFile -Value $PID -Encoding ASCII
Write-ControlLog $logFile ('start pid='+$PID)
while($true){
    try {
        $config=Read-ControlConfig $configPath
        $connection=Read-ControlProfile $(if($Profile){$Profile}else{$config.profile})
        $user=$(if($AgentUser){$AgentUser}else{$config.agentUser})
        $label=Get-ControlLabel $connection.hostId
        Write-ControlLog $logFile 'prepare server'
        $remote=Invoke-ControlPrepare $connection (New-ControlPayload $connection $label $workspace $user)
        if($remote.user -cnotmatch '^[a-z_][a-z0-9_-]*$' -or $remote.home -cnotmatch '^(/[a-zA-Z0-9._-]+)+$'){throw 'Сервер вернул неверного пользователя или HOME'}
        if(-not $LauncherHome){Save-ControlConfig $configPath $remote.user $connection.profilePath}
        Write-Host 'Подключение моста: команды агентов выполняются с вашими правами Windows.'
        & (Join-Path $PSScriptRoot 'Start-CodexWindowsBridge.ps1') -VPSHost $connection.serverAddress -VPSUser $connection.login -IdentityFile $connection.keyPath -SSHPort $connection.port -SSHExecutable $connection.sshExecutable -SSHConfig $connection.configPath -KnownHostsFile $connection.knownHostsPath -ServerUser $remote.user -RemoteBase ($remote.home+'/.local/share/codex-remote') -SocketPath ($remote.home+'/.local/state/codex-remote/'+$label+'.sock') -Workspace $workspace -DeviceLabel $label -ProjectId control -HostId $connection.hostId -AllowShell -ControlOnly -RetryForever -LogFile $logFile
        Write-ControlLog $logFile 'bridge returned'
    } catch {
        Write-Host ('Ошибка: '+$_.Exception.Message)
        Write-ControlLog $logFile ('error '+$_.Exception.Message)
    }
    Start-Sleep -Seconds 15
}
