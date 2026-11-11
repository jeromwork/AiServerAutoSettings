#!/usr/bin/env bash
# Read-only inventory, explicit non-root repair using existing public installers, and long
# installs detached from the SSH session (start/status/run/ensure): closing the window or the
# PC never interrupts them. State: ~/.local/state/remoteagents-wizard/<op>.json; one run per op (flock).
set -euo pipefail
umask 077
export PATH="$HOME/.local/share/remoteagents-accounts/node:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
state_dir="$HOME/.local/state/remoteagents-wizard"
self="$HOME/.local/share/remoteagents-wizard/server-wizard.sh"
# Public state only: no command line, environment or installer output is copied into it.
read -r -d '' ops_py <<'PYCODE' || true
import calendar,fcntl,json,os,re,sys,time
from pathlib import Path
d=Path.home()/'.local/state/remoteagents-wizard'
def now():return time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
def seconds(text):
 try:return calendar.timegm(time.strptime(text,'%Y-%m-%dT%H:%M:%SZ'))
 except Exception:return None
def load(op):
 try:return json.loads((d/(op+'.json')).read_text(encoding='utf-8'))
 except Exception:return {}
def save(op,data):
 d.mkdir(parents=True,exist_ok=True);t=d/(op+'.json.tmp');t.write_text(json.dumps(data,ensure_ascii=False),encoding='utf-8');os.replace(t,d/(op+'.json'))
def running(op):
 p=d/(op+'.lock')
 if not p.exists():return False
 with p.open('a') as f:
  try:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
  except OSError:return True
  fcntl.flock(f,fcntl.LOCK_UN);return False
def clean(text):
 text=re.sub(r'\x1b\[[0-9;?]*[A-Za-z]','',text)
 text=re.sub(r'(?i)(token|key|secret|password|authorization)\S*\s*[=:]\s*\S+',r'\1=***',text)
 return re.sub(r'[\x00-\x1f]+',' ',text).strip()[:240]
def status(op):
 s=load(op);r=dict(op=op,state='none',started=s.get('started'),finished=s.get('finished'),step='',stage=0,stages=0,exitCode=s.get('exitCode'),reason=s.get('reason',''))
 try:
  step=clean((d/(op+'.step')).read_text(encoding='utf-8'));m=re.match(r'(\d+)/(\d+) (.*)',step)
  if m:r.update(stage=int(m.group(1)),stages=int(m.group(2)),step=m.group(3))
  else:r['step']=step
 except Exception:pass
 if running(op):r['state']='running'
 elif s.get('finished'):r['state']='finished' if s.get('exitCode')==0 else 'failed'
 elif s.get('started'):r.update(state='failed',reason='Операция прервана (перезагрузка сервера или завершение процесса). Повторите шаг')
 a=seconds(r['started'] or '');b=seconds(r['finished'] or '') if r['state']!='running' else time.time()
 r['elapsedSec']=max(0,int(b-a)) if a is not None and b is not None else 0
 return r
a=sys.argv[1:]
if a[0]=='status':print(json.dumps({op:status(op) for op in a[1:]},ensure_ascii=False))
elif a[0]=='begin':save(a[1],dict(schema=1,op=a[1],started=now(),finished=None,exitCode=None,reason=''))
elif a[0]=='end':
 s=load(a[1]);code=int(a[2]);reason=''
 if code:
  try:reason=clean([l for l in (d/(a[1]+'.log')).read_text(encoding='utf-8',errors='replace').splitlines() if l.strip()][-1])
  except Exception:reason=''
  reason=reason or 'код '+str(code)
 s.update(finished=now(),exitCode=code,reason=reason);save(a[1],s)
