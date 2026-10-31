#!/usr/bin/env bash
# Ubuntu-only startup check, synthetic HOME/config, no account or model request.
set -Eeuo pipefail
[[ $(id -u) == 0 ]] || exit 3
runuser -u remoteagents -- env -i PATH=/usr/bin:/bin bash -s <<'ISOLATED'
set -Eeuo pipefail
stage=$(mktemp -d /home/remoteagents/.local/state/remoteagents-codex-smoke.XXXXXXXX)
chmod 0700 "$stage"
mkdir "$stage/home" "$stage/codex" "$stage/runtime" "$stage/work"
chmod 0700 "$stage/runtime"
export HOME="$stage/home" CODEX_HOME="$stage/codex" XDG_RUNTIME_DIR="$stage/runtime"
export PATH=/usr/bin:/bin TERM=xterm-256color
binary=/opt/remote-agents/codex/0.166.0/bin/codex
trap '"$binary" app-server daemon stop >/dev/null 2>&1 || true; rm -rf -- "$stage"' EXIT
cd "$stage/work"
python3 -I - "$binary" <<'PROBE'
import fcntl,json,os,pty,re,select,signal,struct,subprocess,sys,termios,time
binary=sys.argv[1]
def call(args):
 p=subprocess.run([binary,'app-server','daemon',*args],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=60)
 assert p.returncode==0, 'isolated daemon '+args[0]+' failed (output withheld)'
 return json.loads(p.stdout)
start=call(['start'])
version=call(['version'])
# Do not print arbitrary daemon fields, paths, or logs.
print('CODEX_ISOLATED_DAEMON_START=1')
print('CODEX_ISOLATED_VERSION_JSON=1')
assert '0.166.0' in json.dumps(version), 'unexpected packaged daemon version'
assert 'running' in json.dumps(version).lower(), 'packaged daemon is not running'
print('CODEX_ISOLATED_DAEMON_RUNNING=1')
master,slave=pty.openpty()
fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',30,120,0,0))
p=subprocess.Popen([binary],stdin=slave,stdout=slave,stderr=slave,start_new_session=True)
os.close(slave)
output=b''
try:
 until=time.monotonic()+15
 while time.monotonic()<until and p.poll() is None:
  if select.select([master],[],[],.25)[0]:
   try: chunk=os.read(master,65536)
   except OSError: break
   output+=chunk
   if b'\x1b[6n' in chunk: os.write(master,b'\x1b[1;1R')
 text=re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]','',output.decode(errors='replace')).lower()
 bad='no complete local package' in text
 onboarding=any(word in text for word in ('sign in with','welcome to codex','sign in to codex','chatgpt account'))
 print('CODEX_TUI_INCOMPLETE_PACKAGE_ERROR='+str(int(bad)))
 print('CODEX_TUI_FRESH_ONBOARDING='+str(int(onboarding)))
 print('CODEX_TUI_ALIVE='+str(int(p.poll() is None)))
 assert not bad and onboarding and p.poll() is None,'TUI startup was not confirmed (output withheld)'
finally:
 try: os.killpg(p.pid,signal.SIGTERM)
 except ProcessLookupError: pass
 try: p.wait(timeout=5)
 except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL);p.wait()
 os.close(master)
PROBE
ISOLATED
