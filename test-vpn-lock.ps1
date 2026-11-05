$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$source = Join-Path $PSScriptRoot 'VpnLock.ps1'
$parseErrors = $null; $tokens = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join '; ') }
foreach ($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('vpn-lock-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$stateRoot = $fixture; $statePath = Join-Path $fixture 'state.json'; $backupPath = Join-Path $fixture 'before.wfw'
$programDirectory = Join-Path $fixture 'Happ'
[void][IO.Directory]::CreateDirectory($programDirectory)
$programPath = Join-Path $programDirectory 'happd.exe'
[IO.File]::WriteAllText($programPath,'fixture')
$group = 'RemoteAgents VPN Lock'; $ServerAddress = '109.199.110.63'; $ServerPort = 8443; $TunnelInterfaceAlias = ''
$script:rules = @(); $script:blocked = $false; $script:mutations = 0; $script:imports = 0; $script:exports = 0
$script:hasTunnel = $false; $script:publicIp = $ServerAddress; $script:failRule = $false
function Initialize-StateDirectory { }
function Get-NetIPAddress {
    if ($script:hasTunnel) { [pscustomobject]@{IPAddress='172.19.0.1';AddressState='Preferred';InterfaceAlias='happ-xray';InterfaceIndex=7} }
}
function Get-NetRoute { [pscustomobject]@{DestinationPrefix='0.0.0.0/0'} }
function Get-VpnPublicAddress { $script:publicIp }
function Get-CimInstance { [pscustomobject]@{State='Running';PathName=$programPath} }
function Get-AuthenticodeSignature { [pscustomobject]@{Status='Valid'} }
function Get-NetFirewallProfile {
    1..3 | ForEach-Object { [pscustomobject]@{Enabled='True';DefaultOutboundAction=$(if ($script:blocked) {'Block'} else {'Allow'});DisabledInterfaceAliases=@()} }
}
function Get-NetFirewallRule {
    [CmdletBinding()]param($PolicyStore,$Direction,$Action,$Enabled,$Group)
    foreach ($rule in $script:rules) { if ((-not $Group -or $rule.Group -eq $Group) -and (-not $Enabled -or $rule.Enabled)) { $rule } }
}
function Set-NetFirewallProfile { $script:blocked=$true; $script:mutations++ }
function Disable-NetFirewallRule {
    [CmdletBinding()]param([Parameter(ValueFromPipeline)]$InputObject)
    process { $InputObject.Enabled=$false; $script:mutations++ }
}
function Remove-NetFirewallRule {
    [CmdletBinding()]param([Parameter(ValueFromPipeline)]$InputObject)
    process { $script:rules=@($script:rules | Where-Object Name -ne $InputObject.Name); $script:mutations++ }
}
function New-NetFirewallRule {
    [CmdletBinding()]param($PolicyStore,$Name,$DisplayName,$Group,$Direction,$Action,$Profile,$InterfaceAlias,$Program,$Protocol,$RemoteAddress,$RemotePort,$Service,$LocalPort)
    if ($script:failRule) { throw 'Simulated rule failure' }
    $rule=[pscustomobject]@{Name=$Name;Group=$Group;Enabled=$true;PolicyStoreSourceType='Local';InterfaceAlias=$InterfaceAlias;RemoteAddress=$RemoteAddress;RemotePort=$RemotePort;Protocol=$Protocol}
    $script:rules += $rule; $script:mutations++
}
function Invoke-Netsh([string[]]$Arguments) {
    if ($Arguments[1] -eq 'export') { $script:exports++; [IO.File]::WriteAllText($backupPath,'saved-policy') }
    elseif ($Arguments[1] -eq 'import') { $script:imports++; $script:rules=@(); $script:blocked=$false }
    else { throw 'Unexpected netsh operation' }
}
function Assert-True($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Expect-Failure([scriptblock]$Body,[string]$Text) {
    $caught=$null
    try { & $Body } catch { $caught=$_.Exception.Message }
    Assert-True ($caught -and $caught.Contains($Text)) ('Expected failure: ' + $Text + '; actual: ' + $caught)
}
try {
    Expect-Failure { Enable-VpnLock } 'Connect HAPP'
    Assert-True ($script:mutations -eq 0 -and $script:exports -eq 0) 'Missing tunnel changed firewall'
    $script:hasTunnel=$true; $script:publicIp='192.0.2.1'
    Expect-Failure { Enable-VpnLock } 'does not exit'
    Assert-True ($script:mutations -eq 0 -and $script:exports -eq 0) 'Wrong IP changed firewall'
    $script:publicIp=$ServerAddress
    $script:rules=@([pscustomobject]@{Name='Old';Group='Other';Enabled=$true;PolicyStoreSourceType='Local'})
    Enable-VpnLock
    Assert-LockActive
    Assert-True ((Get-LockState).Phase -eq 'Enabled') 'Enabled state missing'
    Assert-True ($script:rules.Where({$_.Name -eq 'Old' -and $_.Enabled}).Count -eq 0) 'Old outbound allow remained active'
    $transport=@($script:rules | Where-Object Name -eq 'RemoteAgents-VpnLock-Transport')[0]
    Assert-True ($transport.RemoteAddress -eq $ServerAddress -and $transport.RemotePort -eq 8443 -and $transport.Protocol -eq 'TCP') 'Transport is not scoped to the fixed endpoint'
    Enable-VpnLock
    Assert-True ($script:exports -eq 1) 'Repeated enable overwrote the recovery snapshot'
    [IO.File]::WriteAllText($backupPath,'tampered')
    Expect-Failure { Disable-VpnLock } 'missing or changed'
    Assert-True ($script:imports -eq 0 -and $script:blocked) 'Invalid backup unblocked traffic'
    [IO.File]::WriteAllText($backupPath,'saved-policy')
    Disable-VpnLock
    Assert-True ($script:imports -eq 1 -and -not $script:blocked -and (Get-LockState).Phase -eq 'Disabled') 'Restore failed'
    $script:failRule=$true
    Expect-Failure { Enable-VpnLock } 'No automatic unblock'
    Assert-True ($script:blocked -and $script:imports -eq 1 -and (Get-LockState).Phase -eq 'NeedsAttention') 'Failure silently restored ordinary internet'
    Disable-VpnLock
    Assert-True (-not $script:blocked -and $script:imports -eq 2) 'Recovery after partial activation failed'
    Write-Host 'PASS: parse, missing tunnel, wrong IP, endpoint scope, repeated ON, invalid backup, restore, partial-failure recovery.'
} finally {
    foreach ($name in @('state.json','state.pending.json','before.wfw','happd.exe')) {
        $path=Join-Path $fixture $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    Remove-Item -LiteralPath $programPath -Force
    [IO.Directory]::Delete($programDirectory)
    [IO.Directory]::Delete($fixture)
}
