[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$required=@('01-setup-ssh.cmd','setup-vps-ssh.ps1','ssh-password-ui.cs','Select-RemoteAgentsProjects.ps1','Connect-RemoteAgentsProject.ps1','Sync.Workspace.ps1','Sync.Runtime.ps1','Sync.Orchestrator.ps1','Start-RemoteSyncTunnel.ps1','Invoke-RemoteAgentsSsh.ps1','Invoke-RemoteSyncGuard.ps1','Agent.Handoff.ps1','server-agent-handoff.py','server-sync.py','server-sync-runtime.py','server-install-sync.sh','server-desktop.ps1','server-desktop-bootstrap.sh','server-desktop-audio.sh','server-browser.ps1','server-browser-bootstrap.sh','server-agent-user-v1.sh','server-codex-v1.sh','server-chatgpt.sh','server-claude-code.sh','server-claude-desktop.sh','server-devtools.sh','setup-happ.ps1','Get-CodexWindowsBridgeRegistration.ps1','Start-CodexWindowsBridge.ps1','windows-bridge-executor.ps1','codex-windows-bridge.py','codex-bridge-session.py')
$required+=@('project-console-input.cs','server_node_catalog.py','Start-RemotePreview.ps1','server-desktop-onboarding.py','server-happ.sh')
$required+='Windows.Paths.ps1'
$required+=@('Remote.Chat.ps1','server-chat.ps1','server-happier.sh')
foreach($name in $required){if(!(Test-Path -LiteralPath (Join-Path $root $name) -PathType Leaf)){throw "Missing runtime source: $name"}}
$files=@(Get-ChildItem -LiteralPath $root -File)
foreach($file in $files){
    if($file.Name -match '^(\.env|auth\.json|credentials|profile\.json|computer\.json|id_rsa|id_ed25519)' -or $file.Extension -in '.exe','.zip','.log','.png','.key','.pem','.p12','.jks','.keystore'){throw ('Forbidden package file: '+$file.Name)}
    if($file.Extension -in '.ps1','.py','.sh','.cs','.cmd','.md','.txt'){
        $text=[IO.File]::ReadAllText($file.FullName)
        # Source patterns are deliberately assembled so the check does not match itself.
        $userPath='(?i)[A-Z]:[\\/]'+'(?:Users|work)[\\/]'
        if($text -match $userPath){throw ('Absolute personal path: '+$file.Name)}
        if($text -match ('-----BEGIN '+'(?:[A-Z]+ )?PRIVATE KEY-----')){throw ('Private-key literal: '+$file.Name)}
        if($text -match ('(?:gh[pousr]_'+'[A-Za-z0-9]{20,}|sk-'+'[A-Za-z0-9]{24,})')){throw ('Token literal: '+$file.Name)}
    }
    if($file.Extension -eq '.ps1'){
        $tokens=$null;$errors=$null
        [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)|Out-Null
        if($errors){throw ('PowerShell parse failed: '+$file.Name)}
    }
}
$launcher=[IO.File]::ReadAllText((Join-Path $root '01-setup-ssh.cmd'))
if($launcher -notmatch 'powershell\.exe.*-STA.*setup-vps-ssh\.ps1'){throw 'Launcher must invoke Windows PowerShell STA'}
$manifest=Join-Path $root 'PACKAGE-MANIFEST.txt'
if(Test-Path -LiteralPath $manifest){
    foreach($name in [IO.File]::ReadAllLines($manifest)){if($name -and !(Test-Path -LiteralPath (Join-Path $root $name) -PathType Leaf)){throw ('Manifest entry missing: '+$name)}}
}
Write-Output ('PASS portable package: '+$required.Count+' runtime components; '+$files.Count+' reviewed source/document files; PowerShell syntax and privacy fence')
