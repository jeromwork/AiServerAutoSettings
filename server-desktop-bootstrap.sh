#!/usr/bin/env bash
# SSH-authenticated desktop proxy. Existing noVNC/browser sessions are not changed.
set -Eeuo pipefail
umask 077
server_user=${1:-remoteagents}
[[ $server_user =~ ^[a-z_][a-z0-9_-]{0,31}$ && $server_user != root ]] || exit 2
[[ $(id -u) == 0 ]] || exit 3
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 && $(dpkg --print-architecture) == amd64 ]] || exit 4
[[ -d /run/systemd/system ]] || exit 5
[[ $(id -u "$server_user") != 0 && $(getent passwd "$server_user" | cut -d: -f6) == /home/"$server_user" ]] || exit 6
install_dir=/usr/local/lib/remoteagents-desktop
# Trust gate precedes cached execution and privileged writes.
python3 -I - "$install_dir" <<'DESKTOP_TRUST'
import os, stat, sys
from pathlib import Path
def trusted(path):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise SystemExit('Unsafe desktop path metadata: ' + str(path))
folder = Path(sys.argv[1])
for path in map(Path, ('/', '/usr', '/usr/local', '/usr/local/lib', '/etc', '/etc/systemd', '/etc/systemd/system', '/run')):
    trusted(path)
for name in ('remoteagents-desktop-x.service', 'remoteagents-desktop-vnc.service', 'remoteagents-desktop-rdp.service', 'remoteagents-desktop-clipboard.service'):
    path = Path('/etc/systemd/system') / name
    if os.path.lexists(path): trusted(path)
if os.path.lexists(folder):
    trusted(folder)
    for path in folder.rglob('*'): trusted(path)
