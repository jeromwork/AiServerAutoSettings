[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$DataDir,[Parameter(Mandatory=$true)][string]$ProjectId,[Parameter(Mandatory=$true)][string]$HostId,[switch]$ManagedSession)
$ErrorActionPreference='Stop'
if(-not $ManagedSession){throw 'Подключайте проект из основной программы.'}
if($ProjectId -notmatch '\A[a-z0-9][a-z0-9_-]{0,63}\z' -or $HostId -notmatch '\A[a-z0-9][a-z0-9_-]{0,63}\z'){throw 'Неверная привязка проекта.'}
# Reuse the installer's bounded managed-process lifecycle, without executing its wizard.
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'setup-vps-ssh.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Не удалось загрузить компонент подключения.'}
foreach($name in @('Convert-SshArgument','Initialize-ManagedOutput','Start-ManagedComponent','Stop-ManagedComponent')){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if(-not $node){throw 'Неполный комплект программы.'}
    . ([scriptblock]::Create($node.Extent.Text))
}
Add-Type -TypeDefinition @'
using System;using System.Threading;
public static class ProjectManagedControl {public static volatile bool StopRequested;public static void Start(){var t=new Thread(()=>{Console.ReadLine();StopRequested=true;});t.IsBackground=true;t.Start();}}
'@
[ProjectManagedControl]::Start()
$moduleRoot=$PSScriptRoot
Import-Module (New-Module -Name RemoteAgentsProjectSync -ArgumentList $moduleRoot -ScriptBlock {
    param($root)
    . (Join-Path $root 'Sync.Workspace.ps1')
    . (Join-Path $root 'Sync.Runtime.ps1')
    . (Join-Path $root 'Sync.Orchestrator.ps1')
    Export-ModuleMember -Function *
}) -Force
$connection=[IO.File]::ReadAllText((Join-Path $DataDir 'ssh-transport.json'))|ConvertFrom-Json
$tunnels=New-Object 'Collections.Generic.List[object]'
$transport={param($request)& (Join-Path $moduleRoot 'Invoke-RemoteAgentsSsh.ps1') -Request $request -Connection $connection -DataDir $DataDir}.GetNewClosure()
$tunnel={param($request)
    $params=@('-VPSHost',$connection.serverAddress,'-VPSUser',$connection.login,'-IdentityFile',$connection.keyPath,'-KnownHostsFile',$connection.knownHostsPath,'-SSHConfig',$connection.configPath,'-SSHExecutable',$connection.sshExecutable,'-AskpassExecutable',$connection.askpassExecutable,'-LocalForwardPort',[string]$request.localForwardPort,'-ServerListenPort',[string]$request.serverListenPort,'-RemoteForwardPort',[string]$request.remoteForwardPort,'-WindowsListenPort',[string]$request.windowsListenPort,'-ManagedSession')
    $component=Start-ManagedComponent (Join-Path $moduleRoot 'Start-RemoteSyncTunnel.ps1') $params 'connected'
    $tunnels.Add($component)
    [pscustomobject]@{ok=$true;processId=$component.Process.Id}
}.GetNewClosure()
try{
    $barrier=Connect-RemoteSyncProject -DataDir $DataDir -ProjectId $ProjectId -HostId $HostId -SSHTransport $transport -TunnelHook $tunnel
    if(-not $barrier.ready -or -not $barrier.fresh){throw 'Рабочая копия ещё не совпадает с сервером. Повторите подключение; исходная папка не изменена.'}
    $barrier|Add-Member -NotePropertyName state -NotePropertyValue 'project-ready' -Force
    [Console]::WriteLine(($barrier|ConvertTo-Json -Compress))
    while(-not [ProjectManagedControl]::StopRequested){Start-Sleep -Milliseconds 200}
}catch{[Console]::Error.WriteLine(('Проект не подключён: '+$_.Exception.Message));exit 1}
finally{
    foreach($component in $tunnels){Stop-ManagedComponent $component}
    try{Stop-RemoteSyncWorker -DataDir $DataDir -ProjectId $ProjectId -HostId $HostId|Out-Null}catch{}
}
