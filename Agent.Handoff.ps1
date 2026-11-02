# Public data only. The installer already owns the verified SSH connection.
function New-RemoteAgentHandoff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidatePattern('^[a-z0-9][a-z0-9_-]{0,63}$')][string]$ProjectId,
        [Parameter(Mandatory=$true)][ValidatePattern('^[a-z0-9][a-z0-9_-]{0,63}$')][string]$HostId,
        [Parameter(Mandatory=$true)][ValidatePattern('^win-[a-f0-9]{28}$')][string]$DeviceLabel,
        [Parameter(Mandatory=$true)][string]$ReplicaPath,
        [Parameter(Mandatory=$true)][ValidateSet('1','2','3')][string]$Agents,
        [Parameter(Mandatory=$true)][bool]$AllowShell
    )
    $source=Join-Path $PSScriptRoot 'server-agent-handoff.py'
    if(-not [IO.File]::Exists($source)){throw 'Не хватает модуля передачи проекта агенту. Скопируйте полный комплект.'}
    $base='/home/remoteagents/.local/share/codex-remote'
    $directory='/home/remoteagents/.local/share/remote-agent-handoff/'+$ProjectId+'/'+$HostId
    $data=[ordered]@{schema=1;projectId=$ProjectId;hostId=$HostId;deviceLabel=$DeviceLabel;deviceName=[Environment]::MachineName;serverWorkspace=('/home/remoteagents/work/projects/'+$ProjectId);windowsReplica=$ReplicaPath;socketPath=('/home/remoteagents/.local/state/codex-remote/'+$DeviceLabel+'.sock');agents=$Agents;allowShell=$AllowShell}
    $encoded=[Convert]::ToBase64String([IO.File]::ReadAllBytes($source))
    $metadata=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($data|ConvertTo-Json -Compress)))
    $script=@'
set -eu
runuser -u remoteagents -- env HOME=/home/remoteagents bash -c 'umask 077; base64 --decode > "$HOME/.local/share/codex-remote/server-agent-handoff.py"' <<'REMOTEAGENTS_PUBLIC_HANDOFF'
__SOURCE__
REMOTEAGENTS_PUBLIC_HANDOFF
runuser -u remoteagents -- env HOME=/home/remoteagents /usr/bin/python3 __BASE__/server-agent-handoff.py --prepare-b64 '__METADATA__'
'@
    $script=$script.Replace('__SOURCE__',$encoded).Replace('__METADATA__',$metadata).Replace('__BASE__',$base).Replace("`r`n","`n")+"`n"
    $smoke="runuser -u remoteagents -- env HOME=/home/remoteagents /usr/bin/python3 $base/server-agent-handoff.py --handoff $directory/handoff.json --smoke`n"
    [pscustomobject]@{RemoteScript=$script;SmokeScript=$smoke;Directory=$directory;HandoffPath=($directory+'/handoff.json');StartPage=($directory+'/start.html');DeviceLabel=$DeviceLabel}
}