DESKTOP_TRUST
write_desktop_checker() {
cat > "$install_dir/check.py" <<'DESKTOP_CHECK'
import configparser, json, os, pwd, re, socket, ssl, stat, subprocess
from pathlib import Path
BASE=Path('/usr/local/lib/remoteagents-desktop')
UNITS=('remoteagents-desktop-x.service','remoteagents-desktop-vnc.service','remoteagents-desktop-rdp.service')
def output(args): return subprocess.check_output(args,text=True).strip()
def check():
    config=configparser.ConfigParser()
    config.read(BASE/'xrdp.ini')
    assert config.get('Globals','port') == 'unix://./run/remoteagents-desktop-rdp/rdp.socket'
    ui=config['Globals']
    assert ui['ls_logo_transform'] == 'scale'
    logo=tuple(int(ui['ls_logo_'+key]) for key in ('x_pos','y_pos','width','height'))
    assert logo[1]+logo[3] < int(ui['ls_input_y_pos'])
    for name in ('ok','cancel'):
        button=tuple(int(ui['ls_btn_'+name+'_'+key]) for key in ('x_pos','y_pos','width','height'))
        assert not (logo[0]<button[0]+button[2] and button[0]<logo[0]+logo[2] and
                    logo[1]<button[1]+button[3] and button[1]<logo[1]+logo[3]),'Logo intercepts button clicks'
        assert button[1]+button[3] < int(ui['ls_height'])
    assert config.get('Desktop','lib') == 'libvnc.so' and config.get('Desktop','port') == '5901'
    assert not any(value.startswith('ask') for value in config['Desktop'].values())
    assert 'pamusername' not in config['Desktop']
    ids=[int(output(['systemctl','show',unit,'-p','MainPID','--value'])) for unit in UNITS]
    assert all(pid>1 for pid in ids)
    uid=pwd.getpwnam(output(['systemctl','show',UNITS[0],'-p','User','--value'])).pw_uid
    assert uid != 0
    for pid in ids: assert Path('/proc/'+str(pid)).stat().st_uid == uid
    host_ns=os.stat('/proc/1/ns/net').st_ino
    ns=[os.stat('/proc/'+str(pid)+'/ns/net').st_ino for pid in ids]
    assert ns[0] == host_ns and ns[1] == ns[2] and ns[1] != host_ns
    for name,kind in (('/run/remoteagents-desktop-rdp','dir'),('/run/remoteagents-desktop-rdp/rdp.socket','socket'),
                      ('/run/remoteagents-desktop-x','dir'),('/run/remoteagents-desktop-x/Xauthority','file')):
        info=os.lstat(name)
        assert info.st_uid == uid and stat.S_IMODE(info.st_mode) == (0o700 if kind=='dir' else 0o600),name
        assert {'dir':stat.S_ISDIR,'socket':stat.S_ISSOCK,'file':stat.S_ISREG}[kind](info.st_mode)
    process_ids=set()
    for unit in UNITS:
        group=output(['systemctl','show',unit,'-p','ControlGroup','--value'])
        for path in (Path('/sys/fs/cgroup')/group.lstrip('/')).rglob('cgroup.procs'):
            for pid in map(int,path.read_text().split()):
                if unit == UNITS[0] and pid != ids[0]:
                    # XFCE applications may legitimately serve localhost (e.g. a
                    # development site or an OAuth callback). Only Xvfb itself
                    # is a transport component requiring no host TCP listener.
                    try: executable = Path(os.readlink(f'/proc/{pid}/exe')).name
                    except FileNotFoundError: continue
                    if executable != 'Xvfb': continue
                process_ids.add(pid)
    for family in ('-4','-6'):
        for line in output(['ss','-H',family,'-ltnp']).splitlines():
            assert not process_ids.intersection(map(int,re.findall(r'pid=(\d+)',line))),line
    internal=output(['nsenter','-t',str(ids[1]),'-n','ss','-H','-ltn'])
    assert [line.split()[3] for line in internal.splitlines()] == ['127.0.0.1:5901'],internal
    for unit in ('xrdp.service','xrdp-sesman.service'):
        assert output(['systemctl','show',unit,'-p','MainPID','--value']) == '0'
    # Handshake only: no pixels, clipboard, or account data.
    probe="import socket;s=socket.create_connection(('127.0.0.1',5901),5);assert s.recv(12).startswith(b'RFB ');s.sendall(b'RFB 003.008\\n');n=s.recv(1)[0];assert 1 in s.recv(n);s.sendall(bytes([1]));assert s.recv(4)==bytes(4);s.close()"
    subprocess.run(['nsenter','-t',str(ids[1]),'-n','python3','-I','-c',probe],check=True)
    request=bytes.fromhex('030000130ee000000000000100080001000000')
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(5)
        client.connect('/run/remoteagents-desktop-rdp/rdp.socket')
        client.sendall(request)
        reply=b''
        while len(reply)<19:
            chunk=client.recv(19-len(reply))
            if not chunk: raise RuntimeError('Incomplete RDP negotiation')
            reply+=chunk
        assert reply[:2]==b'\x03\x00' and reply[11]==2 and reply[13:]==bytes.fromhex('080001000000')
        context=ssl.create_default_context(cafile=str(BASE/'tls/cert.pem'))
        context.minimum_version=ssl.TLSVersion.TLSv1_2
        with context.wrap_socket(client,server_hostname='127.0.0.1') as secure:
            protocol=secure.version()
            assert protocol in ('TLSv1.2','TLSv1.3')
    return {'auth':'SSH-only Unix socket','rdp':protocol,'vnc':'private network namespace','host_component_tcp_listeners':0}
if __name__=='__main__': print(json.dumps(check()))
DESKTOP_CHECK
chmod 0644 "$install_dir/check.py"
}
configure_clipboard() {
  # Standalone chansrv supplies Unicode text without sesman, PAM, or a TCP listener.
  # The package socket directory is shared; bind a private runtime over it ONLY
  # inside this service's mount namespace. Existing desktop workers are untouched.
  python3 -I - <<'DESKTOP_CLIPBOARD_BINARY'
from pathlib import Path
binary = Path('/usr/sbin/xrdp-chansrv').read_bytes()
for template in (b'/run/xrdp/sockdir/xrdp_chansrv_socket_%d\0', b'/run/xrdp/sockdir/xrdpapi_%d\0'):
    assert template in binary, 'Unsupported chansrv package socket path'
DESKTOP_CLIPBOARD_BINARY
  cat > "$install_dir/chansrv.ini" <<'DESKTOP_CLIPBOARD_CONFIG'
[Globals]
ListenAddress=127.0.0.1
[Security]
RestrictInboundClipboard=file,image
RestrictOutboundClipboard=file,image
[Chansrv]
EnableFuseMount=false
FileUmask=077
[ChansrvLogging]
LogLevel=WARNING
EnableSyslog=false
DESKTOP_CLIPBOARD_CONFIG
  cat > "$install_dir/clipboard-socket.py" <<'DESKTOP_CLIPBOARD_SOCKET'
import os, stat, sys, time
from pathlib import Path
folder = Path('/run/remoteagents-desktop-clipboard')
info = folder.lstat()
assert stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700
paths = [folder / name for name in ('xrdp_chansrv_socket_98', 'xrdpapi_98')]
for attempt in range(100):
    if all(os.path.lexists(path) for path in paths): break
    time.sleep(0.05)
for path in paths:
    info = path.lstat()
    assert not stat.S_ISLNK(info.st_mode) and stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid(), 'Unsafe clipboard socket metadata'
    os.chmod(path, 0o600, follow_symlinks=False)
    assert stat.S_IMODE(path.lstat().st_mode) == 0o600
DESKTOP_CLIPBOARD_SOCKET
  cat > /etc/systemd/system/remoteagents-desktop-clipboard.service <<DESKTOP_CLIPBOARD_UNIT
[Unit]
Description=RemoteAgents private Unicode text clipboard
Requires=remoteagents-desktop-x.service
After=remoteagents-desktop-x.service
[Service]
Type=simple
User=$server_user
Group=$server_user
RuntimeDirectory=remoteagents-desktop-clipboard
RuntimeDirectoryMode=0700
UMask=0077
PrivateNetwork=yes
RestrictAddressFamilies=AF_UNIX
NoNewPrivileges=true
BindPaths=/run/remoteagents-desktop-clipboard:/run/xrdp/sockdir
BindReadOnlyPaths=$install_dir/chansrv.ini:/etc/xrdp/sesman.ini
Environment=DISPLAY=:98
Environment=XAUTHORITY=/run/remoteagents-desktop-x/Xauthority
Environment=CHANSRV_LOG_PATH=/run/remoteagents-desktop-clipboard
ExecStart=/usr/sbin/xrdp-chansrv
ExecStartPost=/usr/bin/python3 -I $install_dir/clipboard-socket.py
Restart=on-failure
RestartSec=2
[Install]
WantedBy=multi-user.target
DESKTOP_CLIPBOARD_UNIT
  chmod 0644 "$install_dir/chansrv.ini" "$install_dir/clipboard-socket.py"
  chmod 0644 /etc/systemd/system/remoteagents-desktop-clipboard.service
  systemd-analyze verify /etc/systemd/system/remoteagents-desktop-clipboard.service
  systemctl daemon-reload
  systemctl enable --now remoteagents-desktop-clipboard.service
  python3 -I - "$server_user" <<'DESKTOP_CLIPBOARD_READY'
import configparser, os, pwd, stat, subprocess, sys
from pathlib import Path
uid = pwd.getpwnam(sys.argv[1]).pw_uid
folder = Path('/run/remoteagents-desktop-clipboard')
info = folder.lstat()
assert stat.S_ISDIR(info.st_mode) and info.st_uid == uid and stat.S_IMODE(info.st_mode) == 0o700
for name in ('xrdp_chansrv_socket_98', 'xrdpapi_98'):
    info = (folder / name).lstat()
    assert stat.S_ISSOCK(info.st_mode) and info.st_uid == uid and stat.S_IMODE(info.st_mode) == 0o600
pid = int(subprocess.check_output(['systemctl','show','remoteagents-desktop-clipboard','-p','MainPID','--value']))
assert pid > 0 and Path('/proc',str(pid)).stat().st_uid == uid
assert os.stat('/proc/self/ns/net').st_ino != os.stat(f'/proc/{pid}/ns/net').st_ino
assert not subprocess.check_output(['nsenter','-t',str(pid),'-n','ss','-H','-ltn']).strip(), 'Clipboard TCP listener forbidden'
for name in ('xrdp_chansrv_socket_98', 'xrdpapi_98'):
    outside = os.stat(folder / name)
    inside = subprocess.check_output(['nsenter','-t',str(pid),'-m','stat','-c','%d:%i', '/run/xrdp/sockdir/' + name],text=True).strip()
    assert inside == f'{outside.st_dev}:{outside.st_ino}', 'Clipboard private mount mismatch'
DESKTOP_CLIPBOARD_READY
  # Change the module endpoint for FUTURE connections, preserving the current worker.
  python3 -I - "$install_dir/xrdp.ini" <<'DESKTOP_CLIPBOARD_INI'
import configparser, re, sys
from pathlib import Path

def add_desktop_chansrvport(text):
    match = re.search(r'(?ms)^\[Desktop\][ \t]*\n(.*?)(?=^\[|\Z)', text)
    if not match: raise ValueError('Missing Desktop section')
    body = re.sub(r'(?m)^[ \t]*chansrvport[ \t]*=.*(?:\n|$)', '', match.group(1))
    body = body.rstrip('\n') + '\nchansrvport=/run/remoteagents-desktop-clipboard/xrdp_chansrv_socket_98\n'
    return text[:match.start(1)] + body + text[match.end(1):]

path = Path(sys.argv[1])
config = configparser.ConfigParser()
config.read(path)
value = '/run/remoteagents-desktop-clipboard/xrdp_chansrv_socket_98'
if config.get('Desktop','chansrvport',fallback=None) != value:
    updated = add_desktop_chansrvport(path.read_text())
    checked = configparser.ConfigParser(); checked.read_string(updated)
    assert checked.get('Desktop','chansrvport') == value
    assert all('chansrvport' not in checked[section] for section in checked.sections() if section != 'Desktop')
    path.write_text(updated)
print('DESKTOP_CLIPBOARD=private-unix-unicode-text-next-connection')
DESKTOP_CLIPBOARD_INI
}
if [[ -f $install_dir/.remoteagents-managed && $(cat "$install_dir/.remoteagents-managed") == desktop-ssh-v2 ]]; then
  write_desktop_checker
