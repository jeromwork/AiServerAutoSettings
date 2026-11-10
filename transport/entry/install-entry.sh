#!/usr/bin/env bash
# Точка входа RemoteAgents на промежуточном сервере (RU VPS).
# Ставит sing-box с несколькими входами разных классов трафика и ведёт всё на основной сервер
# по уже работающему VLESS-Reality (upstream.json кладётся рядом заранее).
# Повторный запуск сохраняет ключи и пароли. Удаление: install-entry.sh --remove
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DIR=/opt/rd-entry
VER=1.14.4
UNIT=rd-entry
PORTS_UDP=(443 3478 8445)
PORTS_TCP=(8446 8447 8448)
DOMAIN="${ENTRY_DOMAIN:-}"   # имя для CDN (например entry.example.com); пусто — блок nginx не ставится

if [[ "${1:-}" == "--remove" ]]; then
  systemctl disable --now "$UNIT" 2>/dev/null || true
  rm -f /etc/systemd/system/$UNIT.service; systemctl daemon-reload
  for p in "${PORTS_UDP[@]}"; do ufw delete allow "$p/udp" >/dev/null 2>&1 || true; done
  for p in "${PORTS_TCP[@]}"; do ufw delete allow "$p/tcp" >/dev/null 2>&1 || true; done
  rm -f /etc/nginx/sites-enabled/rd-entry /etc/nginx/sites-available/rd-entry; nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
  rm -rf "$DIR"; echo removed; exit 0
fi

mkdir -p "$DIR"; chmod 700 "$DIR"; cd "$DIR"
[[ -s upstream.json ]] || { echo "нет $DIR/upstream.json (исходящий VLESS до основного сервера)"; exit 1; }

if [[ ! -x sing-box || "$(./sing-box version 2>/dev/null | head -1)" != *"$VER"* ]]; then
  curl -fsSL -o sb.tgz "https://github.com/SagerNet/sing-box/releases/download/v$VER/sing-box-$VER-linux-amd64.tar.gz"
  tar -xzf sb.tgz --strip-components=1 "sing-box-$VER-linux-amd64/sing-box"; rm -f sb.tgz
  sha256sum sing-box > sing-box.sha256
fi

