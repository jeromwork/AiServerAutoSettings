#!/usr/bin/env bash
# HAPP-compatible VLESS/REALITY server. No credentials are written to stdout.
set -Eeuo pipefail
umask 077
[[ $(id -u) == 0 ]] || { echo 'Root is required.' >&2; exit 3; }
endpoint=${1:?server address required}
port=${2:-8443}
[[ $endpoint =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$ && $port =~ ^[0-9]{2,5}$ ]] || exit 4
((port >= 1024 && port <= 65535)) || exit 4
command -v python3 >/dev/null || { echo 'Python 3 is required.' >&2; exit 5; }
[[ $(uname -m) == x86_64 ]] || { echo 'This release is for x86_64.' >&2; exit 5; }
if ss -H -lnt "sport = :$port" | grep -q . && ! systemctl is-active --quiet remoteagents-happ; then
    echo 'The requested VPN port is already occupied.' >&2; exit 6
fi
export HAPP_ENDPOINT="$endpoint" HAPP_PORT="$port"
python3 - <<'PY'
import hashlib, io, json, os, pathlib, re, secrets, subprocess, urllib.request, uuid, zipfile
binary = pathlib.Path('/usr/local/bin/remoteagents-xray')
version = 'v26.10.31'
def fetch(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'RemoteAgents-Happ-Setup'})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()
if not binary.exists():
    print('Downloading official Xray release; checking SHA256.', flush=True)
    release = json.loads(fetch('https://api.github.com/repos/XTLS/Xray-core/releases/tags/' + version))
    asset = next(a for a in release['assets'] if a['name'] == 'Xray-linux-64.zip')
    digest = asset.get('digest', '')
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', digest):
        raise SystemExit('Release has no SHA256 digest; refusing installation.')
    url = 'https://github.com/XTLS/Xray-core/releases/download/' + version + '/Xray-linux-64.zip'
    archive = fetch(url)
    if 'sha256:' + hashlib.sha256(archive).hexdigest() != digest:
        raise SystemExit('Xray SHA256 mismatch.')
    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
        executable = bundle.read('xray')
    binary.write_bytes(executable)
    binary.chmod(0o755)
    print('Xray SHA256 verified.', flush=True)
subprocess.run(['id', '-u', 'remoteagents-happ'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0 or subprocess.run(
    ['useradd', '--system', '--no-create-home', '--shell', '/usr/sbin/nologin', 'remoteagents-happ'], check=True)
import grp
gid = grp.getgrnam('remoteagents-happ').gr_gid
config_dir = pathlib.Path('/usr/local/etc/remoteagents-happ')
state_dir = pathlib.Path('/var/lib/remoteagents-happ')
for directory in (config_dir, state_dir):
    if directory.is_symlink():
        raise SystemExit('Refusing a symbolic link for managed state.')
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
config_dir.chmod(0o750)
os.chown(config_dir, 0, gid)
config_path = config_dir / 'config.json'
state_path = state_dir / 'connection.json'
if not config_path.exists() and not state_path.exists():
    keys = dict(line.split(':', 1) for line in subprocess.check_output([str(binary), 'x25519'], text=True).splitlines() if ':' in line)
    keys = {k.strip().lower().replace(' ', ''): v.strip() for k, v in keys.items()}
    private = keys['privatekey']
    public = keys.get('publickey') or keys.get('password(publickey)') or keys.get('password')
    if not public:
        raise SystemExit('Unrecognized Xray public key output.')
    client = str(uuid.uuid4())
    short_id = secrets.token_hex(8)
    sni = 'www.microsoft.com'
    config = {
        'log': {'loglevel': 'warning'},
        'inbounds': [{'listen': '0.0.0.0', 'port': int(os.environ['HAPP_PORT']), 'protocol': 'vless',
            'settings': {'clients': [{'id': client, 'flow': 'xtls-rprx-vision'}], 'decryption': 'none'},
            'streamSettings': {'network': 'tcp', 'security': 'reality', 'realitySettings': {
                'show': False, 'target': sni + ':443', 'xver': 0, 'serverNames': [sni],
                'privateKey': private, 'shortIds': [short_id]}}}],
        'outbounds': [{'protocol': 'freedom', 'tag': 'direct'}, {'protocol': 'blackhole', 'tag': 'blocked'}],
        'routing': {'rules': [{'type': 'field', 'ip': ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '127.0.0.0/8', '169.254.0.0/16', '::1/128', 'fc00::/7', 'fe80::/10'], 'outboundTag': 'blocked'}]}}
    config_path.write_text(json.dumps(config), encoding='utf-8')
    config_path.chmod(0o640)
    os.chown(config_path, 0, gid)
    state_path.write_text(json.dumps({'address': os.environ['HAPP_ENDPOINT'], 'port': int(os.environ['HAPP_PORT']),
        'id': client, 'public': public, 'short': short_id, 'sni': sni}), encoding='utf-8')
    state_path.chmod(0o600)
elif not (config_path.exists() and state_path.exists()):
    raise SystemExit('Incomplete configuration; refusing to replace credentials.')
subprocess.run([str(binary), 'run', '-test', '-config', str(config_path)], stdout=subprocess.DEVNULL, check=True)
PY
cat > /usr/local/bin/remoteagents-happ-link <<'LINK'
#!/usr/bin/python3
# Invoked only by the owner to import the private connection into HAPP.
import json, urllib.parse
with open('/var/lib/remoteagents-happ/connection.json') as source:
    c = json.load(source)
query = urllib.parse.urlencode({'encryption': 'none', 'security': 'reality', 'sni': c['sni'],
    'fp': 'chrome', 'pbk': c['public'], 'sid': c['short'], 'type': 'tcp', 'flow': 'xtls-rprx-vision'})
print('vless://' + c['id'] + '@' + c['address'] + ':' + str(c['port']) + '?' + query + '#My-server-HAPP')
LINK
chmod 700 /usr/local/bin/remoteagents-happ-link
cat > /etc/systemd/system/remoteagents-happ.service <<'UNIT'
[Unit]
Description=HAPP compatible VLESS REALITY server
After=network-online.target
Wants=network-online.target
[Service]
User=remoteagents-happ
Group=remoteagents-happ
ExecStart=/usr/local/bin/remoteagents-xray run -config /usr/local/etc/remoteagents-happ/config.json
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now remoteagents-happ
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw allow "$port/tcp" comment 'HAPP VPN'
fi
sleep 2
systemctl is-active --quiet remoteagents-happ
ss -H -lnt "sport = :$port" | grep -q .
echo "HAPP_SERVER_READY TCP $port"