fi
# Repair only the login-window geometry of an already managed installation.
# Existing RDP workers and the desktop keep running; new connections read it.
if [[ -f $install_dir/.remoteagents-managed && $(cat "$install_dir/.remoteagents-managed") == desktop-ssh-v2 && -f $install_dir/xrdp.ini ]]; then
  python3 -I - "$install_dir/xrdp.ini" <<'DESKTOP_LAYOUT'
import sys
from pathlib import Path
path = Path(sys.argv[1])
values = dict(ls_height='210', ls_input_y_pos='95', ls_btn_ok_y_pos='155', ls_btn_cancel_y_pos='155',
              ls_logo_transform='scale', ls_logo_width='96', ls_logo_height='56', ls_logo_x_pos='127', ls_logo_y_pos='15')
lines = path.read_text().splitlines()
result = []
section = None
inserted = False
for line in lines:
    if line.startswith('[') and line.endswith(']'):
        if section == 'Globals':
            result.extend(key + '=' + value for key, value in values.items())
            inserted = True
        section = line[1:-1]
    key = line.partition('=')[0].strip()
    if key not in values: result.append(line)
if section == 'Globals':
    result.extend(key + '=' + value for key, value in values.items())
    inserted = True
if not inserted: raise SystemExit('Managed desktop configuration is missing its Globals section')
updated = '\n'.join(result) + '\n'
if updated != path.read_text(): path.write_text(updated)
DESKTOP_LAYOUT
fi
if [[ -f $install_dir/.remoteagents-managed && $(cat "$install_dir/.remoteagents-managed") == desktop-ssh-v2 ]] && python3 "$install_dir/check.py" >/dev/null 2>&1; then
  configure_clipboard
  echo 'DESKTOP_READY=UNIX:/run/remoteagents-desktop-rdp/rdp.socket'
  exit 0
