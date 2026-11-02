[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^win-[a-f0-9]{28}$')][string]$DeviceLabel,
    [ValidatePattern('^[a-z_][a-z0-9_-]*$')][string]$ServerUser = 'remoteagents',
    [ValidatePattern('^(/[a-zA-Z0-9._-]+)+$')][string]$RemoteBase = '/home/remoteagents/.local/share/codex-remote',
    [ValidatePattern('^(/[a-zA-Z0-9._-]+)+$')][string]$SocketPath,
    [ValidateSet('1','2','3')][string]$Agents = '1',
    [ValidatePattern('^[a-z0-9][a-z0-9_-]{0,63}$')][string]$ProjectId,
    [ValidatePattern('^(/[a-zA-Z0-9._-]+)+$')][string]$CodexExecutable = '/opt/remote-agents/codex/0.166.0/bin/codex'
)
$ErrorActionPreference = 'Stop'
if ($ServerUser -eq 'root') { throw 'The GUI MCP must be registered for a non-root user.' }
if ($Agents -in @('2','3') -and -not $ProjectId) { throw 'Claude registration requires a selected project.' }
if (-not $SocketPath) { $SocketPath = '/home/' + $ServerUser + '/.local/state/codex-remote/' + $DeviceLabel + '.sock' }
# This helper only builds PUBLIC shell source. It never opens SSH or user config.
# The installer uploads the adapter first, owns the exact reserved name/marker,
# and sends this script through its existing verified SSH stdin transport.
$name = 'windows-' + $DeviceLabel
$script = @'
set -eu
target='__USER__'
target_uid=$(id -u "$target")
[ "$target_uid" -ne 0 ] || { echo 'GUI_MCP_ERROR: non-root user required' >&2; exit 1; }
target_home=$(getent passwd "$target" | cut -d: -f6)
case "$target_home" in /*) ;; *) echo 'GUI_MCP_ERROR: absolute user home required' >&2; exit 1;; esac
as_target() {
    if [ "$(id -u)" -eq 0 ]; then
        runuser -u "$target" -- env -u CODEX_HOME HOME="$target_home" "$@"
    elif [ "$(id -u)" -eq "$target_uid" ]; then
        env -u CODEX_HOME HOME="$target_home" "$@"
    else
        sudo -n -u "$target" -- env -u CODEX_HOME HOME="$target_home" "$@"
    fi
}
if { [ '__AGENTS__' = 1 ] || [ '__AGENTS__' = 3 ]; } && [ -x '__CODEX__' ]; then
    as_target '__CODEX__' mcp add '__NAME__' -- /usr/bin/python3 '__BASE__/codex-windows-bridge.py' --catalog '/home/__USER__/.local/share/remote-agents-nodes'
    printf '%s\n' 'CODEX_GUI_MCP_CONFIGURED=__NAME__'
fi
if { [ '__AGENTS__' = 2 ] || [ '__AGENTS__' = 3 ]; } && [ -x "$target_home/.local/bin/claude" ]; then
    # Local scope is keyed by this cwd in Claude's own configuration. The CLI
    # merges its reserved entry; we never read or rewrite personal config/auth.
    # Only the root-owned installer marker authorizes replacing this reserved
    # local entry. A first-time name collision fails without deleting anything.
    if [ "${REMOTEAGENTS_MANAGED_MCP:-0}" = 1 ]; then
        as_target bash -c 'cd "$1"; "$2" mcp remove "$3" --scope user >/dev/null 2>&1 || true' handoff '/home/__USER__/work/projects/__PROJECT__' '/home/__USER__/.local/bin/claude' '__NAME__'
    fi
    as_target bash -c 'cd "$1"; exec "$2" mcp add --transport stdio --scope user "$3" -- /usr/bin/python3 "$4" --catalog "$5"' handoff '/home/__USER__/work/projects/__PROJECT__' '/home/__USER__/.local/bin/claude' '__NAME__' '__BASE__/codex-windows-bridge.py' '/home/__USER__/.local/share/remote-agents-nodes'
    printf '%s\n' 'CLAUDE_CODE_GUI_MCP_CONFIGURED=__NAME__'
fi
printf '%s\n' 'GUI_MCP_REGISTERED=__NAME__'
'@
$script = $script.Replace('__USER__',$ServerUser).Replace('__CODEX__',$CodexExecutable).Replace('__NAME__',$name).Replace('__BASE__',$RemoteBase).Replace('__SOCKET__',$SocketPath).Replace('__AGENTS__',$Agents).Replace('__PROJECT__',$ProjectId)
[pscustomobject]@{ Name=$name; DeviceLabel=$DeviceLabel; SocketPath=$SocketPath; RemoteScript=($script.Replace("`r`n","`n") + "`n") }
