#!/usr/bin/env bash
set -euo pipefail
# Payload variables are supplied by the launcher, never account-specific defaults.
if [ "$(id -u)" = 0 ]; then
    if [ -n "$CONTROL_USER" ]; then
        [[ "$CONTROL_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] && [ "$CONTROL_USER" != root ] || { echo 'Недопустимый -AgentUser' >&2; exit 1; }
        entry=$(getent passwd "$CONTROL_USER") || { echo 'Пользователь -AgentUser не существует' >&2; exit 1; }
        [ "$(printf '%s' "$entry" | cut -d: -f3)" != 0 ] || exit 1
    else
        candidates=()
        while IFS=: read -r name pass uid gid desc home shell; do
            if [ "$uid" -ge 1000 ] && [[ "$shell" != */nologin && "$shell" != */false ]] && [ -x "$shell" ] && { [ -x "$home/.local/bin/claude" ] || [ -d "$home/.local/share/codex-remote" ]; }; then candidates+=("$name"); fi
        done < <(getent passwd)
        [ "${#candidates[@]}" = 1 ] || { printf 'Укажите -AgentUser; кандидаты: %s\n' "${candidates[*]:-нет}" >&2; exit 1; }
        CONTROL_USER=${candidates[0]}
        entry=$(getent passwd "$CONTROL_USER")
    fi
    CONTROL_HOME=$(printf '%s' "$entry" | cut -d: -f6)
else
    CONTROL_USER=$(id -un)
    CONTROL_HOME=$HOME
fi
export CONTROL_USER CONTROL_HOME CONTROL_DATA CONTROL_BRIDGE CONTROL_SESSION CONTROL_CATALOG
worker=$(cat <<'WORKER'
set -euo pipefail
umask 077
export HOME=$CONTROL_HOME
base=$HOME/.local/share/codex-remote
state=$HOME/.local/state/codex-remote
mkdir -p "$base" "$state"
echo 'Установка файлов моста' >&2
/usr/bin/python3 - <<'PYCODE'
import os, base64, json, tempfile, sys
from pathlib import Path
home=Path(os.environ['HOME']); base=home/'.local/share/codex-remote'
for name,key in [('codex-windows-bridge.py','CONTROL_BRIDGE'),('codex-bridge-session.py','CONTROL_SESSION'),('server_node_catalog.py','CONTROL_CATALOG')]:
    content=base64.b64decode(os.environ[key]).replace(b'\r\n',b'\n').replace(b'\r',b'\n')
    fd,tmp=tempfile.mkstemp(dir=base)
    try:
        with os.fdopen(fd,'wb') as stream: stream.write(content)
        os.chmod(tmp,0o600);os.replace(tmp,base/name)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
sys.path.insert(0,str(base))
from server_node_catalog import register
data=json.loads(base64.b64decode(os.environ['CONTROL_DATA']))
data.update(controlOnly=True,allowShell=bool(data.get('allowShell',False)),projectName='Управление компьютером',serverWorkspace=str(home/'work/projects/control'),socketPath=str(home/'.local/state/codex-remote'/(data['deviceLabel']+'.sock')))
register(home/'.local/share/remote-agents-nodes',data,str(home))
PYCODE
echo 'Регистрация MCP' >&2
if ! grep -q 'remote-agents-nodes' "$HOME/.claude.json" 2>/dev/null && [ -x "$HOME/.local/bin/claude" ]; then
    "$HOME/.local/bin/claude" mcp add --transport stdio --scope user windows-control -- /usr/bin/python3 "$base/codex-windows-bridge.py" --catalog "$HOME/.local/share/remote-agents-nodes" >&2
fi
if ! grep -q 'remote-agents-nodes' "$HOME/.codex/config.toml" 2>/dev/null && command -v codex >/dev/null 2>&1; then
    codex mcp add windows-control -- /usr/bin/python3 "$base/codex-windows-bridge.py" --catalog "$HOME/.local/share/remote-agents-nodes" >&2
fi
/usr/bin/python3 -c 'import os,json;print(json.dumps({"user":os.environ["CONTROL_USER"],"home":os.environ["HOME"]}))'
WORKER
)
if [ "$(id -u)" = 0 ]; then
    runuser -u "$CONTROL_USER" -- env HOME="$CONTROL_HOME" CONTROL_USER="$CONTROL_USER" CONTROL_HOME="$CONTROL_HOME" CONTROL_DATA="$CONTROL_DATA" CONTROL_BRIDGE="$CONTROL_BRIDGE" CONTROL_SESSION="$CONTROL_SESSION" CONTROL_CATALOG="$CONTROL_CATALOG" bash -c "$worker"
else
    bash -c "$worker"
fi
