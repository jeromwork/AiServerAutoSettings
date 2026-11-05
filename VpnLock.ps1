#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Enable','Disable','Status')][string]$Action = 'Status',
    [string]$ServerAddress = '109.199.110.63',
    [ValidateRange(1,65535)][int]$ServerPort = 8443,
    [string]$TunnelInterfaceAlias,
    [switch]$Elevated,
    [switch]$ShowResult
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$group = 'RemoteAgents VPN Lock'
$stateRoot = Join-Path $env:ProgramData 'RemoteAgents-VpnLock'
$statePath = Join-Path $stateRoot 'state.json'
$backupPath = Join-Path $stateRoot 'before.wfw'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Netsh([string[]]$Arguments) {
    $output = & "$env:SystemRoot\System32\netsh.exe" @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('Windows Firewall operation failed: ' + ($output -join ' ')) }
}

function Get-VpnPublicAddress([string]$BindAddress) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path -LiteralPath $curl)) { throw 'Windows curl.exe is required to check the VPN address.' }
    $arguments = @('--silent','--show-error','--fail','--noproxy','*',
        '--connect-timeout','3','--max-time','5','--ipv4')
    if ($BindAddress) { $arguments += @('--interface',$BindAddress) }
    $output = & $curl @arguments 'https://api.ipify.org' 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'The VPN address check failed. Protection was not confirmed.' }
    return (($output -join '').Trim())
}

function Get-VerifiedTunnel([string]$RequestedAlias, [string]$ExpectedAddress) {
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.InterfaceAlias -like 'happ*' -and $_.AddressState -eq 'Preferred' })
    if ($RequestedAlias) { $addresses = @($addresses | Where-Object { $_.InterfaceAlias -eq $RequestedAlias }) }
    if ($addresses.Count -ne 1) {
        throw 'Connect HAPP to this server first. A single managed VPN interface must be available.'
    }
    $tunnel = $addresses[0]
    $routes = @(Get-NetRoute -AddressFamily IPv4 -InterfaceIndex $tunnel.InterfaceIndex -ErrorAction Stop)
    $prefixes = @($routes | ForEach-Object { $_.DestinationPrefix })
    if ('0.0.0.0/0' -notin $prefixes -and
        -not ('0.0.0.0/1' -in $prefixes -and '128.0.0.0/1' -in $prefixes)) {
        throw 'Disable split tunneling in HAPP first. A full IPv4 tunnel is required.'
    }
    if ((Get-VpnPublicAddress $tunnel.IPAddress) -ne $ExpectedAddress) {
        throw 'The VPN does not exit through the selected server. No firewall changes were made.'
    }
    return $tunnel
}

function Initialize-StateDirectory {
    if (Test-Path -LiteralPath $stateRoot) {
        $item = Get-Item -LiteralPath $stateRoot -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not $item.PSIsContainer) {
            throw 'The firewall backup directory is not a normal directory.'
        }
    } else { [void][IO.Directory]::CreateDirectory($stateRoot) }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl',
            'ContainerInherit,ObjectInherit','None','Allow')
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $stateRoot -AclObject $acl
    foreach ($path in @($statePath,$backupPath,(Join-Path $stateRoot 'state.pending.json'))) {
        if ((Test-Path -LiteralPath $path) -and
            ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'A firewall backup file is a reparse point.'
        }
    }
}