PYCODE
valid_op() { case "${1:-}" in happier|disk) return 0;; *) echo 'Неизвестная операция' >&2; exit 2;; esac; }
op_status() { python3 -c "$ops_py" status "$@"; }
op_start() {
    # Lock is taken here and inherited by the detached runner: a second start sees it held.
    local op=$1
    mkdir -p "$state_dir"
    exec 9>>"$state_dir/$op.lock"
    if flock -n 9; then
        python3 -c "$ops_py" begin "$op"
        : > "$state_dir/$op.log"; printf '%s\n' 'Запуск' > "$state_dir/$op.step"
        local runner=(bash "$self" run "$op")
        # A user scope survives logout even with KillUserProcesses=yes; otherwise a new session.
        if command -v systemd-run >/dev/null 2>&1 && timeout 10 systemd-run --user --scope --quiet --collect true </dev/null >/dev/null 2>&1 9>&-; then
            runner=(systemd-run --user --scope --quiet --collect --unit="remoteagents-$op-$(date +%s)-$$" "${runner[@]}")
        fi
        setsid nohup "${runner[@]}" </dev/null >>"$state_dir/$op.log" 2>&1 &
    fi
    exec 9>&-
}
happier_ready() { test -x "$HOME/.local/bin/happier" && systemctl --user show-environment >/dev/null 2>&1; }
case "${1:-inspect}" in
inspect)
RA_OPS=$(op_status happier disk 2>/dev/null || echo '{}') python3 - <<'PYCODE'
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
try:ops=json.loads(os.environ.get('RA_OPS') or '{}')
except Exception:ops={}
print(json.dumps(dict(schema=1,user=os.environ.get('USER',''),root=os.getuid()==0,disk=disk,happier=(h/'.local/bin/happier').is_file(),userManager=active('default.target'),bridge=all((h/'.local/share/codex-remote'/n).is_file() for n in ['codex-windows-bridge.py','server_node_catalog.py']),catalog=(h/'.config/remoteagents/transport-catalog.json').is_file(),services={k:settings.get(k,'') for k in ['serverUrl','webappUrl']},operations=ops)))
PYCODE
;;
status)
shift; for op in "$@"; do valid_op "$op"; done
op_status "$@"
;;
start)
valid_op "${2:-}"; op_start "$2"; op_status "$2"
;;
ensure)
# Explicit request: ready now, or the install is running (a failed one is retried).
valid_op "${2:-}"
ready=false
if [ "$2" = happier ] && happier_ready && [ "$(op_status happier | python3 -c 'import json,sys;print(json.load(sys.stdin)["happier"]["state"])')" != running ]; then ready=true; fi
if [ "$ready" = false ]; then op_start "$2"; fi
op_status "$2" | python3 -c 'import json,sys;r=json.load(sys.stdin)[sys.argv[1]];r["ready"]=sys.argv[2]=="true";print(json.dumps(r,ensure_ascii=False))' "$2" "$ready"
;;
run)
valid_op "${2:-}"; op=$2
export REMOTEAGENTS_STEP_FILE="$state_dir/$op.step"
# Step file: "k/n text" — stage k of n, shown with the elapsed time (never an estimate).
case "$op" in
happier) command=(bash "$HOME/.local/share/remoteagents-accounts/bootstrap.sh");;
disk) command=(bash "$HOME/.local/share/remote-disk/server-disk.sh" bootstrap); printf '%s\n' '1/1 Загружаю, проверяю и запускаю Syncthing' > "$REMOTEAGENTS_STEP_FILE";;
esac
if timeout 1800 "${command[@]}" 9>&-; then code=0; else code=$?; fi
python3 -c "$ops_py" end "$op" "$code"
;;
repair)
[ "$(id -u)" != 0 ] || { echo 'Выберите SSH-профиль рабочего пользователя. Установка служб от root запрещена.' >&2; exit 41; }
# No sudo prompts or escalation in a hidden process. Missing OS prerequisites remain explicit errors.
for tool in python3 curl tar flock systemctl setsid; do command -v "$tool" >/dev/null || { echo "Администратору сервера нужно установить: $tool" >&2; exit 42; }; done
# Long installs only start here; the window follows them with «status».
if [ "${2:-1}" = 1 ]; then op_start disk; fi
if [ "${3:-1}" = 1 ]; then op_start happier; fi
if [ "${4:-1}" = 1 ]; then python3 "$HOME/.local/share/remoteagents-wizard/server-transport-catalog.py" get >/dev/null; fi
op_status happier disk
;;
*) exit 2;;
esac
