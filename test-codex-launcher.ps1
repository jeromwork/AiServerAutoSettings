$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'setup-vps-ssh.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count) { throw 'Parser failed' }
$wanted=@('Convert-SshArgument','Initialize-ManagedOutput','Start-ManagedComponent','Stop-ManagedComponent','Open-ServerDesktop','Invoke-CodexSession','Start-CodexTerminal','Start-RemoteCodex','Install-AgentApplications','Start-ProjectWindowsBridge','Get-ManagedComponentState','Select-ExecutionMode','Connect-ProjectFolders')
foreach($function in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)) {
    if($function.Name -in $wanted) { Invoke-Expression $function.Extent.Text.Replace('$PSScriptRoot', ("'" + $PSScriptRoot.Replace("'", "''") + "'")) }
}
$fixture=Join-Path $PSScriptRoot '.offline codex launcher fixture'
if(Test-Path -LiteralPath $fixture) { throw 'Fixture already exists' }
[IO.Directory]::CreateDirectory($fixture)|Out-Null
try {
    # Real PS5.1 process/argv/managed lifecycle, with a harmless local child script.
    $child=Join-Path $fixture 'child with spaces.ps1'
    [IO.File]::WriteAllText($child, 'param([string]$Label); if($Label -ne "Русское имя с пробелами"){exit 8}; Write-Output ''{"state":"connected"}''; $line=[Console]::ReadLine(); if($line -ne ''stop''){exit 9}',(New-Object Text.UTF8Encoding($true)))
    $component=Start-ManagedComponent $child @('-Label','Русское имя с пробелами') 'connected'
    Stop-ManagedComponent $component
    [IO.File]::WriteAllText($child, 'Write-Output ''REMOTEAGENTS_DESKTOP_READY=127.0.0.1:43389''; $line=[Console]::ReadLine(); if($line -ne ''stop''){exit 9}',(New-Object Text.UTF8Encoding($true)))
    $component=Start-ManagedComponent $child @() 'desktop'
    Stop-ManagedComponent $component
    $marker=Join-Path $fixture 'drain-complete.txt'
    [IO.File]::WriteAllText($child, 'param([string]$Marker); Write-Output ''{"state":"connected"}''; for($i=0;$i -lt 10000;$i++){Write-Output ''{"state":"disconnected"}''}; if([Console]::ReadLine() -ne ''stop''){exit 9}; [IO.File]::WriteAllText($Marker,''done'')',(New-Object Text.UTF8Encoding($true)))
    $component=Start-ManagedComponent $child @('-Marker',$marker) 'connected'
    Stop-ManagedComponent $component
    if(-not(Test-Path -LiteralPath $marker)){throw 'Managed GUI status pipe blocked after readiness'}
    $script:calls=New-Object Collections.Generic.List[object]
    $script:stops=0; $script:components=0; $script:prepareFail=$false; $script:needAuth=$true; $script:authFail=$false; $script:authChoice='2';$script:executionChoice='1'
    function Invoke-ProfileSsh([string[]]$Arguments,[string]$PublicKey,[string]$InputText) {
        $script:calls.Add([pscustomobject]@{Arguments=$Arguments;InputText=$InputText})
        if($InputText) { [IO.File]::WriteAllText((Join-Path $fixture 'public-payload.sh'),$InputText,(New-Object Text.UTF8Encoding($false))); if($script:prepareFail){return 41};return 0 }
        $command=$Arguments[-1]
        if($command -match 'codex-session status') {if($script:needAuth){return 1};return 0}
        if($command -match 'codex-session auth-device') {if($script:authFail){return 7};$script:needAuth=$false;return 0}
        if($command -match 'codex-session chat') {return 0}
        throw 'Unexpected native call'
    }
    function Start-ManagedComponent([string]$File,[string[]]$Parameters,[string]$ReadyState){$script:components++;return [pscustomobject]@{File=$File;Parameters=$Parameters}}
    function Stop-ManagedComponent($Component){if($Component){$script:stops++}}
    function Confirm-Action {return $false}
    function Save-ProfileMetadata {$script:metadataWrites++}
    $script:serverActions=New-Object 'Collections.Generic.Queue[string]'
    function Read-Host([string]$Question) {
        if ($Question -eq 'Введите номер; Enter — рабочий стол') {if($script:serverActions.Count){return $script:serverActions.Dequeue()};return '2'}
        if ($Question -like 'Введите 0, чтобы закрыть*') {return '0'}
        if ($Question -like 'Место работы:*') {return $script:executionChoice}
        return $script:authChoice
    }
    $ServerAddress='203.0.113.10';$Login='root';$profileId='test-safe';$keyPath=Join-Path $fixture 'synthetic key'
    $script:sshExecutable='not-executed.exe';$script:askpassExecutable='not-executed-ui.exe'
    $common=@('-F',(Join-Path $fixture 'empty config'),'-l','root')
    $configPath=$common[1];$knownHostsPath=Join-Path $fixture 'known hosts'
    $metadata=[pscustomobject]@{bridgeWorkspace=$fixture;executionMode='1'};$metadataPath=Join-Path $fixture 'unused.json'
    # Exercise the real desktop hook callsite, with only its managed process mocked.
    $script:lastComponent=$null
    function Start-ManagedComponent([string]$File,[string[]]$Parameters,[string]$ReadyState){$script:components++;$script:lastComponent=[pscustomobject]@{File=$File;Parameters=$Parameters;ReadyState=$ReadyState};return $script:lastComponent}
    Open-ServerDesktop
    if($script:lastComponent.ReadyState -ne 'desktop' -or $script:lastComponent.Parameters -contains '-SetDesktopPassword' -or $script:lastComponent.Parameters -notcontains '-ManagedSession' -or $script:lastComponent.Parameters -notcontains '-AskpassExecutable'){throw 'SSH-only desktop hook argument contract failed'}
    $script:components=0;$script:stops=0
    # GUI bridge is confined to the ready replica; labels isolate computer/project.
    $script:calls.Clear()
    Start-ProjectWindowsBridge 'p-fixture' 'computer-one' $fixture $false $fixture | Out-Null
    $firstLabel=$script:lastComponent.Parameters[($script:lastComponent.Parameters.IndexOf('-DeviceLabel')+1)]
    if($script:lastComponent.Parameters -contains '-AllowShell' -or $script:lastComponent.Parameters[($script:lastComponent.Parameters.IndexOf('-Workspace')+1)] -ne $fixture){throw 'GUI bridge replica/shell scope failed'}
    & 'C:\Program Files\Git\bin\bash.exe' -n ((Join-Path $fixture 'public-payload.sh').Replace('\','/'))
    if($LASTEXITCODE){throw 'GUI bridge registration payload syntax failed'}
    Start-ProjectWindowsBridge 'p-fixture' 'computer-two' $fixture $true $fixture | Out-Null
    $secondLabel=$script:lastComponent.Parameters[($script:lastComponent.Parameters.IndexOf('-DeviceLabel')+1)]
    if($firstLabel -notmatch '^win-[a-f0-9]{28}$' -or $firstLabel -eq $secondLabel -or $script:lastComponent.Parameters -notcontains '-AllowShell'){throw 'GUI project/computer identity failed'}
    $before=$script:calls.Count
    $failed=$false;try{Start-ProjectWindowsBridge 'p-fixture' 'computer-one' (Join-Path $fixture 'not-ready') $false $fixture | Out-Null}catch{$failed=$true}
    if(-not $failed -or $script:calls.Count -ne $before){throw 'Missing replica reached bridge registration'}
    $script:components=0;$script:stops=0;$script:calls.Clear()
    Start-CodexTerminal
    if($script:setupOutcome -ne 'codex-ready' -or $script:components -ne 1 -or $script:stops -ne 1){throw 'Install/auth/chat lifecycle failed'}
    $chat=@($script:calls|Where-Object {$_.Arguments[-1] -match 'codex-session chat'})
    if($chat.Count -ne 1 -or $chat[0].Arguments -notcontains '-tt' -or $chat[0].Arguments[-1] -notmatch 'default_tools_approval_mode="prompt"'){throw 'Interactive chat flags failed'}
    $script:calls.Clear();Start-CodexTerminal
    if(@($script:calls|Where-Object {$_.Arguments[-1] -match 'codex-session auth-device'}).Count){throw 'Repeated auth despite ready status'}
    $script:calls.Clear();$script:prepareFail=$true;$before=$script:components
    $failed=$false;try{Start-CodexTerminal}catch{$failed=$true}
    if(-not $failed -or $script:components -ne $before -or $script:calls.Count -ne 1){throw 'Preparation failure did not stop safely'}
    $script:prepareFail=$false;$script:needAuth=$true;$script:authFail=$true;$script:authChoice='1';$before=$script:stops
    $failed=$false;try{Start-CodexTerminal}catch{$failed=$true}
    if(-not $failed -or $script:stops -ne ($before+1)){throw 'Browser cleanup on auth failure failed'}
    $script:needAuth=$false;$script:authFail=$false;$script:executionChoice='2';$script:metadataWrites=0;$before=$script:components;$script:calls.Clear()
    Start-CodexTerminal
    $serverChat=@($script:calls|Where-Object {$_.Arguments[-1] -match 'codex-session chat'})
    if($script:components -ne $before -or $metadata.executionMode -ne '2' -or $script:metadataWrites -ne 1 -or $serverChat[0].Arguments[-1] -notmatch 'enabled=false'){throw 'Server mode isolation/persistence failed'}
    $script:executionChoice='';Start-CodexTerminal
    if($script:components -ne $before -or $script:metadataWrites -ne 1){throw 'Saved server mode Enter failed'}
    $metadata.executionMode=$null;$script:metadataWrites=0;Start-CodexTerminal
    if($script:components -ne $before -or $metadata.executionMode -ne '2' -or $script:metadataWrites -ne 1){throw 'New profile did not default/persist server-only mode'}
    & 'C:\Program Files\Git\bin\bash.exe' -n ((Join-Path $fixture 'public-payload.sh').Replace('\','/'))
    if($LASTEXITCODE){throw 'Generated deployment payload syntax failed'}
    # Real application selection callsite, with SSH replaced by the same public-payload stub.
    foreach($choice in @('1','2','3')) {
        $script:calls.Clear(); Install-AgentApplications $choice
        $payload=$script:calls[0].InputText
        if($script:calls.Count -ne 1 -or $payload -notmatch 'AGENT_ACCOUNT_READY'){throw 'Common managed account preparation missing'}
        $hasCodex=$payload -match 'codex-package-\$target.tar.gz'
        $hasCodexApp=$payload -match 'CHATGPT_INSTALLED='
        $hasClaude=$payload -match 'CLAUDE_DESKTOP_INSTALLED='
        if($hasCodex -ne ($choice -in @('1','3')) -or $hasCodexApp -ne ($choice -in @('1','3')) -or $hasClaude -ne ($choice -in @('2','3'))){throw ('Wrong selected app bundle: '+$choice)}
        & 'C:\Program Files\Git\bin\bash.exe' -n ((Join-Path $fixture 'public-payload.sh').Replace('\','/'))
        if($LASTEXITCODE){throw 'Selected GUI bundle Bash syntax failed'}
    }
    function Connect-ProjectFolders {param($Agents,$Sessions)}
    $script:desktopOpens=0;$script:terminalOpens=0
    function Open-ServerDesktop {$script:desktopOpens++}
    function Start-CodexTerminal {$script:terminalOpens++}
    function Read-Host([string]$Question) {
        if($Question -like 'Выберите 1, 2 или 3*'){return $script:appChoice}
        if($Question -like 'Что открыть?*'){return $script:serverActions.Dequeue()}
        if($Question -like 'Место работы:*'){return '2'}
        throw 'Unexpected menu prompt'
    }
    foreach($choice in @('1','2','3','0')) {
        $script:appChoice=$choice;$script:serverActions.Clear();$script:calls.Clear();$before=$script:desktopOpens
        foreach($action in @('1','0')){$script:serverActions.Enqueue($action)}
        Start-RemoteCodex
        if($script:desktopOpens -ne ($before+1) -or $script:terminalOpens -ne 0 -or $script:calls.Count -ne [int]($choice -ne '0')){throw ('GUI-first menu/optional no-install failed: '+$choice)}
    }
    Write-Output 'PASS: PS5.1 parser/managed child/Unicode/desktop; CLI mode/auth cleanup; GUI Codex/Claude/both/no-install selection and Bash payloads. No SSH, RDP or real keys.'
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture)
    if($resolved -ne (Join-Path $PSScriptRoot '.offline codex launcher fixture')){throw 'Unsafe fixture cleanup'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