function Write-LockState($State) {
    $temporary = Join-Path $stateRoot 'state.pending.json'
    [IO.File]::WriteAllText($temporary,($State | ConvertTo-Json -Depth 4),
        (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $statePath -Force
}

function Get-LockState {
    foreach ($path in @($stateRoot,$statePath)) {
        if ((Test-Path -LiteralPath $path) -and
            ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'The protection state path is a reparse point.'
        }
    }
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
    return (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json)
}

function Assert-FirewallPolicy {
    $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
    if ($profiles.Count -ne 3) { throw 'Unable to verify all Windows Firewall profiles.' }
    foreach ($profile in $profiles) {
        $excluded = @($profile.DisabledInterfaceAliases | Where-Object { $_ -and $_ -ne 'NotConfigured' })
        if ($excluded.Count) { throw 'An interface is excluded from Windows Firewall. Protection cannot be enabled safely.' }
    }
    $managed = @(Get-NetFirewallRule -PolicyStore ActiveStore -Direction Outbound -Action Allow -Enabled True |
        Where-Object { $_.PolicyStoreSourceType -notin @('Local','Dynamic','Generated','Hardcoded') })
    if ($managed.Count) { throw 'Organization-managed outbound rules are present. No firewall changes were made.' }
}

function Assert-LockActive {
    $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
    if ($profiles.Count -ne 3) { throw 'Unable to verify all Windows Firewall profiles.' }
    foreach ($profile in $profiles) {
        if ([string]$profile.Enabled -ne 'True' -or [string]$profile.DefaultOutboundAction -ne 'Block') {
            throw 'Windows Firewall has not confirmed the outbound block on every profile.'
        }
    }
    $other = @(Get-NetFirewallRule -PolicyStore ActiveStore -Direction Outbound -Action Allow -Enabled True |
        Where-Object { $_.Group -ne $group })
    if ($other.Count) { throw 'Additional outbound exceptions are active. Strict protection is not confirmed.' }
    $own = @(Get-NetFirewallRule -PolicyStore ActiveStore -Group $group -Direction Outbound -Action Allow -Enabled True)
    if ($own.Count -ne 3) { throw 'The expected VPN-only firewall rules are missing.' }
}

function Enable-VpnLock {
    $address = $null
    if (-not [Net.IPAddress]::TryParse($ServerAddress,[ref]$address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'A fixed IPv4 VPN server address is required.'
    }
    $previous = Get-LockState
    if ($previous -and $previous.Phase -ne 'Disabled') {
        Assert-LockActive
        if ((Get-VpnPublicAddress '') -ne $previous.ServerAddress) {
            throw 'Protection rules remain active, but the VPN exit IP is not verified. Connect HAPP or use VPN-OFF.bat.'
        }
        Write-Host 'Protection is already ON. Run VPN-OFF.bat to restore ordinary internet.'
        return
    }
    Assert-FirewallPolicy
    $tunnel = Get-VerifiedTunnel $TunnelInterfaceAlias $ServerAddress
    $service = Get-CimInstance Win32_Service -Filter "Name='HappService'"
    if (-not $service -or $service.State -ne 'Running') { throw 'The HAPP service is not running.' }
    $program = if ($service.PathName -match '^"([^"]+)"') { $Matches[1] } else { $service.PathName }
    if ($program -notmatch '(?i)\\Happ\\happd\.exe$' -or -not (Test-Path -LiteralPath $program)) {
        throw 'The HAPP service executable could not be verified.'
    }
    if ((Get-AuthenticodeSignature -LiteralPath $program).Status -ne 'Valid') {
        throw 'The HAPP service signature is not valid.'
    }
    Initialize-StateDirectory
    Invoke-Netsh -Arguments @('advfirewall','export',$backupPath)
    $state = [ordered]@{
        Version = 1; Phase = 'Preparing'; ServerAddress = $ServerAddress; ServerPort = $ServerPort
        TunnelAlias = $tunnel.InterfaceAlias; CreatedUtc = [DateTime]::UtcNow.ToString('o')
        BackupHash = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash
    }
    Write-LockState $state
    try {
        # Default-deny is persistent. Existing allow rules must also be disabled:
        # setting the default alone does not override explicit outbound exceptions.
        Set-NetFirewallProfile -PolicyStore PersistentStore -Profile Domain,Private,Public -Enabled True -DefaultOutboundAction Block
        Get-NetFirewallRule -PolicyStore PersistentStore -Direction Outbound -Action Allow -Enabled True |
            Disable-NetFirewallRule | Out-Null
        Get-NetFirewallRule -PolicyStore PersistentStore -Group $group -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule
        New-NetFirewallRule -PolicyStore PersistentStore -Name 'RemoteAgents-VpnLock-Tunnel' -DisplayName 'VPN Lock: tunnel only' `
            -Group $group -Direction Outbound -Action Allow -Profile Any -InterfaceAlias $tunnel.InterfaceAlias | Out-Null
        New-NetFirewallRule -PolicyStore PersistentStore -Name 'RemoteAgents-VpnLock-Transport' -DisplayName 'VPN Lock: fixed server transport' `
            -Group $group -Direction Outbound -Action Allow -Profile Any `
            -Protocol TCP -RemoteAddress $ServerAddress -RemotePort $ServerPort | Out-Null
        New-NetFirewallRule -PolicyStore PersistentStore -Name 'RemoteAgents-VpnLock-Dhcp' -DisplayName 'VPN Lock: DHCP lease only' `
            -Group $group -Direction Outbound -Action Allow -Profile Any -Program "$env:SystemRoot\System32\svchost.exe" `
            -Service Dhcp -Protocol UDP -LocalPort 68 -RemotePort 67 | Out-Null
        Assert-LockActive
        $state.Phase = 'Enabled'
        Write-LockState $state
        if ((Get-VpnPublicAddress '') -ne $ServerAddress) {
            throw 'The exit IP check failed. Protection stays ON; use VPN-OFF.bat to restore internet.'
        }
        Write-Host 'Protection ON. VPN exit IP verified. Without this tunnel, internet is blocked.'
        Write-Host 'VPN-OFF.bat restores the saved Windows Firewall policy.'
    } catch {
        # Never silently restore ordinary internet following a failed ON operation.
        $state.Phase = 'NeedsAttention'
        Write-LockState $state
        throw ('Protection setup was not fully confirmed. No automatic unblock was performed. ' +
            'Run VPN-OFF.bat for recovery. ' + $_.Exception.Message)
    }
}

function Disable-VpnLock {
    $state = Get-LockState
    if (-not $state -or $state.Phase -eq 'Disabled') {
        $leftovers = @(Get-NetFirewallRule -PolicyStore PersistentStore -Group $group -ErrorAction SilentlyContinue)
        if ($leftovers.Count) { throw 'VPN Lock rules exist without a valid backup. No reset was attempted.' }
        Write-Host 'Protection is already OFF. No firewall changes were made.'
        return
    }
    if (-not (Test-Path -LiteralPath $backupPath) -or
        (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash -ne $state.BackupHash) {
        throw 'The saved firewall backup is missing or changed. No firewall reset was attempted.'
    }
    Invoke-Netsh -Arguments @('advfirewall','import',$backupPath)
    if (@(Get-NetFirewallRule -PolicyStore PersistentStore -Group $group -ErrorAction SilentlyContinue).Count) {
        throw 'Firewall restore did not remove the VPN Lock rules. Protection OFF is not confirmed.'
    }
    $state.Phase = 'Disabled'
    Write-LockState $state
    Write-Host 'Protection OFF. The Windows Firewall policy saved before activation was restored.'
}

function Show-VpnLockStatus {
    $state = Get-LockState
    if (-not $state -or $state.Phase -eq 'Disabled') { Write-Host 'Protection OFF.'; return }
    Assert-LockActive
    Write-Host ('Protection rules active. Fixed server: {0}. Tunnel: {1}.' -f $state.ServerAddress,$state.TunnelAlias)
    Write-Host 'The VPN may be disconnected; in that case internet remains blocked.'
}

try {
    if (-not (Test-Administrator)) {
        if ($Elevated) { throw 'Administrator rights were not granted.' }
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action {1} -ServerAddress "{2}" -ServerPort {3} -Elevated -ShowResult' -f `
            $PSCommandPath,$Action,$ServerAddress,$ServerPort
        if ($TunnelInterfaceAlias) { $arguments += ' -TunnelInterfaceAlias "' + $TunnelInterfaceAlias.Replace('"','') + '"' }
        $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList $arguments -Verb RunAs -PassThru -Wait
        exit $process.ExitCode
    }
    $mutex = New-Object Threading.Mutex($false,'Global\RemoteAgents-VpnLock')
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Another VPN switch operation is still running.' }
        switch ($Action) {
            Enable { Enable-VpnLock }
            Disable { Disable-VpnLock }
            Status { Show-VpnLockStatus }
        }
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
    if ($ShowResult) { Start-Sleep -Seconds 3 }
    exit 0
} catch {
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    if ($ShowResult) { [void](Read-Host 'Press Enter to close this window') }
    exit 1
}