fi
if [[ -f $install_dir/.remoteagents-managed && $(cat "$install_dir/.remoteagents-managed") == desktop-ssh-v2 ]] && systemctl is-active --quiet remoteagents-desktop-x.service; then
  echo 'An existing desktop is active but a readiness check failed. It was preserved; automatic restart is refused.' >&2
  exit 12
fi
[[ ! -e $install_dir || ( -d $install_dir && -f $install_dir/.remoteagents-managed ) ]] || exit 7
if [[ ! -f $install_dir/.remoteagents-managed ]] && dpkg-query -W -f='${Status}' xrdp 2>/dev/null | grep -q '^install ok installed$'; then
  echo 'Unmanaged xrdp installation; refusing to replace it.' >&2; exit 8
fi
install -d -m 0755 "$install_dir"
printf 'desktop-ssh-installing\n' > "$install_dir/.remoteagents-managed"
if systemctl is-active --quiet xrdp-sesman.service; then
  sesman_pid=$(systemctl show xrdp-sesman.service -p MainPID --value)
  if pgrep -P "$sesman_pid" >/dev/null; then
    echo 'An existing RDP session is active. Disconnect it before migration.' >&2; exit 11
  fi
fi
systemctl mask --now xrdp.service xrdp-sesman.service
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
apt-get update
apt-get install -y --no-install-recommends xrdp xvfb xauth x11-utils x11vnc xfce4 xfce4-terminal dbus-x11 x11-xserver-utils xdg-utils fonts-liberation ca-certificates curl openssl util-linux
if ! command -v google-chrome-stable >/dev/null; then
  stage=$(mktemp -d /tmp/remoteagents-desktop.XXXXXXXX)
  trap 'rm -rf -- "$stage"' EXIT
  curl --fail --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o "$stage/chrome.deb"
  [[ $(dpkg-deb -f "$stage/chrome.deb" Package) == google-chrome-stable && $(dpkg-deb -f "$stage/chrome.deb" Architecture) == amd64 ]] || exit 9
  chmod 0755 "$stage"; chmod 0644 "$stage/chrome.deb"
  apt-get install -y --no-install-recommends "$stage/chrome.deb"
