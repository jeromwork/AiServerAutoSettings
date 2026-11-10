#!/usr/bin/env bash
# Read-only inventory, or explicit non-root repair using existing public installers.
set -euo pipefail
umask 077
export PATH="$HOME/.local/share/remoteagents-accounts/node:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
case "${1:-inspect}" in
inspect)
python3 - <<'PYCODE'
import json,os,subprocess,urllib.request,xml.etree.ElementTree as E
from pathlib import Path
h=Path.home()
def active(name):
 try:return subprocess.run(['systemctl','--user','is-active','--quiet',name],timeout=5,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
 except (OSError,subprocess.TimeoutExpired):return False
disk=False
try:
 c=E.parse(h/'.local/share/remote-disk/config.xml').getroot();g=c.find('gui');req=urllib.request.Request('http://'+g.findtext('address')+'/rest/system/status',headers={'X-API-Key':g.findtext('apikey')});disk=bool(json.load(urllib.request.urlopen(req,timeout=4)).get('myID'))
except Exception:pass
settings={}
f=h/'.config/remoteagents/services.json'
if f.exists():
 try:settings=json.loads(f.read_text(encoding='utf-8-sig').replace('\r',''))
 except Exception:pass
print(json.dumps(dict(schema=1,user=os.environ.get('USER',''),root=os.getuid()==0,disk=disk,happier=(h/'.local/bin/happier').is_file(),userManager=active('default.target'),bridge=all((h/'.local/share/codex-remote'/n).is_file() for n in ['codex-windows-bridge.py','server_node_catalog.py']),catalog=(h/'.config/remoteagents/transport-catalog.json').is_file(),services={k:settings.get(k,'') for k in ['serverUrl','webappUrl']})))
PYCODE
;;
repair)
[ "$(id -u)" != 0 ] || { echo 'Выберите SSH-профиль рабочего пользователя. Установка служб от root запрещена.' >&2; exit 41; }
# No sudo prompts or escalation in a hidden process. Missing OS prerequisites remain explicit errors.
for tool in python3 curl tar flock systemctl; do command -v "$tool" >/dev/null || { echo "Администратору сервера нужно установить: $tool" >&2; exit 42; }; done
if [ "${2:-1}" = 1 ]; then bash "$HOME/.local/share/remote-disk/server-disk.sh" bootstrap >/dev/null; fi
if [ "${3:-1}" = 1 ]; then bash "$HOME/.local/share/remoteagents-accounts/bootstrap.sh"; fi
if [ "${4:-1}" = 1 ]; then python3 "$HOME/.local/share/remoteagents-wizard/server-transport-catalog.py" get >/dev/null; fi
;;
*) exit 2;;
esac
