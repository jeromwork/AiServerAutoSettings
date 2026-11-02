#!/usr/bin/env bash
# Ubuntu's supported xrdp/PipeWire module; only this managed desktop is changed.
set -Eeuo pipefail
umask 077
server_user=${1:-remoteagents}
[[ $server_user =~ ^[a-z_][a-z0-9_-]{0,31}$ && $server_user != root && $(id -u) == 0 ]] || exit 2
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || exit 3
install_dir=/usr/local/lib/remoteagents-desktop
python3 -I - "$install_dir" <<'AUDIO_TRUST'
import os, stat, sys
from pathlib import Path
base = Path(sys.argv[1])
for path in [Path('/'), Path('/usr'), Path('/usr/local'), Path('/usr/local/lib'), base,
             Path('/etc'), Path('/etc/systemd'), Path('/etc/systemd/system')]:
    info = path.lstat()
    assert not stat.S_ISLNK(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022, 'Unsafe audio installation path'
for path in list(base.rglob('*')) + [Path('/etc/systemd/system/remoteagents-desktop-audio.service')]:
    if not os.path.lexists(path): continue
    info = path.lstat()
    assert not stat.S_ISLNK(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022, 'Unsafe audio file metadata'
assert (base/'.remoteagents-managed').read_text().strip() == 'desktop-ssh-v2'
AUDIO_TRUST
packages=(pipewire pipewire-pulse wireplumber pipewire-module-xrdp pulseaudio-utils pavucontrol)
missing=0
for package in "${packages[@]}"; do
  [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || :) == 'install ok installed' ]] || missing=1
done
if (( missing )); then
  export DEBIAN_FRONTEND=noninteractive
  # Package hooks must not restart the active desktop or disconnect RDP.
  export NEEDRESTART_MODE=l
  apt-get update
  # Refuse any replacement/removal of an existing sound stack.
  apt-get install -y --no-install-recommends --no-remove "${packages[@]}"
fi
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
cat > "$stage/audio-session.py" <<'AUDIO_SESSION'
import os, signal, subprocess, time
from pathlib import Path
os.umask(0o077)
runtime = Path('/run/remoteagents-desktop-audio')
ready = runtime/'audio.ready'
ready.unlink(missing_ok=True)
children = []
def cleanup():
    ready.unlink(missing_ok=True)
    for child in reversed(children):
        if child.poll() is None: child.terminate()
    for child in reversed(children):
        try: child.wait(timeout=5)
        except subprocess.TimeoutExpired: child.kill()
def stop(*_):
    cleanup()
    raise SystemExit(0)
signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
def start(args):
    child = subprocess.Popen(args)
    children.append(child)
    return child
def wait_for(args):
    for _ in range(100):
        if any(child.poll() is not None for child in children): raise RuntimeError('Audio process stopped')
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=5)
        if result.returncode == 0: return result.stdout
        time.sleep(0.1)
    raise RuntimeError('Audio service did not become ready')
try:
    start(['/usr/bin/pipewire', '-c', '/usr/share/pipewire/pipewire.conf'])
    wait_for(['/usr/bin/pw-cli', 'info', '0'])
    start(['/usr/bin/pipewire-pulse', '-c', '/usr/share/pipewire/pipewire-pulse.conf'])
    wait_for(['/usr/bin/pactl', 'info'])
    start(['/usr/bin/wireplumber'])
    # Publish playback and the redirected Windows microphone for dictation.
    start(['/usr/bin/pw-cli', '-m', '-d', 'load-module', 'libpipewire-module-xrdp',
           'sink.node.latency=2048', 'sink.stream.props={node.name=xrdp-sink}',
           'source.stream.props={node.name=xrdp-source}'])
    for _ in range(100):
        sinks = wait_for(['/usr/bin/pactl', 'list', 'short', 'sinks'])
        if any('xrdp-sink' in line for line in sinks.splitlines()): break
        time.sleep(0.1)
    else: raise RuntimeError('xrdp audio sink is missing')
    subprocess.run(['/usr/bin/pactl', 'set-default-sink', 'xrdp-sink'], check=True)
    for _ in range(100):
        sources = wait_for(['/usr/bin/pactl', 'list', 'short', 'sources'])
        if any(line.split()[1:2] == ['xrdp-source'] for line in sources.splitlines()): break
        time.sleep(0.1)
    else: raise RuntimeError('xrdp microphone source is missing')
    subprocess.run(['/usr/bin/pactl', 'set-default-source', 'xrdp-source'], check=True)
    subprocess.run(['/usr/bin/pactl', 'set-source-mute', 'xrdp-source', '0'], check=True)
    # libpulse clients on the already-running XFCE display discover this socket.
    subprocess.run(['/usr/bin/xprop', '-root', '-f', 'PULSE_SERVER', '8s', '-set',
                    'PULSE_SERVER', os.environ['PULSE_SERVER']], check=True)
    ready.write_text('xrdp-sink\nxrdp-source\n')
    while all(child.poll() is None for child in children): time.sleep(1)
    raise RuntimeError('Audio worker stopped')
