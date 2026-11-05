#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ProfileDirectory,
    [string]$ServerAddress,
    [string]$Login = 'root',
    [string]$IdentityFile,
    [string]$KnownHostsFile,
    [string]$SSHConfig,
    [string]$SSHExecutable = "$env:WINDIR\System32\OpenSSH\ssh.exe",
    [int]$SSHPort = 443,
    [string]$JumpHost,
    [int]$VpnPort = 8443,
    [switch]$ImportOnly
)
$ErrorActionPreference = 'Stop'
if (-not $ServerAddress) {
    if (-not $ProfileDirectory) {
        $root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'RemoteAgents\ssh-profiles'
        $profiles = @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'profile.json') })
        if ($profiles.Count -ne 1) { throw 'Choose the server through the main installer VPN menu.' }
        $ProfileDirectory = $profiles[0].FullName
    }
    $metadata = Get-Content -LiteralPath (Join-Path $ProfileDirectory 'profile.json') -Raw | ConvertFrom-Json
    $ServerAddress = [string]$metadata.serverAddress
    $Login = [string]$metadata.login
    if ($metadata.sshPort) { $SSHPort = [int]$metadata.sshPort }
}
if ($ProfileDirectory) {
    if (-not $IdentityFile) { $IdentityFile = Join-Path $ProfileDirectory 'id_ed25519' }
    if (-not $KnownHostsFile) { $KnownHostsFile = Join-Path $ProfileDirectory 'known_hosts' }
    if (-not $SSHConfig) { $SSHConfig = Join-Path $ProfileDirectory 'ssh_config' }
}
if ($ServerAddress -notmatch '\A[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}\z' -or $Login -notmatch '\A[a-zA-Z0-9_-]+\z') { throw 'Invalid server address or user.' }
foreach ($path in @($IdentityFile,$KnownHostsFile,$SSHConfig,$SSHExecutable)) {
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'SSH connection files are missing.' }
}
$sshArguments = @('-F',$SSHConfig,'-i',$IdentityFile,'-p',[string]$SSHPort,
    '-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes',
    '-o',('UserKnownHostsFile='+$KnownHostsFile),'-o','ConnectTimeout=12')
if ($JumpHost) {
    if ($JumpHost -notmatch '\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z') { throw 'Invalid jump host.' }
    $proxyConfig = (Join-Path $HOME '.ssh\config').Replace('\','/')
    $proxyExe = $SSHExecutable.Replace('\','/')
    $sshArguments += @('-o',('ProxyCommand="{0}" -F "{1}" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=12 -W %h:%p {2}' -f $proxyExe,$proxyConfig,$JumpHost))
}
$sshArguments += @('-T',($Login+'@'+$ServerAddress))
if (-not $ImportOnly) {
    Write-Host 'Preparing HAPP server. Downloads happen on the VPS.'
    $payload = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'server-happ.sh')).Replace("`r`n","`n").TrimStart([char]0xFEFF)
    $command = 'if [ "$(id -u)" -eq 0 ]; then tr -d "\r" | bash -s -- ' + $ServerAddress + ' ' + $VpnPort + '; else tr -d "\r" | sudo -n bash -s -- ' + $ServerAddress + ' ' + $VpnPort + '; fi'
    $payload | & $SSHExecutable @sshArguments $command
    if ($LASTEXITCODE -ne 0) { throw 'HAPP server setup failed. The connection was not imported.' }
}
# This owner-invoked helper puts the connection directly into the clipboard.
# It never prints or saves VPN credentials in the project or setup logs.
$link = & $SSHExecutable @sshArguments 'if [ "$(id -u)" -eq 0 ]; then exec /usr/local/bin/remoteagents-happ-link; else exec sudo -n /usr/local/bin/remoteagents-happ-link; fi'
if ($LASTEXITCODE -ne 0 -or @($link).Count -ne 1 -or $link -notmatch '\Avless://[^\s]+\z') { throw 'The server did not return a valid HAPP connection.' }
Set-Clipboard -Value ([string]$link)
$link = $null
Write-Host 'Connection copied. In HAPP: + -> Add from clipboard. Then enable VPN mode and connect.'
$happ = Join-Path $env:ProgramFiles 'FlyFrogLLC\Happ\Happ.exe'
if (Test-Path -LiteralPath $happ) { Start-Process -FilePath $happ | Out-Null }
else { Write-Host 'Install HAPP from https://happ.info and add the connection from the clipboard.' }
