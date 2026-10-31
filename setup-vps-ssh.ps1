[CmdletBinding()]
param([string]$ServerAddress, [string]$Login, [string]$ProfileName, [string]$DataDir, [switch]$Launcher)
$ErrorActionPreference = 'Stop'
function Protect-NewDirectory([string]$Path) {
    # Called only for directories newly created by this script.
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = New-Object Security.AccessControl.DirectorySecurity
    # Keep the existing owner of this newly created directory; only its DACL changes.
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    # Use .NET directly: loading Microsoft.PowerShell.Security is not required.
    if ($PSVersionTable.PSVersion.Major -le 5) {
        [IO.Directory]::SetAccessControl($Path, $acl)
    } else {
        [IO.FileSystemAclExtensions]::SetAccessControl((New-Object IO.DirectoryInfo($Path)), $acl)
    }
}
function Convert-SshArgument([string]$Value) {
    # Encode Windows argv explicitly; PowerShell 5.1 otherwise loses nested quotes.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}
function Initialize-PasswordWindow {
    if ($script:askpassExecutable) { return }
    if ($PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::UserInteractive) {
        throw 'Для окна пароля запустите 01-setup-ssh.cmd в обычной Windows с рабочим столом (Windows PowerShell 5.1).'
    }
    $clientVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($script:sshExecutable).ProductVersion
    if ($clientVersion -notmatch '(\d+)\.(\d+)' -or [version]($Matches[1] + '.' + $Matches[2]) -lt [version]'8.6') {
        throw 'Для окна пароля нужен Windows OpenSSH Client 8.6 или новее. Обновите клиент; скрытый ввод в консоли автоматически включаться не будет.'
    }
    $uiSource = Join-Path $PSScriptRoot 'ssh-password-ui.cs'
    if (-not (Test-Path -LiteralPath $uiSource -PathType Leaf)) { throw 'Рядом с программой не хватает ssh-password-ui.cs. Скопируйте весь комплект и повторите запуск.' }
    $sourceBytes = [IO.File]::ReadAllBytes($uiSource)
    $digest = [Security.Cryptography.SHA256]::Create()
    try { $sourceId = [BitConverter]::ToString($digest.ComputeHash($sourceBytes)).Replace('-', '').ToLowerInvariant() }
    finally { $digest.Dispose() }
    $uiDirectory = Join-Path $profileDirectory 'password-window'
    if (-not (Test-Path -LiteralPath $uiDirectory)) {
        [IO.Directory]::CreateDirectory($uiDirectory) | Out-Null
        Protect-NewDirectory $uiDirectory
    }
    $uiPath = Join-Path $uiDirectory ('askpass-' + $sourceId + '.exe')
    if (-not (Test-Path -LiteralPath $uiPath -PathType Leaf)) {
        try { Add-Type -TypeDefinition ([Text.Encoding]::UTF8.GetString($sourceBytes).TrimStart([char]0xFEFF)) -ReferencedAssemblies System.Windows.Forms,System.Drawing -OutputAssembly $uiPath -OutputType WindowsApplication -ErrorAction Stop }
        catch { throw 'Не удалось подготовить окно пароля средствами Windows. Проверьте наличие .NET Framework и разрешение запуска локальных программ; данные подключения сохранены.' }
    }
    $script:askpassExecutable = $uiPath
}
function Test-WindowsRuntime {
    $missing = @()
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion -lt [version]'5.1') {
        $missing += 'Windows PowerShell 5.1: запускайте 01-setup-ssh.cmd в Windows 10/11.'
    }
    if (-not [Environment]::UserInteractive) { $missing += 'Обычный рабочий стол Windows для окон ввода пароля.' }
    try { Add-Type -AssemblyName System.Windows.Forms,System.Drawing -ErrorAction Stop }
    catch { $missing += '.NET Framework с Windows Forms: восстановите компоненты Windows/.NET.' }
    foreach ($program in @('ssh.exe','ssh-keygen.exe')) {
        $found = @(Get-Command $program -CommandType Application -ErrorAction SilentlyContinue)
        if (-not $found.Count) { $missing += ('OpenSSH Client: не найден ' + $program + '. Добавьте «Клиент OpenSSH» в дополнительных компонентах Windows.') }
    }
    if ($missing.Count) {
        throw ("Сначала подготовьте Windows:`n- " + ($missing -join "`n- ") + "`nУстановка компонентов может потребовать прав администратора. Python на Windows не нужен.")
    }
    $script:sshExecutable = @(Get-Command ssh.exe -CommandType Application)[0].Source
    $script:keygenExecutable = @(Get-Command ssh-keygen.exe -CommandType Application)[0].Source
    $clientVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($script:sshExecutable).ProductVersion
    if ($clientVersion -notmatch '(\d+)\.(\d+)' -or [version]($Matches[1] + '.' + $Matches[2]) -lt [version]'8.6') {
        throw 'Сначала обновите Клиент OpenSSH до версии 8.6 или новее: он нужен для безопасного окна пароля. Это клиент, служба SSH-сервера Windows не требуется.'
    }
}
function Invoke-ProfileSsh([string[]]$Arguments, [string]$PublicKey, [string]$InputText) {
    Initialize-PasswordWindow
    $eventName = 'Local\RemoteAgents.Askpass.' + [guid]::NewGuid().ToString('N')
    $eventSecurity = New-Object Security.AccessControl.EventWaitHandleSecurity
    $eventSecurity.SetAccessRuleProtection($true, $false)
    $eventSecurity.AddAccessRule((New-Object Security.AccessControl.EventWaitHandleAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'Allow')))
    $created = $false
    $cancelled = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $eventName, [ref]$created, $eventSecurity)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $script:sshExecutable
    $start.Arguments = (@($Arguments | ForEach-Object { Convert-SshArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.EnvironmentVariables['SSH_ASKPASS'] = $script:askpassExecutable
    $start.EnvironmentVariables['SSH_ASKPASS_REQUIRE'] = 'force'
    $start.EnvironmentVariables['REMOTE_AGENTS_ASKPASS_CANCEL'] = $eventName
    # Only public setup source/data goes to SSH stdin. Passwords remain in askpass/OpenSSH.
    if ($PublicKey -and $InputText) { throw 'Нельзя одновременно передать два источника настройки.' }
    $payload = if ($InputText) { $InputText } else { $PublicKey }
    $start.RedirectStandardInput = [bool]$payload
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        if ($payload) {
            # .NET Framework / Windows PowerShell 5.1 has no StandardInputEncoding.
            # Write bytes directly: no BOM, no StreamWriter encoding or CRLF conversion.
            $payloadBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($payload.Replace("`r`n", "`n").TrimStart([char]0xFEFF) + "`n")
            $process.StandardInput.BaseStream.Write($payloadBytes, 0, $payloadBytes.Length)
            $process.StandardInput.BaseStream.Flush()
            $process.StandardInput.Close()
        }
        while (-not $process.WaitForExit(100)) {
            if ($cancelled.WaitOne(0)) { if (-not $process.HasExited) { $process.Kill() }; $process.WaitForExit(); throw 'Ввод отменён. Данные подключения сохранены.' }
        }
        if ($cancelled.WaitOne(0)) { throw 'Ввод отменён или вопрос подключения не поддерживается. Данные сохранены.' }
        return $process.ExitCode
    } finally { $process.Dispose(); $cancelled.Dispose() }
}
function Save-ProfileMetadata($Value, [string]$Path) {
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}
function Get-KeyDirectory([string]$Slot) {
    if (-not $Slot -or $Slot -ceq 'legacy') { return $profileDirectory }
    if ($Slot -notmatch '\Akey-[a-f0-9]{32}\z') { throw 'Нужна помощь с сохранённым подключением: неверное имя комплекта.' }
    return Join-Path (Join-Path $profileDirectory 'keysets') $Slot
}
function Test-SavedConnection([string]$PrivatePath) {
    $arguments = $common + @('-i', $PrivatePath, '-o', 'IdentitiesOnly=yes', '-o', 'PubkeyAuthentication=yes', '-o', 'PreferredAuthentications=publickey', '-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no', $ServerAddress, 'set -eu; id; cat /etc/os-release; uname -m')
    return (Invoke-ProfileSsh -Arguments $arguments)
}
function Confirm-Action([string]$Question, [switch]$DefaultNo) {
    $hint = if ($DefaultNo) { ' Да/Нет; Enter — Нет' } else { ' Да/Нет; Enter — Да' }
    $answer = (Read-Host ($Question + $hint)).Trim().ToLowerInvariant()
    if (-not $answer) { return (-not $DefaultNo) }
    return ($answer -in @('да', 'д', 'y', 'yes'))
}
function Invoke-CodexSession([string]$Mode, [switch]$Terminal) {
    if ($Mode -notin @('status', 'auth-device', 'chat')) { throw 'Неизвестный режим запуска Codex.' }
    $command = 'if [ "$(id -u)" -eq 0 ]; then exec runuser -u remoteagents -- /usr/local/lib/remoteagents/codex-session ' + $Mode + '; else exec sudo -n -H -u remoteagents -- /usr/local/lib/remoteagents/codex-session ' + $Mode + '; fi'
    if ($Mode -eq 'chat') {
        $options = ' -c ''mcp_servers.windows-' + $deviceLabel + '.default_tools_approval_mode="prompt"'' -c ''mcp_servers.windows-' + $deviceLabel + '.tool_timeout_sec=80'''
        if ($executionMode -eq '2') { $options += ' -c ''mcp_servers.windows-' + $deviceLabel + '.enabled=false''' }
        if ($executionMode -eq '1') { $options += ' -c ''mcp_servers.windows-' + $deviceLabel + '.enabled=true''' }
        $command = $command.Replace('codex-session chat;', ('codex-session chat' + $options + ';'))
    }
    $terminalFlag = if ($Terminal) { '-tt' } else { '-T' }
    return (Invoke-ProfileSsh -Arguments ($codexSsh + @($terminalFlag, $ServerAddress, $command)))
}
function Stop-ManagedComponent($Component) {
    if (-not $Component) { return }
    try {
        if (-not $Component.Process.HasExited) {
            $Component.Process.StandardInput.WriteLine('stop')
            $Component.Process.StandardInput.Close()
            if (-not $Component.Process.WaitForExit(10000)) { $Component.Process.Kill(); $Component.Process.WaitForExit() }
        }
    } finally { $Component.Process.Dispose(); $Component.CancelEvent.Dispose() }
}
function Initialize-ManagedOutput {
    if ('RemoteAgents.BoundedStatusReader' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
namespace RemoteAgents {
    public sealed class BoundedStatusReader {
        readonly Queue<string> lines = new Queue<string>();
        readonly object gate = new object();
        bool complete;
        readonly string expected;
        string readyLine;
        public BoundedStatusReader(Process process, string readyState) { expected=readyState; process.OutputDataReceived += Receive; }
        void Receive(object sender, DataReceivedEventArgs args) {
            lock (gate) {
                if (args.Data == null) { complete = true; return; }
                if (readyLine == null && (
                    (expected == "browser" && args.Data.StartsWith("REMOTEAGENTS_BROWSER_READY=http://127.0.0.1:")) ||
                    (expected == "desktop" && System.Text.RegularExpressions.Regex.IsMatch(args.Data, @"\AREMOTEAGENTS_DESKTOP_READY=127\.0\.0\.1:[0-9]+\z")) ||
                    System.Text.RegularExpressions.Regex.IsMatch(args.Data, @"""state""\s*:\s*""" + System.Text.RegularExpressions.Regex.Escape(expected) + @"""")))
                    readyLine=args.Data;
                while (lines.Count >= 8) lines.Dequeue();
                lines.Enqueue(args.Data.Length <= 4096 ? args.Data : args.Data.Substring(0, 4096));
            }
        }
        public string Take() { lock (gate) { return lines.Count == 0 ? null : lines.Dequeue(); } }
        public string ReadyLine { get { lock (gate) { return readyLine; } } }
        public bool Complete { get { lock (gate) { return complete; } } }
    }
}
"@
}
function Start-ManagedComponent([string]$File, [string[]]$Parameters, [string]$ReadyState) {
    $eventName = 'Local\RemoteAgents.Askpass.' + [guid]::NewGuid().ToString('N')
    $acl = New-Object Security.AccessControl.EventWaitHandleSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object Security.AccessControl.EventWaitHandleAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'Allow')))
    $created = $false
    $event = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $eventName, [ref]$created, $acl)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $PSHOME 'powershell.exe'
    $info.Arguments = (@(@('-NoProfile','-ExecutionPolicy','Bypass','-File',$File) + $Parameters | ForEach-Object { Convert-SshArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.EnvironmentVariables['REMOTE_AGENTS_ASKPASS_CANCEL'] = $eventName
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    Initialize-ManagedOutput
    $reader = New-Object RemoteAgents.BoundedStatusReader($process,$ReadyState)
    $component = [pscustomobject]@{ Process=$process; CancelEvent=$event; Output=$reader; State='starting' }
    try {
        [void]$process.Start()
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $process.BeginOutputReadLine()
        while ($clock.Elapsed.TotalMinutes -lt 20) {
            if ($event.WaitOne(0)) { throw 'Ввод отменён. Подключение сохранено.' }
            $line = $reader.ReadyLine
            if ($null -eq $line) { $line = $reader.Take() }
            if ($null -ne $line) {
                if ($ReadyState -eq 'browser' -and $line.StartsWith('REMOTEAGENTS_BROWSER_READY=http://127.0.0.1:')) { $component.State='ready'; return $component }
                if ($ReadyState -eq 'desktop' -and $line -match '\AREMOTEAGENTS_DESKTOP_READY=127\.0\.0\.1:[0-9]+\z') { $component.State='ready'; return $component }
                try { $status = $line | ConvertFrom-Json -ErrorAction Stop } catch { $status = $null }
                if ($status -and $status.state -eq $ReadyState) { $component.State=$ReadyState; return $component }
            }
            if ($process.HasExited -and $reader.Complete) { throw ('Компонент завершился с кодом ' + $process.ExitCode + '. Посмотрите сообщение выше.') }
            Start-Sleep -Milliseconds 50
        }
        throw 'Ожидание подключения завершилось. Повторите запуск; прежние данные сохранены.'
    } catch { Stop-ManagedComponent $component; throw }
}
function Get-ManagedComponentState($Component) {
    if (-not $Component -or $Component.Process.HasExited) { return 'stopped' }
    while ($null -ne ($line = $Component.Output.Take())) {
        try { $status = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($status.state -in @('ready','connected','disconnected','stopped')) { $Component.State=[string]$status.state }
    }
    return $Component.State
}
function Get-ProjectClientContext {
    $localData = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not $localData) { throw 'Не найдена папка данных Windows. Подключение проектов пока недоступно; режим сервера работает.' }
    $clientRoot = Join-Path $localData 'RemoteAgents'
    if (-not (Test-Path -LiteralPath $clientRoot)) { [IO.Directory]::CreateDirectory($clientRoot) | Out-Null; Protect-NewDirectory $clientRoot }
    $clientPath = Join-Path $clientRoot 'computer.json'
    if (Test-Path -LiteralPath $clientPath -PathType Leaf) {
        $client = [IO.File]::ReadAllText($clientPath) | ConvertFrom-Json
        if ($client.version -ne 1 -or $client.id -notmatch '\A[a-f0-9]{32}\z') { throw 'Не удалось прочитать привязку этого компьютера. Сохранённые данные не изменены.' }
    } else {
        $client = [pscustomobject]@{ version=1; id=[guid]::NewGuid().ToString('N') }
        Save-ProfileMetadata $client $clientPath
    }
    $projectRoot = Join-Path $profileDirectory 'project-connections'
    $projectData = Join-Path $projectRoot $client.id
    foreach ($directory in @($projectRoot,$projectData)) {
        if (-not (Test-Path -LiteralPath $directory)) { [IO.Directory]::CreateDirectory($directory) | Out-Null; Protect-NewDirectory $directory }
    }
    return [pscustomobject]@{ ClientId=[string]$client.id; DataDir=$projectData }
}
function Start-ProjectWindowsBridge([string]$ProjectId, [string]$ClientId, [string]$ReplicaPath, [bool]$AllowShell, [string]$SyncDataDir, [string]$Agents = '1') {
    if (-not $SyncDataDir) { throw 'Не задана проверка рабочей копии. Управление Windows не открыто.' }
    if (-not (Test-Path -LiteralPath $ReplicaPath -PathType Container)) { throw 'Рабочая копия ещё не готова. Соединение с Windows не открыто.' }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $label = 'win-' + [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($profileId + '/' + $ClientId + '/' + $ProjectId))).Replace('-','').ToLowerInvariant().Substring(0,28) }
    finally { $hash.Dispose() }
    $hook = Join-Path $PSScriptRoot 'Get-CodexWindowsBridgeRegistration.ps1'
    if (-not (Test-Path -LiteralPath $hook -PathType Leaf)) { throw 'Не хватает компонента подключения Windows. Скопируйте полный комплект.' }
    $registration = & $hook -DeviceLabel $label -Agents $Agents -ProjectId $ProjectId
    . (Join-Path $PSScriptRoot 'Agent.Handoff.ps1')
    $handoff = New-RemoteAgentHandoff -ProjectId $ProjectId -HostId $ClientId -DeviceLabel $label -ReplicaPath $ReplicaPath -Agents $Agents -AllowShell $AllowShell
    $payload = @'
set -eu
check_marker_path() {
    [ ! -L "$1" ] && [ "$(stat -c %u "$1")" = 0 ] || exit 41
    mode=$(stat -c %a "$1")
    [ $((0$mode & 0022)) -eq 0 ] || exit 41
}
for directory in /var /var/lib /var/lib/remote-agents; do check_marker_path "$directory"; done
if [ ! -e /var/lib/remote-agents/windows-mcp ]; then mkdir -m 755 /var/lib/remote-agents/windows-mcp; fi
check_marker_path /var/lib/remote-agents/windows-mcp
runuser -u remoteagents -- env HOME=/home/remoteagents bash -c 'umask 077; mkdir -p "$HOME/.local/share/codex-remote" "$HOME/.local/state/codex-remote"'
'@
    $payload = $payload.Replace("`r`n","`n") + "`n"
    foreach ($name in @('codex-windows-bridge.py','codex-bridge-session.py')) {
        $source = Join-Path $PSScriptRoot $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Не хватает серверного компонента подключения Windows. Скопируйте полный комплект.' }
        $encoded = [Convert]::ToBase64String([IO.File]::ReadAllBytes($source))
        $payload += "runuser -u remoteagents -- env HOME=/home/remoteagents bash -c 'umask 077; base64 --decode > `"`$HOME/.local/share/codex-remote/$name`"' <<'REMOTEAGENTS_PUBLIC_SOURCE'`n$encoded`nREMOTEAGENTS_PUBLIC_SOURCE`n"
    }
    $marker = '/var/lib/remote-agents/windows-mcp/' + $registration.Name
    $payload += "REMOTEAGENTS_MANAGED_MCP=0`nif [ -e '$marker' ] || [ -L '$marker' ]; then check_marker_path '$marker'; REMOTEAGENTS_MANAGED_MCP=1; fi`n"
    $payload += $registration.RemoteScript
    $payload += "umask 022`n: > '$marker'`n"
    $payload += $handoff.RemoteScript
    $arguments = $common + @('-i',$keyPath,'-o','IdentitiesOnly=yes','-o','PubkeyAuthentication=yes','-o','PreferredAuthentications=publickey','-o','PasswordAuthentication=no','-o','KbdInteractiveAuthentication=no','-T',$ServerAddress,'if [ "$(id -u)" -eq 0 ]; then exec bash -s; else exec sudo -n bash -s; fi')
    if ((Invoke-ProfileSsh -Arguments $arguments -InputText $payload) -ne 0) { throw 'Подключение Windows не подготовлено. Прежние файлы сохранены; причину смотрите выше.' }
    $parameters = @('-VPSHost',$ServerAddress,'-VPSUser',$Login,'-IdentityFile',$keyPath,'-Workspace',$ReplicaPath,'-DeviceLabel',$label,'-KnownHostsFile',$knownHostsPath,'-SSHConfig',$configPath,'-SSHExecutable',$script:sshExecutable,'-ServerUser','remoteagents','-RemoteBase','/home/remoteagents/.local/share/codex-remote','-SocketPath',$registration.SocketPath,'-AskpassExecutable',$script:askpassExecutable,'-ManagedSession')
    $parameters += @('-ServerOwnedReplica','-SyncGuardPath',(Join-Path $PSScriptRoot 'Invoke-RemoteSyncGuard.ps1'),'-SyncDataDir',$SyncDataDir,'-ProjectId',$ProjectId,'-HostId',$ClientId)
    if ($AllowShell) { $parameters += '-AllowShell' }
    $component=Start-ManagedComponent (Join-Path $PSScriptRoot 'Start-CodexWindowsBridge.ps1') $parameters 'connected'
    try {
        Write-Host 'Проверяем инструменты Windows на временном файле: два изменения сервера и новая проверка синхронизации.'
        if ((Invoke-ProfileSsh -Arguments $arguments -InputText $handoff.SmokeScript) -ne 0) { throw 'Проверка инструментов Windows не пройдена. Настройка агенту пока не передана.' }
    } catch { Stop-ManagedComponent $component; throw }
    $component | Add-Member -NotePropertyName Handoff -NotePropertyValue $handoff -Force
    Write-Host 'Подключение Windows подготовлено. Это проверка транспорта; модель ещё не запускалась.'
    return $component
}
function Initialize-ProjectModule {
    if (Get-Module -Name RemoteAgentsInstallerSync) { return }
    Import-Module (New-Module -Name RemoteAgentsInstallerSync -ArgumentList $PSScriptRoot -ScriptBlock {
        param($root)
        . (Join-Path $root 'Sync.Workspace.ps1')
        . (Join-Path $root 'Sync.Runtime.ps1')
        . (Join-Path $root 'Select-RemoteAgentsProjects.ps1')
        Export-ModuleMember -Function *
    }) -Global -Force
}
function Select-ExecutionMode {
    Write-Host 'Где выполнять команды проекта?'
    Write-Host '1. На этом компьютере — через отдельную рабочую копию'
    Write-Host '2. На сервере — без подключения папок Windows'
    $saved = if ($metadata.executionMode -in @('1','2')) { [string]$metadata.executionMode } else { '' }
    do {
        $question = if ($saved) { 'Место работы: 1 или 2; Enter — ' + $saved } else { 'Место работы: введите 1 или 2' }
        $mode=(Read-Host $question).Trim()
        if (-not $mode -and $saved) { $mode=$saved }
    } until ($mode -in @('1','2'))
    $metadata | Add-Member -NotePropertyName executionMode -NotePropertyValue $mode -Force
    Save-ProfileMetadata $metadata $metadataPath
    return $mode
}
function Add-ProjectFolder($Context) {
    return Show-RemoteSyncProjectSelection -DataDir $Context.DataDir -HostId $Context.ClientId
}
function Connect-ProjectFolders([string]$Agents, $Sessions) {
    Initialize-ProjectModule
    $context=Get-ProjectClientContext
    $transport=[pscustomobject]@{
        sshExecutable=$script:sshExecutable;askpassExecutable=$script:askpassExecutable
        serverAddress=$ServerAddress;login=$Login;keyPath=$keyPath;knownHostsPath=$knownHostsPath;configPath=$configPath
        arguments=@($common + @('-i',$keyPath,'-o','IdentitiesOnly=yes','-o','PubkeyAuthentication=yes','-o','PreferredAuthentications=publickey','-o','PasswordAuthentication=no','-o','KbdInteractiveAuthentication=no','-T',$ServerAddress))
    }
    Save-ProfileMetadata $transport (Join-Path $context.DataDir 'ssh-transport.json')
    $selectionResult=Add-ProjectFolder $context
    if($selectionResult.cancelled){Write-Host 'Выбор отменён. Перенос не запущен.';return}
    $selection=Get-RemoteSyncSelection -DataDir $context.DataDir -HostId $context.ClientId
    $enabledIds=@($selection.projects|Where-Object{$_.selected}|ForEach-Object{$_.projectId})
    # Stop only deselected sessions owned by this installer; bindings/data stay intact.
    foreach($sessionId in @($Sessions.Keys)){
        if($sessionId -notin $enabledIds){Stop-ManagedComponent $Sessions[$sessionId].Bridge;Stop-ManagedComponent $Sessions[$sessionId].Sync;$Sessions.Remove($sessionId)}
    }
    while ($true) {
        $projects=@(Get-RemoteSyncProjects -DataDir $context.DataDir | Where-Object { $_.hostId -eq $context.ClientId -and $_.projectId -in $enabledIds }|Sort-Object sourcePath)
        if(!$projects.Count){Write-Host 'Ни один проект не выбран. Перенос не запущен.';return}
        foreach ($project in $projects) {
            if ($Sessions.ContainsKey($project.projectId) -and (Get-ManagedComponentState $Sessions[$project.projectId].Sync) -ne 'stopped' -and (-not $Sessions[$project.projectId].Bridge -or (Get-ManagedComponentState $Sessions[$project.projectId].Bridge) -ne 'stopped')) { Write-Host 'Подключение этой папки уже запущено.'; continue }
            if ($Sessions.ContainsKey($project.projectId)) { Stop-ManagedComponent $Sessions[$project.projectId].Bridge; Stop-ManagedComponent $Sessions[$project.projectId].Sync; $Sessions.Remove($project.projectId) }
            $sync=$null;$bridge=$null
            try {
                Write-Host ('Подключаем '+[IO.Path]::GetFileName($project.sourcePath)+'. Первый перенос может занять несколько минут.')
                $sync=Start-ManagedComponent (Join-Path $PSScriptRoot 'Connect-RemoteAgentsProject.ps1') @('-DataDir',$context.DataDir,'-ProjectId',$project.projectId,'-HostId',$context.ClientId,'-ManagedSession') 'project-ready'
                $ready=$sync.Output.ReadyLine | ConvertFrom-Json
                if (-not $ready.ready -or -not $ready.fresh -or $ready.projectId -ne $project.projectId -or $ready.hostId -ne $context.ClientId -or -not [string]::Equals($ready.replicaPath,$project.replicaPath,[StringComparison]::OrdinalIgnoreCase)) { throw 'Рабочая копия ещё не подтверждена.' }
                $allowShell=Confirm-Action 'Разрешить выбранному серверному агенту выполнять команды настройки проекта в Windows и безопасную проверку временного файла? Команды работают с вашими правами.' -DefaultNo
                $bridge=Start-ProjectWindowsBridge $project.projectId $context.ClientId $ready.replicaPath ([bool]$allowShell) $context.DataDir $Agents
                $Sessions[$project.projectId]=[pscustomobject]@{Sync=$sync;Bridge=$bridge}
                Write-Host ('Проект «'+[IO.Path]::GetFileName($project.sourcePath)+'» подключён.')
                Write-Host 'На рабочем столе сервера откройте «Начать настройку проекта»: выберите указанную папку и вставьте готовое первое сообщение в чат.'
                Write-Host 'Для Claude используйте вкладку Code. В Codex перезапустите MCP в настройках. Подключение Windows работает, пока эта программа открыта.'
            } catch { Stop-ManagedComponent $bridge; Stop-ManagedComponent $sync; Write-Host ('Папка не подключена: '+$_.Exception.Message) }
        }
        return
    }
}
function Request-VpsVpnSetup {
    Write-Host 'Настроить Amnezia VPN?'
    Write-Host '1. Да'
    Write-Host '2. Нет'
    do {
        $vpnChoice = (Read-Host 'Выберите 1 или 2; Enter — нет').Trim()
    } until ($vpnChoice -in @('', '1', '2'))
    if ($vpnChoice -eq '1') { Open-VpsVpn }
}
function Open-VpsVpn {
    $vpnHook = Join-Path $PSScriptRoot 'setup-amnezia.ps1'
    if (-not [IO.File]::Exists($vpnHook)) { throw 'Не хватает компонента VPN. Скопируйте весь комплект программы.' }
    $vpnResult = & $vpnHook -ProfileDirectory $profileDirectory
    if ($vpnResult.Status -eq 'GuiOpened') {
        Write-Host 'Продолжите настройку сервера в окне AmneziaVPN. Приложения сервера работают отдельно.'
    }
}
function Open-ServerDesktop {
    if (-not (Get-Command mstsc.exe -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'Для рабочего стола нужен компонент Windows «Подключение к удалённому рабочему столу» (mstsc). Чат Codex можно открыть без него.'
    }
    $desktopHook = Join-Path $PSScriptRoot 'server-desktop.ps1'
    if (-not (Test-Path -LiteralPath $desktopHook -PathType Leaf)) { throw 'Не хватает компонента рабочего стола. Скопируйте весь комплект программы.' }
    $desktopParameters = @('-VPSHost',$ServerAddress,'-VPSUser',$Login,'-IdentityFile',$keyPath,'-SSHExecutable',$script:sshExecutable,'-SSHConfig',$configPath,'-KnownHostsFile',$knownHostsPath,'-ServerUser','remoteagents','-Prepare','-ManagedSession','-AskpassExecutable',$script:askpassExecutable)
    Write-Host 'Подготавливаем рабочий стол сервера. При первом запуске это может занять несколько минут.'
    Write-Host 'Рабочий стол открывается через SSH; отдельный пароль не нужен. Если появится выбор сеанса — нажмите OK.'
    $desktop = Start-ManagedComponent $desktopHook $desktopParameters 'desktop'
    try {
        Write-Host 'Рабочий стол открыт через защищённое соединение.'
        do { $closeDesktop = (Read-Host 'Введите 0, чтобы закрыть соединение и вернуться. Enter оставляет его открытым').Trim() } until ($closeDesktop -eq '0')
    } finally { Stop-ManagedComponent $desktop }
}
function Install-AgentApplications([string]$Choice) {
    $files = @('server-agent-user-v1.sh')
    if ($Choice -in @('1','3')) { $files += @('server-codex-v1.sh','server-chatgpt.sh') }
    if ($Choice -in @('2','3')) { $files += @('server-claude-desktop.sh','server-claude-code.sh') }
    if ($Choice -notin @('1','2','3')) { throw 'Выберите приложение из списка.' }
    $parts = @()
    foreach ($file in $files) {
        $path = Join-Path $PSScriptRoot $file
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Не хватает файла ' + $file + '. Скопируйте полный комплект программы.') }
        $parts += [IO.File]::ReadAllText($path).Replace("`r`n", "`n").TrimStart([char]0xFEFF)
    }
    # Separate shells preserve each public script's traps/exit without ending the bundle.
    $payload = "set -e`n"
    foreach ($part in $parts) {
        $delimiter = 'REMOTEAGENTS_PUBLIC_' + [guid]::NewGuid().ToString('N')
        $payload += "bash -s -- remoteagents <<'$delimiter'`n$part`n$delimiter`n"
    }
    $agentSsh = $common + @('-i',$keyPath,'-o','IdentitiesOnly=yes','-o','PubkeyAuthentication=yes','-o','PreferredAuthentications=publickey','-o','PasswordAuthentication=no','-o','KbdInteractiveAuthentication=no')
    Write-Host 'Проверяем выбранные приложения. Готовые используем повторно; недостающие установим.'
    $command = 'if [ "$(id -u)" -eq 0 ]; then exec bash -s; else exec sudo -n bash -s; fi'
    if ((Invoke-ProfileSsh -Arguments ($agentSsh + @('-T',$ServerAddress,$command)) -InputText $payload) -ne 0) { throw 'Приложения пока не готовы. Причина выше; можно повторить без удаления данных.' }
}
function Start-RemoteCodex {
    Write-Host ''
    Write-Host 'Какие приложения подготовить на сервере?'
    Write-Host '1. Codex — приложение'
    Write-Host '2. Claude — приложение'
    Write-Host '3. Оба приложения'
    Write-Host '0. Только рабочий стол, без установки приложений'
    $savedAgents = if ($metadata.agentApplications -in @('1','2','3')) { [string]$metadata.agentApplications } else { '1' }
    do { $agents = (Read-Host ('Выберите 1, 2 или 3; Enter — ' + $savedAgents)).Trim(); if (-not $agents) { $agents=$savedAgents } } until ($agents -in @('0','1','2','3'))
    if ($agents -ne '0') {
        Install-AgentApplications $agents
        $metadata | Add-Member -NotePropertyName agentApplications -NotePropertyValue $agents -Force
        Save-ProfileMetadata $metadata $metadataPath
        $script:setupOutcome = 'applications-ready'
        Write-Host 'Приложения готовы. Откройте ярлык на рабочем столе сервера и войдите в свой аккаунт.'
    }
    $sessions=@{}
    $mode=if ($agents -eq '0') { '2' } else { Select-ExecutionMode }
    try {
      if ($mode -eq '1') { Connect-ProjectFolders $agents $sessions }
      else { Write-Host 'Работа на сервере: папки Windows и мост не подключаются.' }
      while ($true) {
        Write-Host ''
        Write-Host '1. Рабочий стол сервера — открыть приложения'
        if ($agents -in @('1','3')) { Write-Host '2. Дополнительно: Codex в терминале' }
        if ($mode -eq '1') { Write-Host '3. Подключить папки проектов / посмотреть состояние'; Write-Host '4. Отключить папки и управление Windows' }
        Write-Host '5. VPN на этом сервере — Amnezia'
        Write-Host '0. Вернуться к списку серверов'
        $action = (Read-Host 'Что открыть? Enter — рабочий стол').Trim()
        if (-not $action) { $action='1' }
        if ($action -eq '0') { return }
        if ($action -eq '1') {
            try { Open-ServerDesktop }
            catch { Write-Host 'Рабочий стол не открыт. Повторите подключение.'; Write-Host ('Подробности: ' + $_.Exception.Message) }
        }
        if ($action -eq '2' -and $agents -in @('1','3')) { Start-CodexTerminal -ServerTerminalOnly }
        if ($action -eq '5') {
            try { Open-VpsVpn } catch { Write-Host ('VPN пока не настроен: ' + $_.Exception.Message) }
        }
        if ($action -eq '3' -and $mode -eq '1') { Connect-ProjectFolders $agents $sessions }
        if ($action -eq '4' -and $mode -eq '1') {
            foreach ($session in $sessions.Values) { Stop-ManagedComponent $session.Bridge; Stop-ManagedComponent $session.Sync }
            $sessions.Clear(); Write-Host 'Windows отключён. Серверные файлы и исходная папка сохранены.'
        }
      }
    } finally {
        foreach ($session in $sessions.Values) { Stop-ManagedComponent $session.Bridge; Stop-ManagedComponent $session.Sync }
    }
}
function Start-CodexTerminal {
    param([switch]$ServerTerminalOnly)
    $browser = $null
    Write-Host ''
    Write-Host 'Дальше — Codex на сервере. Существующая исправная установка будет использована повторно.'
    $bootstrapPath = Join-Path $PSScriptRoot 'server-codex-v1.sh'
    if (-not (Test-Path -LiteralPath $bootstrapPath -PathType Leaf)) { throw 'Не хватает server-codex-v1.sh. Скопируйте весь комплект программы.' }
    $codexSsh = $common + @('-i', $keyPath, '-o', 'IdentitiesOnly=yes', '-o', 'PubkeyAuthentication=yes', '-o', 'PreferredAuthentications=publickey', '-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no')
    $bootstrap = [IO.File]::ReadAllText($bootstrapPath).Replace("`r`n", "`n").TrimStart([char]0xFEFF)
    $deviceHash = [Security.Cryptography.SHA256]::Create()
    try { $deviceLabel = 'win-' + [BitConverter]::ToString($deviceHash.ComputeHash([Text.Encoding]::UTF8.GetBytes($profileId))).Replace('-','').ToLowerInvariant().Substring(0,28) }
    finally { $deviceHash.Dispose() }
    $bundle = ''
    foreach ($pythonFile in @('codex-windows-bridge.py','codex-bridge-session.py')) {
        $pythonPath = Join-Path $PSScriptRoot $pythonFile
        if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) { throw ('Не хватает компонента ' + $pythonFile + '. Скопируйте весь комплект.') }
        $encoded = [Convert]::ToBase64String([IO.File]::ReadAllBytes($pythonPath))
        $bundle += "runuser -u remoteagents -- env HOME=/home/remoteagents bash -c 'umask 077; base64 --decode > `"`$HOME/.local/share/codex-remote/$pythonFile`"' <<'REMOTEAGENTS_PUBLIC_SOURCE'`n$encoded`nREMOTEAGENTS_PUBLIC_SOURCE`n"
    }
    $bridgeSetup = "`nrunuser -u remoteagents -- env HOME=/home/remoteagents bash -c 'umask 077; mkdir -p `"`$HOME/.local/share/codex-remote`" `"`$HOME/.local/state/codex-remote`"'`n" + $bundle + "runuser -u remoteagents -- env HOME=/home/remoteagents /opt/remote-agents/codex/0.166.0/bin/codex mcp add windows-$deviceLabel -- python3 /home/remoteagents/.local/share/codex-remote/codex-windows-bridge.py --socket /home/remoteagents/.local/state/codex-remote/$deviceLabel.sock`n"
    if (-not $ServerTerminalOnly) {
        $bootstrap += $bridgeSetup
        $bootstrap += "check_root_path `"`$state/windows-mcp/windows-$deviceLabel`"`n: > `"`$state/windows-mcp/windows-$deviceLabel`"`n"
    }
    $prepareCommand = 'if [ "$(id -u)" -eq 0 ]; then exec bash -s; else exec sudo -n bash -s; fi'
    $prepareCode = Invoke-ProfileSsh -Arguments ($codexSsh + @('-T', $ServerAddress, $prepareCommand)) -InputText $bootstrap
    if ($prepareCode -ne 0) { throw ('Codex пока не подготовлен. Причина выше; код ' + $prepareCode + '. Подключение и прежние данные сохранены.') }
    $script:setupOutcome = 'codex-installed'
    if ($ServerTerminalOnly) { $executionMode='2'; Write-Host 'Терминал работает с файлами сервера. Подключённые проекты Windows остаются доступны в приложении Codex.' }
    else {
    Write-Host ''
    Write-Host 'Где выполнять работу? Сам Codex в обоих случаях работает на сервере.'
    Write-Host '1. На этом компьютере через соединение с Windows'
    Write-Host '2. На сервере'
    $savedMode = if ($metadata.executionMode -in @('1','2')) { [string]$metadata.executionMode } else { '2' }
    do { $executionMode = (Read-Host ('Место работы: 1 или 2; Enter — ' + $savedMode)).Trim(); if (-not $executionMode) { $executionMode=$savedMode } } until ($executionMode -in @('1','2'))
    if ($metadata.executionMode -ne $executionMode) {
        $metadata | Add-Member -NotePropertyName executionMode -NotePropertyValue $executionMode -Force
        Save-ProfileMetadata $metadata $metadataPath
    }
    }
    if ((Invoke-CodexSession 'status') -ne 0) {
        Write-Host ''
        Write-Host 'Теперь войдите в свой аккаунт ChatGPT.'
        Write-Host '1. Открыть браузер на сервере (рекомендуется)'
        Write-Host '2. Войти через браузер этого компьютера'
        Write-Host '0. Вернуться без входа'
        do { $authChoice = (Read-Host 'Выберите 1 или 2; Enter — 1').Trim(); if (-not $authChoice) { $authChoice = '1' } } until ($authChoice -in @('0','1','2'))
        if ($authChoice -eq '0') { return }
        if ($authChoice -eq '1') {
            $browserHook = Join-Path $PSScriptRoot 'server-browser.ps1'
            if (-not (Test-Path -LiteralPath $browserHook -PathType Leaf)) { throw 'Не хватает компонента браузера server-browser.ps1. Скопируйте полный комплект.' }
            $browserParameters = @('-VPSHost',$ServerAddress,'-VPSUser',$Login,'-IdentityFile',$keyPath,'-SSHExecutable',$script:sshExecutable,'-SSHConfig',$configPath,'-KnownHostsFile',$knownHostsPath,'-ServerUser','remoteagents','-Prepare','-ManagedSession','-AskpassExecutable',$script:askpassExecutable)
            $browser = Start-ManagedComponent $browserHook $browserParameters 'browser'
            Write-Host 'В следующем шаге появятся ссылка и одноразовый код. Откройте ссылку в браузере сервера и введите там код.'
        } else {
            Write-Host 'Откройте показанную ссылку в браузере этого компьютера и введите код. Этот способ входа не использует адрес сервера для браузера.'
        }
        Write-Host 'Если вход по коду недоступен, разрешите его в настройках безопасности ChatGPT или у администратора организации.'
        try {
            if ((Invoke-CodexSession 'auth-device' -Terminal) -ne 0) { throw 'Вход в Codex не завершён. Причина выше; при повторном запуске установка сохранится.' }
        } finally { Stop-ManagedComponent $browser }
    }
    if ((Invoke-CodexSession 'status') -ne 0) { throw 'Codex установлен, но подтверждения входа в аккаунт нет. Повторите вход.' }
    $script:setupOutcome = 'codex-ready'
    $bridge = $null
    if ($executionMode -eq '1') {
    $workspace = $metadata.bridgeWorkspace
    if (-not $workspace -or -not (Test-Path -LiteralPath $workspace -PathType Container)) {
        Add-Type -AssemblyName System.Windows.Forms
        $picker = New-Object Windows.Forms.FolderBrowserDialog
        $picker.Description = 'Выберите папку Windows, с которой Codex сможет работать через соединение. Остальные папки не предоставляются.'
        try { if ($picker.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { Write-Host 'Выбор папки отменён. Codex установлен; выберите сервер повторно для продолжения.'; return }; $workspace = $picker.SelectedPath }
        finally { $picker.Dispose() }
        $metadata | Add-Member -NotePropertyName bridgeWorkspace -NotePropertyValue $workspace -Force
        Save-ProfileMetadata $metadata $metadataPath
    }
    $bridgeHook = Join-Path $PSScriptRoot 'Start-CodexWindowsBridge.ps1'
    if (-not (Test-Path -LiteralPath $bridgeHook -PathType Leaf)) { throw 'Не хватает компонента связи с Windows. Скопируйте весь комплект программы.' }
    Write-Host 'Соединяем Codex с выбранной папкой Windows. Команды Windows требуют отдельного разрешения.'
    $bridgeParameters = @('-VPSHost',$ServerAddress,'-VPSUser',$Login,'-IdentityFile',$keyPath,'-Workspace',$workspace,'-DeviceLabel',$deviceLabel,'-KnownHostsFile',$knownHostsPath,'-SSHConfig',$configPath,'-SSHExecutable',$script:sshExecutable,'-ServerUser','remoteagents','-RemoteBase','/home/remoteagents/.local/share/codex-remote','-SocketPath',('/home/remoteagents/.local/state/codex-remote/' + $deviceLabel + '.sock'),'-AskpassExecutable',$script:askpassExecutable,'-ManagedSession')
    Write-Host 'Разрешённые команды работают с вашими правами Windows, включая доступные вам сеть и другие папки.'
    if (Confirm-Action 'Разрешить Codex запускать команды на этом компьютере?' -DefaultNo) { $bridgeParameters += '-AllowShell' }
    $bridge = Start-ManagedComponent $bridgeHook $bridgeParameters 'connected'
    } else {
        Write-Host 'Рабочая папка на сервере: /home/remoteagents/work. Соединение с папками Windows не запускается.'
    }
    Write-Host 'Node, PHP и Android этой программой пока не устанавливаются. VPN Windows не изменяется.'
    Write-Host ''
    Write-Host 'Codex готов. Сейчас откроется чат на сервере; рабочая папка сохраняется между запусками.'
    Write-Host 'Чтобы вернуться сюда, завершите Codex командой /quit.'
    try {
        if ((Invoke-CodexSession 'chat' -Terminal) -ne 0) { throw 'Сеанс Codex завершился с ошибкой. Сообщение выше; повторный запуск использует сохранённую установку.' }
    } finally { Stop-ManagedComponent $bridge }
}
function Start-ConnectionSetup {
param([string]$ServerAddress, [string]$Login, [string]$ProfileName, [string]$DataDir)
$script:setupOutcome = 'stopped'
$script:setupExitCode = 0
$script:askpassExecutable = $null
try {
    Test-WindowsRuntime
    if (-not $DataDir) {
        $localData = [Environment]::GetFolderPath('LocalApplicationData')
        if (-not $localData) { throw 'Не найдена папка данных Windows. Укажите другую папку параметром -DataDir.' }
        $DataDir = Join-Path (Join-Path $localData 'RemoteAgents') 'ssh-profiles'
    }
    if (-not [IO.Path]::IsPathRooted($DataDir)) { throw 'Параметр -DataDir должен содержать полный путь к папке, например D:\My SSH State.' }
    $DataDir = [IO.Path]::GetFullPath($DataDir)
    Write-Host 'Подключим этот компьютер к вашему серверу.'
    Write-Host 'Пароли вводите здесь, не отправляйте их в чат.'
    Write-Host ''
    Write-Host 'Этап 1. Выберите сервер'
    $available = @()
    if (Test-Path -LiteralPath $DataDir -PathType Container) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $DataDir -Directory | Sort-Object Name)) {
            if ($folder.Name -notmatch '\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z') { continue }
            $candidatePath = Join-Path $folder.FullName 'profile.json'
            if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) { continue }
            try {
                $candidate = [IO.File]::ReadAllText($candidatePath) | ConvertFrom-Json
                if ($candidate.version -ne 1 -or $candidate.profile -cne $folder.Name -or $candidate.hiddenFromList -eq $true) { continue }
                $name = [string]$candidate.displayName
                if (-not $name) { $name = $folder.Name }
                $available += [pscustomobject]@{ Id = $folder.Name; Name = $name; Address = [string]$candidate.serverAddress }
            } catch { Write-Host 'Один сервер не удалось показать в списке. Его данные сохранены.' }
        }
    }
    $selected = $null
    $displayName = $null
    if ($ProfileName) {
        $matches = @($available | Where-Object { $_.Id -ceq $ProfileName -or $_.Name -ceq $ProfileName })
        if ($matches.Count -gt 1) { throw 'Есть несколько серверов с таким названием. Запустите без -ProfileName и выберите номер.' }
        if ($matches.Count -eq 1) { $selected = $matches[0] } else { $displayName = $ProfileName }
    } elseif ($available.Count) {
        for ($i = 0; $i -lt $available.Count; $i++) {
            $safeName = $available[$i].Name -replace '[\x00-\x1f\x7f]', ' '
            $safeAddress = $available[$i].Address -replace '[\x00-\x1f\x7f]', ' '
            Write-Host ('  {0}. {1} — {2}' -f ($i + 1), $safeName, $safeAddress)
        }
        Write-Host '  0. Добавить новый сервер'
        do {
            $answer = Read-Host 'Введите номер сервера или 0 для нового'
            $number = -1
            $validChoice = [int]::TryParse($answer, [ref]$number) -and $number -ge 0 -and $number -le $available.Count
            if (-not $validChoice) { Write-Host 'Введите номер из списка или 0 для нового сервера.' }
        } until ($validChoice)
        if ($number -gt 0) { $selected = $available[$number - 1] }
    }
    if ($selected) {
        $profileId = $selected.Id
        $displayName = $selected.Name
        Write-Host ('Выбран сервер: ' + $displayName)
    } else {
        if (-not $displayName) { $displayName = Read-Host 'Как назвать сервер? Например: Рабочий сервер. Это только название' }
        $displayName = $displayName.Trim()
        if (-not $displayName -or $displayName.Length -gt 120 -or $displayName -match '[\x00-\x1f\x7f]') { throw 'Введите название длиной до 120 символов. Можно по-русски, с пробелами.' }
        $profileId = [guid]::NewGuid().ToString('N')
    }
    $profileDirectory = Join-Path $DataDir $profileId
    $metadataPath = Join-Path $profileDirectory 'profile.json'
    $keyPath = Join-Path $profileDirectory 'id_ed25519'
    $publicPath = Join-Path $profileDirectory 'id_ed25519.pub'
    $knownHostsPath = Join-Path $profileDirectory 'known_hosts'
    $configPath = Join-Path $profileDirectory 'ssh_config'
    $metadata = $null
    if (Test-Path -LiteralPath $profileDirectory) {
        if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { throw 'Добавьте сервер заново под другим названием. Прежние данные сохранены.' }
        $metadata = [IO.File]::ReadAllText($metadataPath) | ConvertFrom-Json
        if ($metadata.version -ne 1 -or $metadata.profile -cne $profileId) { throw 'Нужна помощь с сохранёнными настройками сервера. Данные не изменены.' }
        if (($ServerAddress -and $ServerAddress -cne $metadata.serverAddress) -or ($Login -and $Login -cne $metadata.login)) { throw 'Добавьте новый сервер: адрес или пользователь отличаются. Старые данные сохранены.' }
        $ServerAddress = [string]$metadata.serverAddress
        $Login = [string]$metadata.login
    }
    if (-not $ServerAddress) { $ServerAddress = Read-Host 'Адрес из панели хостинга. Например: 203.0.113.10' }
    if (-not $Login) {
        $Login = Read-Host 'Имя пользователя из хостинга. Обычно root; Enter — root'
        if (-not $Login) { $Login = 'root' }
    }
    # Clipboard/typing padding is not part of a server address.
    $ServerAddress = [regex]::Replace($ServerAddress, '\A[\s\uFEFF\u200B]+|[\s\uFEFF\u200B]+\z', '')
    $parsedAddress = $null
    $isIp = [Net.IPAddress]::TryParse($ServerAddress, [ref]$parsedAddress)
    if ($ServerAddress -match '[\x00-\x20\x7f%]' -or $ServerAddress.StartsWith('-') -or (-not $isIp -and $ServerAddress -notmatch '\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z')) { throw ('Проверьте адрес из панели хостинга: без https:// и пробелов. Длина введённого адреса: {0}.' -f $ServerAddress.Length) }
    if ($Login -notmatch '\A[A-Za-z_][A-Za-z0-9_.-]{0,63}\$?\z') { throw 'Введите имя пользователя из панели хостинга, например root.' }
    if (-not (Test-Path -LiteralPath $DataDir)) {
        New-Item -ItemType Directory -Path $DataDir | Out-Null
        Protect-NewDirectory $DataDir
    }
    if (-not $metadata) {
        New-Item -ItemType Directory -Path $profileDirectory | Out-Null
        Protect-NewDirectory $profileDirectory
        # Connection metadata only; never credentials.
        $newMetadata = [ordered]@{ version = 1; profile = $profileId; displayName = $displayName; serverAddress = $ServerAddress; login = $Login }
        $metadata = [pscustomobject]$newMetadata
        Save-ProfileMetadata $metadata $metadataPath
    }
    # Explicit empty configuration isolates user and system SSH configuration.
    if (Test-Path -LiteralPath $configPath) {
        if ((Get-Item -LiteralPath $configPath).Length -ne 0) { throw 'Нужна помощь с настройками подключения. Для безопасности остановлено; данные сохранены.' }
    } else { [IO.File]::WriteAllText($configPath, '') }
    if (-not (Test-Path -LiteralPath $knownHostsPath)) { [IO.File]::WriteAllText($knownHostsPath, '') }
    $knownHostsOption = 'UserKnownHostsFile="' + $knownHostsPath.Replace('\', '/') + '"'
    $common = @('-F', $configPath, '-o', $knownHostsOption, '-o', 'GlobalKnownHostsFile=none', '-o', 'StrictHostKeyChecking=ask', '-o', 'UpdateHostKeys=no', '-o', 'ForwardAgent=no', '-o', 'ClearAllForwardings=yes', '-o', 'IdentityAgent=none', '-o', 'BatchMode=no', '-l', $Login)
    $activeSlot = [string]$metadata.activeKey
    $activeDirectory = Get-KeyDirectory $activeSlot
    $keyPath = Join-Path $activeDirectory 'id_ed25519'
    $publicPath = Join-Path $activeDirectory 'id_ed25519.pub'
    $hasPrivate = Test-Path -LiteralPath $keyPath -PathType Leaf
    $hasPublic = Test-Path -LiteralPath $publicPath -PathType Leaf
    $action = '1'
    if ($selected) {
        Write-Host '1. Продолжить (Enter)'
        Write-Host '2. Настроить подключение заново'
        Write-Host '3. Изменить пароль защиты подключения'
        Write-Host '4. Убрать сервер из списка'
        Write-Host '5. Настроить VPN Amnezia'
        Write-Host '0. Выход'
        do {
            $action = (Read-Host 'Что сделать').Trim()
            if (-not $action) { $action = '1' }
        } until ($action -in @('0','1','2','3','4','5'))
        if ($action -eq '0') { Write-Host 'Данные сохранены. Можно вернуться позже.'; return }
    }
    if ($action -eq '5') { Open-VpsVpn; return }
    if ($action -eq '4') {
        Write-Host 'Уберём сервер только из списка. Сам сервер и файлы подключения останутся.'
        if (Confirm-Action 'Убрать этот сервер из списка?' -DefaultNo) {
            $metadata | Add-Member -NotePropertyName hiddenFromList -NotePropertyValue $true -Force
            Save-ProfileMetadata $metadata $metadataPath
            Write-Host 'Сервер убран из списка. Сохранённые файлы оставлены на компьютере.'
            $script:setupOutcome = 'removed'
        } else { Write-Host 'Ничего не изменено.' }
        return
    }
    if ($action -eq '3') {
        if (-not $hasPrivate -or -not $hasPublic) { throw 'Сохранённое подключение неполное. Выберите «Настроить подключение заново».' }
        Write-Host 'Это пароль защиты подключения, не пароль сервера.'
        Write-Host 'Введите старый пароль при запросе old passphrase, затем новый дважды. Enter вместо нового пароля снимет эту защиту.'
        Write-Host 'Если старый пароль забыт, отмените и выберите настройку заново.'
        & $script:keygenExecutable -p -f $keyPath
        if ($LASTEXITCODE -ne 0) { throw 'Изменить защиту не удалось. Если старый пароль забыт, настройте подключение заново.' }
        Write-Host 'Пароль защиты изменён.'
        $script:setupOutcome = 'changed'
        if (Confirm-Action 'Проверить вход сейчас?') {
            Write-Host 'Если появится окно защиты подключения, введите новый пароль.'
            Write-Host 'Если появится окно проверки сервера, сверьте код с панелью хостинга. Не уверены — «Отмена».'
            if ((Test-SavedConnection $keyPath) -ne 0) { throw 'Проверка входа не прошла. Изменение пароля защиты уже выполнено; посмотрите сообщение выше.' }
            Write-Host 'Вход на сервер проверен.'
            $script:setupOutcome = 'verified'
        }
        return
    }
    $usePending = $false
    if ($action -eq '2') {
        Write-Host 'Заново настраивается только вход с этого компьютера. Сервер и прежнее подключение сохранятся.'
        if (-not (Confirm-Action 'Начать настройку заново?' -DefaultNo)) { Write-Host 'Ничего не изменено.'; return }
        $usePending = $true
    } elseif ($selected) {
        if ($hasPrivate -and $hasPublic) {
            Write-Host 'Проверим сохранённый вход. Пароль защиты вводится в отдельном окне.'
            Write-Host 'Если появится окно проверки сервера, сверьте код с панелью хостинга. Не уверены — «Отмена».'
            if ((Test-SavedConnection $keyPath) -eq 0) {
                Write-Host ('Готово: вход на сервер проверен. Сервер: ' + $displayName)
            $script:setupOutcome = 'verified'
            Request-VpsVpnSetup
            Start-RemoteCodex
            return
            }
            if (-not (Confirm-Action 'Сохранённый вход пока не работает. Продолжить настройку с паролем сервера?')) { return }
            $usePending = [bool]$metadata.pendingKey
        } else {
            Write-Host 'Файлы подключения отсутствуют или неполные. Существующие файлы не удаляются.'
            if (-not (Confirm-Action 'Продолжить незавершённую настройку или создать отдельное новое подключение?')) { return }
            $usePending = $true
        }
    }
    if ($usePending) {
        $pendingSlot = [string]$metadata.pendingKey
        if ($pendingSlot) {
            $pendingDirectory = Get-KeyDirectory $pendingSlot
            $pendingPrivate = Test-Path -LiteralPath (Join-Path $pendingDirectory 'id_ed25519') -PathType Leaf
            $pendingPublic = Test-Path -LiteralPath (Join-Path $pendingDirectory 'id_ed25519.pub') -PathType Leaf
            if ($pendingPrivate -ne $pendingPublic) {
                Write-Host 'В незавершённой попытке не хватает одного файла. Он останется на месте.'
                if (-not (Confirm-Action 'Создать отдельный новый комплект?')) { return }
                $pendingSlot = $null
            } else { Write-Host 'Продолжаем незавершённую настройку без создания лишнего комплекта.' }
        }
        if (-not $pendingSlot) {
            $pendingSlot = 'key-' + [guid]::NewGuid().ToString('N')
            $setsDirectory = Join-Path $profileDirectory 'keysets'
            if (-not (Test-Path -LiteralPath $setsDirectory)) {
                New-Item -ItemType Directory -Path $setsDirectory | Out-Null
                Protect-NewDirectory $setsDirectory
            }
            $pendingDirectory = Get-KeyDirectory $pendingSlot
            New-Item -ItemType Directory -Path $pendingDirectory | Out-Null
            Protect-NewDirectory $pendingDirectory
            $metadata | Add-Member -NotePropertyName pendingKey -NotePropertyValue $pendingSlot -Force
            Save-ProfileMetadata $metadata $metadataPath
        }
        $keyPath = Join-Path $pendingDirectory 'id_ed25519'
        $publicPath = Join-Path $pendingDirectory 'id_ed25519.pub'
    }
    Write-Host ''
    Initialize-PasswordWindow
    Write-Host 'Этап 2. Подготовка подключения'
    $hasPrivate = Test-Path -LiteralPath $keyPath -PathType Leaf
    $hasPublic = Test-Path -LiteralPath $publicPath -PathType Leaf
    if ($hasPrivate -ne $hasPublic) { throw 'Подключение неполное. Повторите запуск и выберите настройку заново; файлы сохранены.' }
    if (-not $hasPrivate) {
        Write-Host 'При запросе Enter passphrase задайте отдельный пароль защиты подключения и повторите его. Это не пароль сервера.'
        Write-Host 'Можно нажать Enter дважды и оставить эту защиту без пароля. Тогда особенно важно никому не передавать файлы подключения.'
        & $script:keygenExecutable -t ed25519 -f $keyPath -C ('remoteagents-' + $profileId)
        if ($LASTEXITCODE -ne 0) { throw 'Подготовить подключение не удалось. Созданные файлы сохранены; повторный запуск предложит продолжение.' }
    }
    # Read public contents only. The private file is handled exclusively by native tools.
    $publicKey = [IO.File]::ReadAllText($publicPath).TrimEnd([char[]]"`r`n")
    if ($publicKey -notmatch '\Assh-ed25519 [A-Za-z0-9+/]+={0,2}(?: [\x20-\x7E]+)?\z') { throw 'Нужна помощь с файлом подключения. Серверу ничего не отправлено.' }
    Write-Host ''
    Write-Host 'Этап 3. Первый вход'
    Write-Host 'При первом входе откроется окно проверки сервера.'
    Write-Host 'Сверьте показанный код сервера с кодом в панели хостинга.'
    Write-Host 'Если код совпал — нажмите «Да, код совпал». Иначе — «Отмена».'
    Write-Host 'Введите пароль сервера в отдельном окне. Кнопка «Показать» поможет проверить ввод.'
    $installCommand = 'set -eu; umask 077; IFS= read -r key; key=$(printf ''%s'' "$key" | tr -d ''\r''); case "$key" in ''ssh-ed25519 ''*) ;; *) exit 20 ;; esac; dir="$HOME/.ssh"; mkdir -p "$dir"; chmod 700 "$dir"; touch "$dir/authorized_keys"; chmod 600 "$dir/authorized_keys"; if ! grep -qxF -- "$key" "$dir/authorized_keys"; then if [ -s "$dir/authorized_keys" ]; then printf ''\n'' >> "$dir/authorized_keys"; fi; printf ''%s\n'' "$key" >> "$dir/authorized_keys"; fi'
    $installArgs = $common + @('-o', 'PubkeyAuthentication=no', '-o', 'PasswordAuthentication=yes', '-o', 'KbdInteractiveAuthentication=yes', '-o', 'PreferredAuthentications=password,keyboard-interactive', $ServerAddress, $installCommand)
    $installExitCode = Invoke-ProfileSsh -Arguments $installArgs -PublicKey $publicKey
    if ($installExitCode -ne 0) { throw ('Вход не завершён. Нужен пароль пользователя сервера (сейчас: {0}), не панели хостинга и не защиты подключения. Проверьте письмо или панель хостинга; если пароль неизвестен — сбросьте его через хостинг. Причиной отказа также может быть запрет входа по паролю. Технические подробности выше; код {1}.' -f $Login, $installExitCode) }
    Write-Host ''
    Write-Host 'Этап 4. Проверка подключения'
    Write-Host 'Если откроется окно защиты подключения, введите её пароль. Пароль сервера здесь не нужен.'
    Write-Host 'Ниже появятся сведения о сервере.'
    $verifyExitCode = Test-SavedConnection $keyPath
    if ($verifyExitCode -ne 0) { throw 'Посмотрите сообщение выше: проверка подключения не прошла. Прежний вход по паролю сохранён.' }
    if ($usePending) {
        # Replace metadata atomically only after a verified login with the candidate key.
        $metadata | Add-Member -NotePropertyName activeKey -NotePropertyValue $pendingSlot -Force
        $metadata | Add-Member -NotePropertyName pendingKey -NotePropertyValue $null -Force
        Save-ProfileMetadata $metadata $metadataPath
        Write-Host 'Новое подключение сохранено. Прежние файлы оставлены для восстановления.'
    }
    Write-Host ('Готово: вход на сервер проверен. Сервер: ' + $displayName)
    $script:setupOutcome = 'verified'
    Request-VpsVpnSetup
    Start-RemoteCodex
} catch {
    Write-Host ''
    Write-Host 'Настройка остановлена. Сохранённые данные не удалялись.'
    Write-Host ('Подробности: ' + $_.Exception.Message)
    Write-Host 'Прочитайте пояснение выше. Затем можно повторить запуск и выбрать тот же сервер.'
    $script:setupOutcome = 'error'
    $script:setupExitCode = 1
}
}
function Show-SetupResult {
    Write-Host ''
    Write-Host '=== Результат ==='
    switch ($script:setupOutcome) {
        'verified' { Write-Host 'Успех: подключение по SSH проверено.' }
        'codex-installed' { Write-Host 'Codex установлен на сервере. Для чата осталось войти в аккаунт; выберите сервер повторно.' }
        'codex-ready' { Write-Host 'Codex установлен, вход в аккаунт проверен. Чат можно открыть повторным выбором сервера.' }
        'applications-ready' { Write-Host 'Выбранные приложения готовы на сервере. Вход в аккаунты выполняется в их окнах.' }
        'changed' { Write-Host 'Защита подключения изменена. Вход после изменения не проверялся.' }
        'removed' { Write-Host 'Сервер убран из списка. VPS и файлы подключения сохранены.' }
        'error' { Write-Host 'Ошибка: настройка не завершена. Причина показана выше.' }
        default { Write-Host 'Настройка остановлена. Пояснение показано выше.' }
    }
    Write-Host 'Выбранные приложения устанавливаются на сервер. VPN Windows не изменяется.'
}

$nextServerAddress = $ServerAddress
$nextLogin = $Login
$nextProfileName = $ProfileName
do {
    Start-ConnectionSetup -ServerAddress $nextServerAddress -Login $nextLogin -ProfileName $nextProfileName -DataDir $DataDir
    Show-SetupResult
    if (-not $Launcher) { break }
    Write-Host ''
    Write-Host '1. Вернуться к списку серверов'
    Write-Host '0. Закрыть окно'
    do {
        $nextAction = (Read-Host 'Введите 1 или 0. Enter оставляет окно открытым').Trim()
        if ($nextAction -notin @('0', '1')) { Write-Host 'Окно остаётся открытым. Для закрытия введите 0.' }
    } until ($nextAction -in @('0', '1'))
    if ($nextAction -eq '0') { break }
    $nextServerAddress = $null
    $nextLogin = $null
    $nextProfileName = $null
} while ($true)
exit $script:setupExitCode
