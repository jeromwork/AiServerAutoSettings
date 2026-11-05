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

