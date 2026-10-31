#!/usr/bin/env bash
# Ubuntu-only, isolated empty profile/display. Never inspect the owner's desktop.
set -Eeuo pipefail
[[ $(id -u) == 0 ]] || exit 3
server_user=${1:-remoteagents}
[[ $server_user =~ ^[a-z_][a-z0-9_-]{0,31}$ && $server_user != root ]] || exit 2
runuser -u "$server_user" -- bash -s <<'FRESH_PROFILE'
set -Eeuo pipefail
stage=$(mktemp -d /tmp/remoteagents-chatgpt-smoke.XXXXXXXX)
chmod 0700 "$stage"
trap 'rm -rf -- "$stage"' EXIT
mkdir "$stage/home" "$stage/config" "$stage/cache" "$stage/data" "$stage/runtime" "$stage/codex"
chmod 0700 "$stage/runtime"
env -i PATH=/usr/bin:/bin HOME="$stage/home" XDG_CONFIG_HOME="$stage/config" XDG_CACHE_HOME="$stage/cache" XDG_DATA_HOME="$stage/data" XDG_RUNTIME_DIR="$stage/runtime" CODEX_HOME="$stage/codex" \
 xvfb-run -a --server-args='-screen 0 1280x800x24 -nolisten tcp' python3 -I - "$stage" <<'PROBE'
import os, signal, subprocess, sys, time
from pathlib import Path
stage=Path(sys.argv[1])
with (stage/'stderr').open('wb') as err:
 p=subprocess.Popen(['/usr/bin/chatgpt','--user-data-dir='+str(stage/'electron')],cwd=stage,stdout=subprocess.DEVNULL,stderr=err,start_new_session=True)
 try:
  window=False
  for _ in range(40):
   time.sleep(.5)
   if p.poll() is not None: break
   tree=subprocess.run(['xwininfo','-root','-tree'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,check=True).stdout
   # Count mapped application windows without printing any title/content.
   for line in tree.splitlines():
    if '"' in line and ('chatgpt' in line.lower() or 'codex' in line.lower()):
     window=True
   if window:
    time.sleep(5)
    break
  print('CHATGPT_TEST_UID='+str(os.getuid()))
  print('CHATGPT_TEST_FRESH_PROFILE=1')
  print('CHATGPT_TEST_WINDOW='+str(int(window)))
  print('CHATGPT_TEST_PROCESS_ALIVE='+str(int(p.poll() is None)))
  if not window or p.poll() is not None:
   # Only classify known startup failures; never output application logs.
   text=(stage/'stderr').read_text(errors='replace').lower()
   for label,word in [('SANDBOX_ERROR','sandbox'),('DISPLAY_ERROR','display'),('MISSING_LIBRARY','shared librar')]:
    print(label+'='+str(int(word in text)))
   raise SystemExit(1)
 finally:
  try: os.killpg(p.pid,signal.SIGTERM)
  except ProcessLookupError: pass
  try: p.wait(timeout=5)
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGKILL); p.wait()
PROBE
FRESH_PROFILE