finally:
    cleanup()
AUDIO_SESSION
cat > "$stage/remoteagents-desktop-audio.service" <<AUDIO_UNIT
[Unit]
Description=RemoteAgents SSH desktop audio (PipeWire)
Requires=remoteagents-desktop-x.service remoteagents-desktop-clipboard.service
After=remoteagents-desktop-x.service remoteagents-desktop-clipboard.service
[Service]
Type=simple
User=$server_user
Group=$server_user
RuntimeDirectory=remoteagents-desktop-audio
RuntimeDirectoryMode=0700
UMask=0077
PrivateNetwork=yes
RestrictAddressFamilies=AF_UNIX
NoNewPrivileges=true
Environment=XDG_RUNTIME_DIR=/run/remoteagents-desktop-audio
Environment=PULSE_SERVER=unix:/run/remoteagents-desktop-audio/pulse/native
Environment=DISPLAY=:98
Environment=XAUTHORITY=/run/remoteagents-desktop-x/Xauthority
Environment=XRDP_SESSION=1
Environment=XRDP_SOCKET_PATH=/run/remoteagents-desktop-clipboard
Environment=XRDP_PULSE_SINK_SOCKET=xrdp_chansrv_audio_out_socket_98
Environment=XRDP_PULSE_SOURCE_SOCKET=xrdp_chansrv_audio_in_socket_98
ExecStart=/usr/bin/dbus-run-session -- /usr/bin/python3 -I $install_dir/audio-session.py
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
AUDIO_UNIT
changed=0
for file in audio-session.py remoteagents-desktop-audio.service; do
  target="$install_dir/$file"
  [[ $file != *.service ]] || target="/etc/systemd/system/$file"
  if ! cmp -s "$stage/$file" "$target"; then install -m 0644 "$stage/$file" "$target"; changed=1; fi
done
python3 -I - "$install_dir" <<'AUDIO_CONFIG'
import configparser, re, sys
from pathlib import Path
base=Path(sys.argv[1])
path=base/'xrdp.ini'
text=path.read_text()
config=configparser.ConfigParser()
config.read_string(text)
assert config.get('Desktop','chansrvport') == '/run/remoteagents-desktop-clipboard/xrdp_chansrv_socket_98'
assert config.get('Globals','port').startswith('unix://')
updated=re.sub(r'(?m)^rdpsnd=(?:false|true)$', 'rdpsnd=true', text)
updated=re.sub(r'(?m)^drdynvc=(?:false|true)$', 'drdynvc=true', updated)
checked=configparser.ConfigParser(); checked.read_string(updated)
assert checked.getboolean('Channels','rdpsnd')
assert checked.getboolean('Channels','drdynvc')
if updated != text: path.write_text(updated)
path=base/'session.py'
text=path.read_text()
line="env['PULSE_SERVER'] = 'unix:/run/remoteagents-desktop-audio/pulse/native'"
if line not in text:
    assert 'env = os.environ.copy()' in text
    path.write_text(text.replace('env = os.environ.copy()', 'env = os.environ.copy()\n'+line, 1))
AUDIO_CONFIG
# Existing XFCE processes cannot inherit newly added session environment variables.
# libpulse also reads the per-user client configuration for future connections.
runuser -u "$server_user" -- python3 -I - <<'AUDIO_CLIENT'
from pathlib import Path
folder = Path.home()/'.config'/'pulse'
folder.mkdir(parents=True, exist_ok=True)
path = folder/'client.conf'
if path.is_symlink(): raise RuntimeError('Refusing symlinked PulseAudio client configuration')
text = path.read_text() if path.exists() else ''
lines = [line for line in text.splitlines() if line.partition('=')[0].strip() != 'default-server']
lines.append('default-server = unix:/run/remoteagents-desktop-audio/pulse/native')
path.write_text('\n'.join(lines)+'\n')
AUDIO_CLIENT
systemd-analyze verify /etc/systemd/system/remoteagents-desktop-audio.service
systemctl daemon-reload
if (( changed )) && systemctl is-active --quiet remoteagents-desktop-audio.service; then
  systemctl restart remoteagents-desktop-audio.service
else
  systemctl enable --now remoteagents-desktop-audio.service
fi
for attempt in {1..100}; do
  [[ ! -f /run/remoteagents-desktop-audio/audio.ready ]] || break
  sleep 0.1
done
[[ -f /run/remoteagents-desktop-audio/audio.ready ]] || { echo 'Audio is not ready. The existing desktop was preserved.' >&2; exit 12; }
runuser -u "$server_user" -- env PULSE_SERVER=unix:/run/remoteagents-desktop-audio/pulse/native pactl list short sinks | grep -q 'xrdp-sink'
runuser -u "$server_user" -- env PULSE_SERVER=unix:/run/remoteagents-desktop-audio/pulse/native pactl list short sources | awk '{print $2}' | grep -qx 'xrdp-source'
echo 'AUDIO_READY=xrdp-sink,xrdp-source; reconnect RDP and reopen the dictation application'