fi
getent group remoteagents-desktop >/dev/null || groupadd --system remoteagents-desktop
usermod -a -G remoteagents-desktop "$server_user"
install -d -o root -g remoteagents-desktop -m 0750 "$install_dir/tls"
if [[ ! -f $install_dir/tls/cert.pem ]]; then
  openssl req -x509 -nodes -newkey rsa:3072 -sha256 -days 1825 -keyout "$install_dir/tls/key.pem" -out "$install_dir/tls/cert.pem" -subj '/CN=localhost' -addext 'subjectAltName=IP:127.0.0.1,DNS:localhost' >/dev/null 2>&1
fi
chown root:remoteagents-desktop "$install_dir/tls/key.pem"
chmod 0640 "$install_dir/tls/key.pem"; chmod 0644 "$install_dir/tls/cert.pem"
cat > "$install_dir/session.py" <<'DESKTOP_SESSION'
import os, secrets, signal, subprocess, time
from pathlib import Path
os.umask(0o077)
Path('/run/remoteagents-desktop-x/host-network').write_text(str(os.stat('/proc/self/ns/net').st_ino))
env = os.environ.copy()
env['PULSE_SERVER'] = 'unix:/run/remoteagents-desktop-audio/pulse/native'
env.update(DISPLAY=':98', XAUTHORITY='/run/remoteagents-desktop-x/Xauthority',
           XDG_CURRENT_DESKTOP='XFCE', XDG_SESSION_DESKTOP='xfce', XDG_SESSION_TYPE='x11')
for key in ('DBUS_SESSION_BUS_ADDRESS','SESSION_MANAGER'): env.pop(key,None)
children = []
def stop(*_):
    for child in reversed(children):
        if child.poll() is None: child.terminate()
    for child in reversed(children):
        try: child.wait(timeout=5)
        except subprocess.TimeoutExpired: child.kill()
    raise SystemExit(0)
