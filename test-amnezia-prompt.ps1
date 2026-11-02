$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'setup-vps-ssh.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$prompt = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Request-VpsVpnSetup' }, $true)
if (-not $prompt) { throw 'VPN prompt function missing' }
Invoke-Expression $prompt.Extent.Text
function Open-VpsVpn { $script:vpnCalls++ }
function Read-Host { param($Prompt) $script:answers.Dequeue() }
function Write-Host { param($Object) }
foreach ($case in @(
    @{ Name = 'yes'; Answers = @('1'); Expected = 1 },
    @{ Name = 'no'; Answers = @('2'); Expected = 0 },
    @{ Name = 'enter'; Answers = @(''); Expected = 0 },
    @{ Name = 'invalid then no'; Answers = @('wrong', '2'); Expected = 0 }
)) {
    $script:answers = New-Object System.Collections.Queue
    foreach ($answer in $case.Answers) { $script:answers.Enqueue($answer) }
    $script:vpnCalls = 0
    Request-VpsVpnSetup
    if ($script:vpnCalls -ne $case.Expected -or $script:answers.Count -ne 0) { throw ('Failed: ' + $case.Name) }
    Write-Output ('PASS: ' + $case.Name)
}
$setup = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-ConnectionSetup' }, $true)
$commands = @($setup.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Request-VpsVpnSetup' }, $true))
if ($commands.Count -ne 0) { throw 'VPN must not precede agent setup' }
$agents = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-RemoteCodex' }, $true)
if ($agents.Extent.Text.IndexOf('Request-VpsVpnSetup') -lt $agents.Extent.Text.IndexOf("Read-Host 'Что открыть?")) { throw 'VPN must remain an explicit server-menu action' }
if (-not $setup.Extent.Text.Contains("if (`$action -eq '5') { Open-VpsVpn; return }")) { throw 'Standalone VPN menu entry missing' }
Write-Output ('PASS: setup parse, both verified paths and standalone VPN menu (PowerShell ' + $PSVersionTable.PSVersion + ')')

# Exercise the Amnezia handoff without launching apps or making SSH connections.
$openVpn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Open-VpsVpn' }, $true)
Invoke-Expression $openVpn.Extent.Text
$quote = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Convert-SshArgument' }, $true)
Invoke-Expression $quote.Extent.Text
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('vpn-flow-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$hook = Join-Path $fixture 'setup-amnezia.ps1'
try {
    foreach ($case in @(
        @{ Status = 'ClientReady'; SshExit = 0; Waits = 0; Checks = 1; Throws = $false },
        @{ Status = 'ClientReady'; SshExit = 1; Waits = 0; Checks = 1; Throws = $true },
        @{ Status = 'ClientInstallSkipped'; SshExit = 0; Waits = 0; Checks = 0; Throws = $false },
        @{ Status = 'InstallInProgress'; SshExit = 0; Waits = 0; Checks = 0; Throws = $false },
        @{ Status = 'NeedsManualClientInstall'; SshExit = 0; Waits = 0; Checks = 0; Throws = $false }
    )) {
        [IO.File]::WriteAllText($hook, ('param($ProfileDirectory,[switch]$ClientOnly); if(-not $ClientOnly){throw ''GUI mode requested''}; [pscustomobject]@{ ClientPath=''fixture-client.exe''; Status = ''' + $case.Status + ''' }'))
        & {
            $profileDirectory = $fixture
            $profileId = '0123456789abcdef0123456789abcdef'
            $ServerAddress = '203.0.113.5'
            $keyPath = 'fixture-key-not-read'
            $script:answers = New-Object System.Collections.Queue
            if ($case.Waits) { $script:answers.Enqueue('') }
            $script:sshChecks = 0
            function Join-Path { param($Path, $ChildPath); if($ChildPath -eq 'setup-amnezia.ps1'){return $hook}; [IO.Path]::Combine($Path,$ChildPath) }
            function Protect-NewDirectory { param($Path) }
            function Get-AuthenticodeSignature { param($LiteralPath); [pscustomobject]@{Status='Valid'} }
            $script:imports = 0
            function Start-Process { param($FilePath,$ArgumentList); if($ArgumentList -notmatch '^--import '){throw 'Manual client setup requested'}; $script:imports++ }
            function Invoke-ProfileSsh {
                param($Arguments,$InputText,$OutputPath)
                if ($script:answers.Count -ne 0) { throw 'SSH ran before the user returned from Amnezia' }
                $script:sshChecks++
                [IO.File]::WriteAllText($OutputPath,"[Interface]`nPrivateKey = fixture-not-a-key`nEndpoint = 203.0.113.5:51820`n")
                return $case.SshExit
            }
            $failed = $false
            try { Open-VpsVpn } catch { $failed = $true }
            if ($failed -ne $case.Throws -or $script:sshChecks -ne $case.Checks -or $script:answers.Count -ne 0) {
                throw ('VPN handoff failed: ' + $case.Status + ', SSH exit ' + $case.SshExit)
            }
            if($script:imports -ne [int]($case.Status -eq 'ClientReady' -and $case.SshExit -eq 0)){throw 'Import must occur only after successful server setup'}
        }
        Write-Output ('PASS: VPN handoff ' + $case.Status + ', SSH exit ' + $case.SshExit)
    }
} finally {
    if ([IO.File]::Exists($hook)) { [IO.File]::Delete($hook) }
    $vpnDirectory=[IO.Path]::Combine($fixture,'vpn')
    $configFile=[IO.Path]::Combine($vpnDirectory,'amnezia.conf')
    if([IO.File]::Exists($configFile)){[IO.File]::Delete($configFile)}
    if([IO.Directory]::Exists($vpnDirectory)){[IO.Directory]::Delete($vpnDirectory)}
    [IO.Directory]::Delete($fixture)
}
