$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'setup-vps-ssh.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Setup parser failed'}
foreach($name in @('Start-RemoteCodex','Start-ConnectionSetup','Initialize-ServerWorkspace','Get-SshTransportConfig','Select-SshTransport')){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($node.Extent.Text.Replace('$PSScriptRoot',("'"+$PSScriptRoot.Replace("'","''")+"'"))))
}
function Assert($Value,$Message){if(!$Value){throw $Message}}
$script:lines=New-Object 'Collections.Generic.List[string]'
function Write-Host {param($Object);$script:lines.Add([string]$Object)}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ra-quick-entry-'+[guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($fixture)
    # Inspect the real baseline script. No native server operation is executed.
    $common=@();$keyPath='fixture';$ServerAddress='fixture.invalid'
    function Invoke-ProfileSsh {param($Arguments,$InputText,$Activity);$script:baseline=$InputText;return 0}
    Initialize-ServerWorkspace
    Assert ($script:baseline -match 'AGENT_ACCOUNT_READY' -and $script:baseline -match '--no-remove python3 git curl ca-certificates' -and $script:baseline -notmatch 'codex-package|claude-desktop') 'Baseline prepared an AI app or omitted sync prerequisites'
    $file=Join-Path $fixture 'baseline.sh';[IO.File]::WriteAllText($file,$script:baseline,(New-Object Text.UTF8Encoding($false)))
    & 'C:\Program Files\Git\bin\bash.exe' -n $file.Replace('\','/')
    Assert ($LASTEXITCODE -eq 0) 'Baseline Bash payload invalid'
    function Reset-Entry {
        $script:installs=0;$script:prepares=0;$script:desktops=0;$script:apps=0;$script:stops=0;$script:connects=New-Object 'Collections.Generic.List[object]'
        $script:steps=New-Object 'Collections.Generic.Queue[string]';$script:savedNames=@('first')
    }
    function Initialize-ServerWorkspace {$script:prepares++}
    function Get-SavedProjectNames {$script:savedNames}
    function Install-AgentApplications {param($Choice);$script:installs++}
    function Select-AgentApplications {return '1'}
    function Select-ExecutionMode {throw 'Unexpected mandatory mode prompt'}
    function Show-ServerApplications {}
    function Save-ProfileMetadata {}
    function Open-ServerDesktop {param([switch]$KeepOpen,$Agents);Assert ([bool]$KeepOpen) 'RDP lifetime not managed';$script:desktops++;$script:desktopAgents=$Agents;[pscustomobject]@{Process=[pscustomobject]@{HasExited=$false}}}
    function Open-ServerAgentApplications {param($Agents);$script:apps++}
    function Stop-ManagedComponent {param($Component);if($Component){$script:stops++}}
    function Connect-ProjectFolders {param($Agents,$Sessions,[switch]$ReuseSelection)
        Assert ($script:stops -eq 0) 'Existing desktop/project stopped while adding folders'
        $script:connects.Add([pscustomobject]@{agents=$Agents;reuse=[bool]$ReuseSelection})
        $Sessions['fixture']=[pscustomobject]@{Sync=[pscustomobject]@{State='ready'};Bridge=$null}
        $script:savedNames=@('first','added')
    }
    function Read-Host {param($Question);Assert ($Question -like 'Что открыть?*') 'Unexpected startup install/mode prompt';if(!$script:steps.Count){throw 'Missing fixture action'};$script:steps.Dequeue()}
    $metadataPath='fixture'
    Reset-Entry;$metadata=[pscustomobject]@{agentApplications='1';executionMode='1'}
    foreach($step in @('','2','3','13','0')){$script:steps.Enqueue($step)}
    Start-RemoteCodex
    Assert ($script:installs -eq 0 -and $script:prepares -eq 1 -and $script:desktops -eq 1 -and $script:desktopAgents -eq '0' -and $script:apps -eq 1) 'Warm RDP path reinstalled apps, reopened desktop or launched an unwanted agent'
    Assert ($script:connects.Count -eq 3 -and $script:connects[0].reuse -and !$script:connects[1].reuse -and $script:connects[2].reuse) 'Automatic saved connection, edit and explicit reconnect not independent'
    Assert (($script:lines -join "`n") -match 'сохранённые папки \(2\): first, added') 'Saved-folder names not refreshed in main menu'
    Reset-Entry;$metadata=[pscustomobject]@{agentApplications='0';executionMode='2'}
    foreach($step in @('3','11','0')){$script:steps.Enqueue($step)}
    Start-RemoteCodex
    Assert ($script:connects.Count -eq 2 -and $script:connects[0].agents -eq '0' -and $script:connects[1].agents -eq '1' -and $script:connects[1].reuse -and $script:installs -eq 1) 'Sync-only flow or later explicit agent configuration failed'
    # Real saved-server entry with metadata/key-path fixtures and SSH stubbed.
    $profiles=Join-Path $fixture 'profiles';$id='0123456789abcdef0123456789abcdef';$directory=Join-Path $profiles $id
    [void][IO.Directory]::CreateDirectory($directory)
    [IO.File]::WriteAllText((Join-Path $directory 'profile.json'),(@{version=1;profile=$id;displayName='Fixture';serverAddress='fixture.invalid';login='root';activeKey='fixture'}|ConvertTo-Json))
    foreach($name in @('id_ed25519','id_ed25519.pub','known_hosts','ssh_config')){[IO.File]::WriteAllText((Join-Path $directory $name),'')}
    function Test-WindowsRuntime {}
    function Test-SshEndpoint {param($Address,$User,$Ports);foreach($Port in $Ports){[pscustomobject]@{Port=$Port;Ready=$true;TimedOut=$false}}}
    function Get-KeyDirectory {param($Slot);$directory}
    function Test-SavedConnection {param($Key);$script:sshChecks++;return 0}
    function Assert-SupportedServer {$script:osChecks++}
    function Show-ServerApplications {throw 'Unexpected component inventory on warm startup'}
    function Start-RemoteCodex {$script:menus++}
    $script:answers=New-Object 'Collections.Generic.Queue[string]'
    function Read-Host {param($Question);if(!$script:answers.Count){throw ('Unexpected warm-entry prompt: '+$Question)};$script:answers.Dequeue()}
    $script:sshChecks=0;$script:osChecks=0;$script:menus=0
    $script:answers.Enqueue('');Start-ConnectionSetup -DataDir $profiles
    Assert ($script:menus -eq 1 -and $script:sshChecks -eq 1 -and $script:osChecks -eq 1 -and !$script:answers.Count) 'Enter server selection did not directly reach action menu'
    $script:answers.Enqueue('M1');$script:answers.Enqueue('0');Start-ConnectionSetup -DataDir $profiles
    Assert ($script:menus -eq 1 -and $script:sshChecks -eq 1 -and !$script:answers.Count) 'Explicit SSH maintenance did not preserve old flow'
    $script:probed=New-Object 'Collections.Generic.List[int]'
    function Test-SshEndpoint {param($Address,$User,$Ports);foreach($Port in $Ports){$script:probed.Add($Port);[pscustomobject]@{Port=$Port;Ready=($Port -eq 443);TimedOut=($Port -eq 22)}}}
    function Save-ProfileMetadata {param($Metadata,$Path);[IO.File]::WriteAllText($Path,($Metadata|ConvertTo-Json))}
    $script:answers.Enqueue('');Start-ConnectionSetup -DataDir $profiles
    Assert (($script:probed -join ',') -eq '22,443,2222,2022' -and $script:menus -eq 2) 'Failed port 22 did not fall back to SSH on 443'
    $saved=[IO.File]::ReadAllText((Join-Path $directory 'profile.json'))|ConvertFrom-Json
    Assert ($saved.sshPort -eq 443) 'Working SSH port was not persisted'
    Assert ([IO.File]::ReadAllText((Join-Path $directory 'ssh_config')) -match 'Port 443') 'Child SSH processes will not inherit the selected port'
    $script:probed.Clear();$script:answers.Enqueue('');Start-ConnectionSetup -DataDir $profiles
    Assert (($script:probed -join ',') -eq '443,22,2222,2022' -and $script:menus -eq 3) 'Saved port did not retain priority alongside fallback ports'
    $saved.sshPort=0
    Save-ProfileMetadata $saved (Join-Path $directory 'profile.json')
    function Test-SshEndpoint {param($Address,$User,$Ports);foreach($Port in $Ports){$script:probed.Add($Port);[pscustomobject]@{Port=$Port;Ready=($Port -eq 2022);TimedOut=($Port -ne 2022)}}}
    $script:probed.Clear();$script:answers.Enqueue('');Start-ConnectionSetup -DataDir $profiles
    Assert (($script:probed -join ',') -eq '22,443,2222,2022' -and $script:menus -eq 4) 'Additional SSH ports were not checked in order'
    $saved=[IO.File]::ReadAllText((Join-Path $directory 'profile.json'))|ConvertFrom-Json
    Assert ($saved.sshPort -eq 2022) 'Additional working port was not persisted'
    # A blocked direct route must switch all components to the verified relay.
    $script:sshExecutable=Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
    $relayConfig=Join-Path $fixture 'relay config.conf'
    [IO.File]::WriteAllText($relayConfig,'Host fixture-relay')
    $script:routes=New-Object 'Collections.Generic.List[string]'
    function Test-SshEndpoint {
        param($Address,$User,$Ports,$TransportConfig='NUL')
        $script:routes.Add($TransportConfig)
        if ($TransportConfig -ne 'NUL') {
            $probe=[IO.File]::ReadAllText($TransportConfig)
            Assert ($probe -match 'StrictHostKeyChecking=yes' -and $probe.Contains($relayConfig.Replace('\','/'))) 'Relay probe omitted pinned host trust or its quoted config path'
        }
        foreach($Port in $Ports){$script:probed.Add($Port);[pscustomobject]@{Port=$Port;Ready=($TransportConfig -ne 'NUL' -and $Port -eq 443);TimedOut=$true}}
    }
    $script:answers.Enqueue('');Start-ConnectionSetup -DataDir $profiles -SSHJumpHost fixture-relay -SSHJumpConfig $relayConfig
    Assert ($script:menus -eq 5 -and $script:routes.Count -eq 2 -and $script:routes[0] -eq 'NUL') 'Blocked direct SSH did not fall back exactly once'
    $saved=[IO.File]::ReadAllText((Join-Path $directory 'profile.json'))|ConvertFrom-Json
    Assert ($saved.sshJumpHost -eq 'fixture-relay' -and $saved.sshJumpConfig -eq $relayConfig -and $saved.sshPort -eq 443) 'Relay settings were not persisted'
    $routedConfig=[IO.File]::ReadAllText((Join-Path $directory 'ssh_config'))
    Assert ($routedConfig -match 'ProxyCommand .* -W %h:%p fixture-relay' -and $routedConfig -match 'Port 443') 'Desktop and child components did not inherit the selected relay'
    Assert (@(Get-ChildItem -LiteralPath $directory -Filter 'transport-probe-*').Count -eq 0) 'Temporary relay config leaked'
    $script:routes.Clear();$script:probed.Clear();$script:answers.Enqueue('');Start-ConnectionSetup -DataDir $profiles -SSHPort 443
    Assert ($script:menus -eq 6 -and $script:routes.Count -eq 2 -and ($script:probed -join ',') -eq '443,443') 'Saved relay route or explicit port failed on a repeated launch'
    # Failed routes must preserve the last working configuration and metadata.
    function Test-SshEndpoint {param($Address,$User,$Ports,$TransportConfig='NUL');foreach($Port in $Ports){[pscustomobject]@{Port=$Port;Ready=$false;TimedOut=$true}}}
    $before=[IO.File]::ReadAllText((Join-Path $directory 'profile.json'))
    $script:answers.Enqueue('');Start-ConnectionSetup -DataDir $profiles
    Assert ($script:menus -eq 6 -and $script:setupOutcome -eq 'error') 'Unavailable relay was reported as successful'
    Assert ([IO.File]::ReadAllText((Join-Path $directory 'ssh_config')) -ceq $routedConfig) 'Failed routes replaced the working config'
    Assert ([IO.File]::ReadAllText((Join-Path $directory 'profile.json')) -ceq $before) 'Failed routes changed the saved metadata'
    Assert (@(Get-ChildItem -LiteralPath $directory -Filter 'transport-probe-*').Count -eq 0) 'Failed relay probe config leaked'
    # Reject unexpected executable content before any SSH process is started.
    $script:tamperSshCalls=0
    function Test-SshEndpoint {$script:tamperSshCalls++;throw 'Tampered config reached SSH'}
    [IO.File]::WriteAllText((Join-Path $directory 'ssh_config'),$routedConfig.Replace(' -W %h:%p ',' -o ProxyCommand=unexpected -W %h:%p '))
    $script:answers.Enqueue('');Start-ConnectionSetup -DataDir $profiles
    Assert ($script:menus -eq 6 -and $script:tamperSshCalls -eq 0 -and $script:setupOutcome -eq 'error') 'Unexpected proxy command was accepted'
    [IO.File]::WriteAllText((Join-Path $directory 'ssh_config'),$routedConfig)
    # A recovered direct route takes precedence and retains the backup settings.
    $script:routes.Clear()
    function Test-SshEndpoint {
        param($Address,$User,$Ports,$TransportConfig='NUL');$script:routes.Add($TransportConfig)
        foreach($Port in $Ports){[pscustomobject]@{Port=$Port;Ready=($Port -eq 22);TimedOut=$false}}
    }
    $script:answers.Enqueue('');Start-ConnectionSetup -DataDir $profiles
    Assert ($script:menus -eq 7 -and $script:routes.Count -eq 1 -and $script:routes[0] -eq 'NUL') 'Recovered direct route still used the relay'
    Assert ([IO.File]::ReadAllText((Join-Path $directory 'ssh_config')) -notmatch 'ProxyCommand') 'Recovered direct route kept the proxy command'
    $saved=[IO.File]::ReadAllText((Join-Path $directory 'profile.json'))|ConvertFrom-Json
    Assert ($saved.sshJumpHost -eq 'fixture-relay' -and $saved.sshPort -eq 22) 'Direct recovery lost the saved backup'
    foreach($badAlias in @('-bad','relay another','relay;command')) {
        $rejected=$false
        try { Get-SshTransportConfig 443 $badAlias $relayConfig | Out-Null } catch { $rejected=$true }
        Assert $rejected 'Unsafe relay alias accepted'
    }
    $script:probed.Clear();$script:answers.Enqueue('M1');$script:answers.Enqueue('0');Start-ConnectionSetup -DataDir $profiles
    Assert ($script:probed.Count -eq 0) 'Offline maintenance unexpectedly attempted a network connection'
    function Confirm-Action {param($Question,[switch]$DefaultNo);throw 'Direct deletion must not ask for confirmation'}
    $script:answers.Enqueue('д1');Start-ConnectionSetup -DataDir $profiles
    Assert (!(Test-Path -LiteralPath $directory) -and $script:probed.Count -eq 0) 'Direct removal did not delete the complete profile offline'
    Assert (Test-Path -LiteralPath $profiles) 'Removal deleted the profiles root'
    Microsoft.PowerShell.Utility\Write-Output 'PASS: warm entry, SSH relay fallback and saved repeat launch, direct recovery, failed-route preservation, proxy validation, offline maintenance and baseline Bash syntax'
}finally{
    $resolved=[IO.Path]::GetFullPath($fixture);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe quick-entry fixture cleanup'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
