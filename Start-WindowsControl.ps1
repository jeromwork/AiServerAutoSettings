[CmdletBinding()]
param([string]$Profile,[string]$AgentUser,[switch]$LibraryOnly)
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
    $source=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $result=@{hostId=(Split-Path (Split-Path ([IO.Path]::GetFullPath($Path)) -Parent) -Leaf);port=22}
    foreach($field in @('sshExecutable','serverAddress','login','keyPath','knownHostsPath','configPath')) {
        if(-not $source.PSObject.Properties[$field] -or -not $source.$field){throw "В профиле отсутствует $field"}
        $result[$field]=[string]$source.$field
    }
    $arguments=@($source.arguments)
    for($i=0;$i -lt $arguments.Count;$i++) {if($arguments[$i] -ceq '-p') {if($i+1 -ge $arguments.Count){throw 'Нет порта после -p'};$result.port=[int]$arguments[++$i]}}
    if($result.port -lt 1 -or $result.port -gt 65535){throw 'Недопустимый SSH-порт'}
    if($result.hostId -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$'){throw 'Недопустимый hostId профиля'}
    [pscustomobject]$result
}
function Get-ControlLabel([string]$HostId) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try {'win-'+([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('control/'+$HostId)))).Replace('-','').ToLowerInvariant().Substring(0,28)} finally {$sha.Dispose()}
}
function Get-ControlSshArguments($Connection) {
    @('-F',$Connection.configPath,'-i',$Connection.keyPath,'-p',[string]$Connection.port,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o',('UserKnownHostsFile='+$Connection.knownHostsPath),'-T',($Connection.login+'@'+$Connection.serverAddress),'bash -s')
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
    $si.StandardInputEncoding=New-Object Text.UTF8Encoding($false)
    $p=New-Object Diagnostics.Process;$p.StartInfo=$si
    try {
        $deadline=[DateTime]::UtcNow.AddSeconds(60)
        [void]$p.Start();$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
        $write=$p.StandardInput.WriteAsync((Convert-ControlLF $Payload))
        if(-not $write.Wait(60000)){$p.Kill();throw 'Таймаут передачи серверу (60 с)'}
        $p.StandardInput.Close()
        if(-not $p.WaitForExit([Math]::Max(1,[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds))){$p.Kill();throw 'Таймаут подготовки сервера (60 с)'}
        $stderr=Convert-ControlLF $err.Result
        if($stderr){Write-Host $stderr}
        if($p.ExitCode -ne 0){throw ('Подготовка сервера завершилась с ошибкой: '+$stderr)}
        $last=@((Convert-ControlLF $out.Result).Trim() -split "`n")[-1]
        $last | ConvertFrom-Json
    } finally {$p.Dispose()}
}
if($LibraryOnly){return}
$transcript=$false
try {
    $base=Join-Path $env:LOCALAPPDATA 'RemoteAgents/control'
    $workspace=Join-Path $base 'workspace';$logs=Join-Path $base 'logs'
    [void][IO.Directory]::CreateDirectory($workspace);[void][IO.Directory]::CreateDirectory($logs)
    Start-Transcript -Path (Join-Path $logs ('control-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.log')) | Out-Null;$transcript=$true
    Write-Host 'Чтение SSH-профиля'
    $connection=Read-ControlProfile $Profile
    Write-Host ('Профиль: '+$connection.hostId)
    $configPath=Join-Path $base 'config.json'
    if(-not $AgentUser -and (Test-Path -LiteralPath $configPath)){$AgentUser=(Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json).agentUser}
    $label=Get-ControlLabel $connection.hostId
    Write-Host 'Подготовка сервера'
    $remote=Invoke-ControlPrepare $connection (New-ControlPayload $connection $label $workspace $AgentUser)
    if($remote.user -cnotmatch '^[a-z_][a-z0-9_-]*$' -or $remote.home -cnotmatch '^(/[a-zA-Z0-9._-]+)+$'){throw 'Сервер вернул неверного пользователя или HOME'}
    @{schema=1;agentUser=$remote.user}|ConvertTo-Json|Set-Content -LiteralPath $configPath -Encoding UTF8
    Write-Host 'Подключение моста: команды агентов выполняются с вашими правами Windows, Ctrl+C отключает.'
    & (Join-Path $PSScriptRoot 'Start-CodexWindowsBridge.ps1') -VPSHost $connection.serverAddress -VPSUser $connection.login -IdentityFile $connection.keyPath -SSHPort $connection.port -SSHExecutable $connection.sshExecutable -SSHConfig $connection.configPath -KnownHostsFile $connection.knownHostsPath -ServerUser $remote.user -RemoteBase ($remote.home+'/.local/share/codex-remote') -SocketPath ($remote.home+'/.local/state/codex-remote/'+$label+'.sock') -Workspace $workspace -DeviceLabel $label -ProjectId control -HostId $connection.hostId -AllowShell -ControlOnly
} catch {Write-Host ('Ошибка: '+$_.Exception.Message);throw} finally {if($transcript){Stop-Transcript|Out-Null}}