signal.signal(signal.SIGTERM,stop)
signal.signal(signal.SIGINT,stop)
# Generate only this new X session's private authorization; never read another profile.
subprocess.run(['xauth','-q','-f',env['XAUTHORITY']],
               input='add :98 . '+secrets.token_hex(16)+'\n',text=True,check=True,
               stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
os.chmod(env['XAUTHORITY'],0o600)
children.append(subprocess.Popen(['Xvfb',':98','-screen','0','1440x900x24','-nolisten','tcp','-auth',env['XAUTHORITY']],env=env))
for _ in range(100):
    if children[0].poll() is not None: raise SystemExit('Desktop X server stopped')
    if subprocess.run(['xdpyinfo'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode == 0: break
    time.sleep(0.1)
else: stop()
work=Path.home()/'work'
work.mkdir(exist_ok=True)
children.append(subprocess.Popen(['dbus-run-session','--','startxfce4'],env=env,cwd=work))
while all(child.poll() is None for child in children): time.sleep(1)
stop()
DESKTOP_SESSION
cat > "$install_dir/chrome" <<'DESKTOP_CHROME'
#!/bin/sh
set -eu
umask 077
mkdir -p "$HOME/.local/share/remoteagents/desktop-browser"
exec google-chrome-stable --user-data-dir="$HOME/.local/share/remoteagents/desktop-browser" --no-first-run --no-default-browser-check --disable-dev-shm-usage "$@"
DESKTOP_CHROME
chmod 0755 "$install_dir/chrome"
cat > "$install_dir/xrdp.ini" <<DESKTOP_CONFIG
[Globals]
ini_version=1
fork=true
port=unix://./run/remoteagents-desktop-rdp/rdp.socket
security_layer=tls
crypt_level=high
ssl_protocols=TLSv1.2, TLSv1.3
certificate=$install_dir/tls/cert.pem
key_file=$install_dir/tls/key.pem
autorun=Desktop
allow_channels=true
require_credentials=false
allow_multimon=false
bitmap_cache=true
bitmap_compression=true
max_bpp=32
use_fastpath=both
ls_title=Desktop (SSH) - OK
ls_width=350
ls_height=210
ls_logo_transform=scale
ls_logo_width=96
ls_logo_height=56
ls_logo_x_pos=127
ls_logo_y_pos=15
ls_bg_color=dedede
ls_top_window_bg_color=202b3b
ls_label_x_pos=15
ls_label_width=70
ls_input_x_pos=90
ls_input_width=230
ls_input_y_pos=95
ls_btn_ok_x_pos=140
ls_btn_ok_y_pos=155
ls_btn_ok_width=85
ls_btn_ok_height=30
ls_btn_cancel_x_pos=240
ls_btn_cancel_y_pos=155
ls_btn_cancel_width=85
ls_btn_cancel_height=30
[Logging]
LogFile=/run/remoteagents-desktop-rdp/xrdp.log
LogLevel=WARNING
EnableSyslog=false
[Channels]
cliprdr=true
rdpdr=false
rdpsnd=true
drdynvc=false
[Desktop]
name=Desktop (SSH)
lib=libvnc.so
ip=127.0.0.1
port=5901
DESKTOP_CONFIG
# Fixed VNC proxy: no port=-1, pamusername, PAM authentication, or sesman.
cat > "$install_dir/namespace-guard.py" <<'DESKTOP_NAMESPACE'
import os, stat, time
path='/run/remoteagents-desktop-x/host-network'
for _ in range(100):
    try: info=os.lstat(path)
    except FileNotFoundError: time.sleep(0.1); continue
    assert stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode)==0o600
    with open(path) as source: host=int(source.read())
    assert os.stat('/proc/self/ns/net').st_ino != host, 'Private network namespace is required'
    break
else: raise SystemExit('Host network reference is unavailable')
DESKTOP_NAMESPACE
cat > /etc/systemd/system/remoteagents-desktop-x.service <<DESKTOP_X_UNIT
[Unit]
Description=RemoteAgents private XFCE display
After=network.target
[Service]
Type=simple
User=$server_user
Group=$server_user
RuntimeDirectory=remoteagents-desktop-x
RuntimeDirectoryMode=0700
UMask=0077
ExecStart=/usr/bin/python3 -I $install_dir/session.py
Restart=on-failure
KillMode=control-group
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
DESKTOP_X_UNIT
cat > /etc/systemd/system/remoteagents-desktop-vnc.service <<DESKTOP_VNC_UNIT
[Unit]
Description=RemoteAgents isolated VNC backend
Requires=remoteagents-desktop-x.service
After=remoteagents-desktop-x.service
[Service]
Type=simple
User=$server_user
Group=$server_user
UMask=0077
PrivateNetwork=yes
RestrictAddressFamilies=AF_UNIX AF_INET
NoNewPrivileges=true
ExecStartPre=/usr/bin/python3 -I $install_dir/namespace-guard.py
ExecStart=/usr/bin/x11vnc -display :98 -auth /run/remoteagents-desktop-x/Xauthority -forever -shared -nopw -listen 127.0.0.1 -rfbport 5901 -rfbportv6 0 -noipv6 -no6 -noxdamage -quiet
Restart=on-failure
RestartSec=2
[Install]
WantedBy=multi-user.target
DESKTOP_VNC_UNIT
cat > /etc/systemd/system/remoteagents-desktop-rdp.service <<DESKTOP_RDP_UNIT
[Unit]
Description=RemoteAgents SSH-only RDP Unix proxy
Requires=remoteagents-desktop-vnc.service
After=remoteagents-desktop-vnc.service
JoinsNamespaceOf=remoteagents-desktop-vnc.service
[Service]
Type=simple
User=$server_user
Group=$server_user
SupplementaryGroups=remoteagents-desktop
RuntimeDirectory=remoteagents-desktop-rdp
RuntimeDirectoryMode=0700
UMask=0077
PrivateNetwork=yes
RestrictAddressFamilies=AF_UNIX AF_INET
NoNewPrivileges=true
ExecStartPre=/usr/bin/python3 -I $install_dir/namespace-guard.py
ExecStart=/usr/sbin/xrdp --nodaemon --config $install_dir/xrdp.ini
ExecStartPost=/usr/bin/python3 -I $install_dir/socket-mode.py
Restart=on-failure
RestartSec=2
[Install]
WantedBy=multi-user.target
DESKTOP_RDP_UNIT
cat > "$install_dir/socket-mode.py" <<'DESKTOP_SOCKET'
import os, stat, time
path='/run/remoteagents-desktop-rdp/rdp.socket'
for _ in range(100):
    try: info=os.lstat(path)
    except FileNotFoundError: time.sleep(0.1); continue
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
        raise SystemExit('Unsafe RDP Unix socket')
    os.chmod(path,0o600)
    break
else: raise SystemExit('RDP Unix socket was not created')
DESKTOP_SOCKET
runuser -u "$server_user" -- sh -s <<'DESKTOP_SHORTCUTS'
set -eu
umask 077
mkdir -p "$HOME/Desktop" "$HOME/work"
cat > "$HOME/Desktop/RemoteAgents-Chrome.desktop" <<'CHROME_SHORTCUT'
[Desktop Entry]
Version=1.0
Type=Application
Name=Chrome
Comment=Отдельный профиль рабочего стола; прежний браузер продолжает работать.
Exec=/usr/local/lib/remoteagents-desktop/chrome about:blank
Icon=google-chrome
Terminal=false
CHROME_SHORTCUT
cat > "$HOME/Desktop/RemoteAgents-Codex.desktop" <<'CODEX_SHORTCUT'
[Desktop Entry]
Version=1.0
Type=Application
Name=Терминал Codex
Exec=xfce4-terminal --hold --command "/usr/local/lib/remoteagents/codex-session chat"
Icon=utilities-terminal
Terminal=false
CODEX_SHORTCUT
cat > "$HOME/Desktop/RemoteAgents-Terminal.desktop" <<'TERMINAL_SHORTCUT'
[Desktop Entry]
Version=1.0
Type=Application
Name=Терминал сервера
Exec=xfce4-terminal
Icon=utilities-terminal
Terminal=false
TERMINAL_SHORTCUT
chmod 0755 "$HOME/Desktop/RemoteAgents-"*.desktop
DESKTOP_SHORTCUTS
write_desktop_checker
chmod 0644 "$install_dir/session.py" "$install_dir/namespace-guard.py" "$install_dir/socket-mode.py" "$install_dir/xrdp.ini"
python3 -m py_compile "$install_dir/session.py" "$install_dir/socket-mode.py" "$install_dir/check.py"
systemd-analyze verify /etc/systemd/system/remoteagents-desktop-{x,vnc,rdp}.service
systemctl daemon-reload
systemctl try-restart remoteagents-desktop-x.service
systemctl reset-failed remoteagents-desktop-x.service remoteagents-desktop-vnc.service remoteagents-desktop-rdp.service
systemctl enable --now remoteagents-desktop-x.service remoteagents-desktop-vnc.service remoteagents-desktop-rdp.service
for attempt in {1..25}; do
  if python3 "$install_dir/check.py"; then
    configure_clipboard
    printf 'desktop-ssh-v2\n' > "$install_dir/.remoteagents-managed"
    echo 'DESKTOP_READY=UNIX:/run/remoteagents-desktop-rdp/rdp.socket'
    exit 0
  fi
  sleep 1
done
systemctl stop remoteagents-desktop-rdp.service remoteagents-desktop-vnc.service
echo 'SSH-only readiness failed; private proxy stopped. Existing noVNC was not changed.' >&2
exit 10
