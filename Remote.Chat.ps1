# Shared public helpers. Never read credentials or write sign-in output to logs.
function Test-RemoteChatUser([string]$Name) {
    return $Name -ceq 'remoteagents'
}
function Get-RemoteChatApprovalUrl([string]$Line) {
    $clean = $Line -replace '\x1b\[[0-9;?]*[ -/]*[@-~]', ''
    foreach ($match in [regex]::Matches($clean, 'https://[^\s<>"\x1b]+')) {
        $uri = $null
        if ([Uri]::TryCreate($match.Value.TrimEnd(')',']',',','.'),[UriKind]::Absolute,[ref]$uri) -and
            $uri.Scheme -eq 'https' -and $uri.IsDefaultPort -and !$uri.UserInfo -and
            ($uri.DnsSafeHost -eq 'happier.dev' -or $uri.DnsSafeHost.EndsWith('.happier.dev')) -and
            $uri.AbsolutePath -match '/(?:auth|terminal|connect|approve|pair)(?:/|$)') {
            return $uri.AbsoluteUri
        }
    }
    return $null
}
function Convert-RemoteChatArgument([string]$Value) {
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}
function New-RemoteChatStart {
    param([string]$SSHExecutable,[string]$VPSHost,[string]$VPSUser,[string]$IdentityFile,[string]$SSHConfig,[string]$KnownHostsFile,[int]$SSHPort,[string]$ChatUser,[ValidateSet('status','login')][string]$Action)
    if (!(Test-RemoteChatUser $ChatUser)) { throw 'Недопустимое имя пользователя чатов.' }
    if ($VPSHost -notmatch '\A[a-zA-Z0-9._:-]+\z' -or $VPSUser -notmatch '\A[a-zA-Z0-9_-]+\z') { throw 'Недопустимый адрес подключения.' }
    if ($SSHPort -lt 1 -or $SSHPort -gt 65535) { throw 'Недопустимый порт подключения.' }
    $argsList=@('-p',[string]$SSHPort,'-i',$IdentityFile,'-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','ConnectTimeout=10','-o','ConnectionAttempts=1','-o','ServerAliveInterval=10','-o','ServerAliveCountMax=2','-o','StrictHostKeyChecking=yes')
    if($SSHConfig){$argsList+=@('-F',$SSHConfig)}else{$argsList+=@('-F','NUL')}
    if($KnownHostsFile){$argsList+=@('-o',('UserKnownHostsFile='+$KnownHostsFile))}
    $operation=if($Action -eq 'login'){'auth login --no-open --method web --wait-timeout 600'}else{'auth status --json'}
    $seconds=if($Action -eq 'login'){610}else{8}
    $run="timeout $seconds runuser -u $ChatUser -- env HOME=/home/$ChatUser PATH=/home/$ChatUser/.local/bin:/usr/local/bin:/usr/bin:/bin /home/$ChatUser/.local/bin/happier $operation"
    # Ubuntu SSH login may be root or a sudo-capable account; no new sudo policy.
    $command='if [ "$(id -u)" -eq 0 ]; then '+$run+'; else sudo -n '+$run+'; fi'
    $argsList+=@('-T',($VPSUser+'@'+$VPSHost),$command)
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$SSHExecutable
    $start.Arguments=(@($argsList|ForEach-Object{Convert-RemoteChatArgument $_}) -join ' ')
    $start.UseShellExecute=$false
    $start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
    return $start
}