# Сертификат: Let's Encrypt узла, если есть, иначе самоподписанный (клиент закрепляет его отпечаток).
CERT=$(ls -d /etc/letsencrypt/live/*/ 2>/dev/null | head -1 || true)
if [[ -n "$CERT" ]]; then
  cp -L "$CERT/fullchain.pem" cert.pem; cp -L "$CERT/privkey.pem" key.pem
else
  [[ -s cert.pem ]] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj "/CN=$(hostname)" -keyout key.pem -out cert.pem 2>/dev/null
fi
chmod 600 key.pem

[[ -s secrets.json ]] || python3 - "$DIR" <<'PY'
import json, secrets, subprocess, sys, uuid, base64
d = sys.argv[1]
kp = subprocess.run([d + '/sing-box', 'generate', 'reality-keypair'], capture_output=True, text=True, check=True).stdout
k = dict(l.split(': ', 1) for l in kp.strip().splitlines())
s = dict(
    hy2=secrets.token_urlsafe(18), hy2_obfs=secrets.token_urlsafe(18), tuic_uuid=str(uuid.uuid4()), tuic=secrets.token_urlsafe(18),
    trojan=secrets.token_urlsafe(18), vless_uuid=str(uuid.uuid4()), reality_private=k['PrivateKey'], reality_public=k['PublicKey'],
    short_id=secrets.token_hex(4), shadowtls=secrets.token_urlsafe(18), ss=base64.b64encode(secrets.token_bytes(16)).decode())
json.dump(s, open(d + '/secrets.json', 'w'))
PY
python3 - "$DIR" <<'PY2'
import json, secrets, sys
f = sys.argv[1] + '/secrets.json'; s = json.load(open(f))
s.setdefault('ws_path', '/' + secrets.token_urlsafe(12)); s.setdefault('ws_uuid', __import__('uuid').uuid4().__str__())
json.dump(s, open(f, 'w'))
PY2
chmod 600 secrets.json

# Сайт-прикрытие: отдаётся nginx и Hysteria2 любому, кто зайдёт без ключа.
if [[ -n "$DOMAIN" && ! -f /var/www/rd-decoy/index.html ]]; then bash "$SCRIPT_DIR/build-decoy.sh" "$DOMAIN"; fi

python3 - "$DIR" <<'PY'
import json, socket, sys, subprocess
d = sys.argv[1]; s = json.load(open(d + '/secrets.json')); up = json.load(open(d + '/upstream.json'))
up['tag'] = 'upstream'; up.pop('detour', None)
host = subprocess.run(['openssl', 'x509', '-in', d + '/cert.pem', '-noout', '-ext', 'subjectAltName'], capture_output=True, text=True).stdout
names = [x.strip()[4:] for x in host.replace('\n', ',').split(',') if x.strip().startswith('DNS:')]
sni = names[0] if names else socket.gethostname()
ip = subprocess.run(['curl', '-s4', '-m', '8', 'https://api.ipify.org'], capture_output=True, text=True).stdout.strip()
tls = dict(enabled=True, certificate_path=d + '/cert.pem', key_path=d + '/key.pem')
cover = 'ya.ru'
inb = [
    dict(type='hysteria2', tag='hy2', listen='::', listen_port=443, users=[dict(password=s['hy2'])], tls=dict(tls, alpn=['h3']), masquerade=('file:///var/www/rd-decoy' if __import__('os').path.isdir('/var/www/rd-decoy') else 'https://' + cover)),
    dict(type='hysteria2', tag='hy2-obfs', listen='::', listen_port=3478, users=[dict(password=s['hy2'])], obfs=dict(type='salamander', password=s['hy2_obfs']), tls=dict(tls, alpn=['h3'])),
    dict(type='tuic', tag='tuic', listen='::', listen_port=8445, users=[dict(uuid=s['tuic_uuid'], password=s['tuic'])], congestion_control='bbr', tls=dict(tls, alpn=['h3'])),
    dict(type='trojan', tag='trojan', listen='::', listen_port=8446, users=[dict(password=s['trojan'])], tls=tls),
    dict(type='vless', tag='reality', listen='::', listen_port=8447, users=[dict(uuid=s['vless_uuid'], flow='xtls-rprx-vision')],
         tls=dict(enabled=True, server_name=cover, reality=dict(enabled=True, handshake=dict(server=cover, server_port=443), private_key=s['reality_private'], short_id=[s['short_id']]))),
    dict(type='shadowtls', tag='shadowtls', listen='::', listen_port=8448, version=3, users=[dict(password=s['shadowtls'])], handshake=dict(server=cover, server_port=443), detour='ss-in'),
    dict(type='shadowsocks', tag='ss-in', listen='127.0.0.1', listen_port=18448, method='2022-blake3-aes-128-gcm', password=s['ss']),
    dict(type='vless', tag='ws', listen='127.0.0.1', listen_port=18090, users=[dict(uuid=s['ws_uuid'])], transport=dict(type='ws', path=s['ws_path'], max_early_data=2048, early_data_header_name='Sec-WebSocket-Protocol')),
]
cfg = dict(log=dict(level='warn'), inbounds=inb, outbounds=[up, dict(type='direct', tag='direct')], route=dict(final='upstream'))
json.dump(cfg, open(d + '/config.json', 'w'), indent=1)
client = dict(server=ip, sni=sni, cover=cover, insecure=not names, secrets={k: v for k, v in s.items() if k != 'reality_private'},
              ports=dict(hy2=443, hy2_obfs=3478, tuic=8445, trojan=8446, reality=8447, shadowtls=8448), domain=__import__('os').environ.get('ENTRY_DOMAIN', ''))
json.dump(client, open(d + '/client.json', 'w'))
PY
chmod 600 config.json client.json
./sing-box check -c config.json

if [[ -n "$DOMAIN" ]] && command -v nginx >/dev/null; then
  WSP=$(python3 -c "import json;print(json.load(open('$DIR/secrets.json'))['ws_path'])")
  cat > /etc/nginx/sites-available/rd-entry <<EOF
# RemoteAgents entry: WebSocket за CDN. Удаление: install-entry.sh --remove
map \$http_upgrade \$rd_upgrade { default upgrade; '' close; }
server {
    listen 80; listen [::]:80;
    listen 443 ssl http2; listen [::]:443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate $DIR/cert.pem; ssl_certificate_key $DIR/key.pem;
    location = $WSP {
        proxy_pass http://127.0.0.1:18090; proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \$rd_upgrade;
        proxy_set_header Host \$host; proxy_read_timeout 1h; proxy_send_timeout 1h; proxy_buffering off;
    }
    root /var/www/rd-decoy; index index.html; server_tokens off; error_page 404 /404.html;
    error_page 405 =200 /login-error.html;
    location = /login { try_files /login.html =404; }
    location /media/ { add_header Cache-Control "public, max-age=86400"; }
    location / { try_files \$uri \$uri/ \$uri.html =404; }
}
EOF
  ln -sf /etc/nginx/sites-available/rd-entry /etc/nginx/sites-enabled/rd-entry
  nginx -t 2>&1 | tail -1 && systemctl reload nginx
fi

cat > /etc/systemd/system/$UNIT.service <<EOF
[Unit]
Description=RemoteAgents entry node (sing-box $VER)
After=network-online.target
[Service]
ExecStart=$DIR/sing-box run -c $DIR/config.json
Restart=always
RestartSec=3
MemoryMax=256M
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable "$UNIT" >/dev/null 2>&1; systemctl restart "$UNIT"
if command -v ufw >/dev/null && ufw status | grep -q active; then
  for p in "${PORTS_UDP[@]}"; do ufw allow "$p/udp" comment rd-entry >/dev/null; done
  for p in "${PORTS_TCP[@]}"; do ufw allow "$p/tcp" comment rd-entry >/dev/null; done
fi
sleep 2; systemctl is-active "$UNIT"
ss -lntuH | awk '{print $1, $5}' | grep -E ':(443|3478|8445|8446|8447|8448)$' | sort -u
