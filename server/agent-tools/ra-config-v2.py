#!/usr/bin/env python3
"""Полный конфиг remoteagents-2 (Лаборатория) для ПК. Запуск: python3 -I build.py <имя ПК> <выходной файл> [--no-fetch]
Берёт ВСЕ пути: channel, relays, wsEntries (сервер 109) и узлы входа sparfum (client.json с ПК через ra-lab).
Пароль: RA_PASSWORD (по умолчанию пустой = «без пароля»). Выход: JSON одной строкой (0600) + проверка полноты."""
import json, os, re, subprocess, sys, tempfile
# ralab лежит рядом в репозитории (lab/ralab); от worktree не зависим.
LAB = os.environ.get('RA_LAB_DIR') or os.path.join(os.path.dirname(os.path.realpath(__file__)), '..', '..', 'lab')
sys.path.insert(0, LAB)
from ralab import secretbox, v2config
H = os.path.expanduser('~')
_TR = dict(zip('абвгдеёжзийклмнопрстуфхцчшщъыьэюя', ['a','b','v','g','d','e','e','zh','z','i','y','k','l','m','n','o','p','r','s','t','u','f','kh','ts','ch','sh','shch','','y','','e','yu','ya']))
def latin_name(n):
    """Имя ПК для v3 обязано быть ^[A-Za-z0-9._-]{1,64}$: кириллицу транслитерируем, прочее -> '-'."""
    t = ''.join(_TR.get(c, _TR.get(c.lower(), c).capitalize() if c.lower() in _TR else c) for c in n)
    t = re.sub(r'[^A-Za-z0-9._-]+', '-', t).strip('-')[:64]
    if not t:
        sys.exit('имя ПК пустое после приведения к латинице: ' + repr(n))
    return t
name, out = latin_name(sys.argv[1]), sys.argv[2]
if name != sys.argv[1]:
    print('имя ПК приведено к латинице: %s -> %s' % (sys.argv[1], name))
ce = json.load(open(H + '/.config/remoteagents/config-export.json'))
cat = json.load(open(ce['catalogFile']))
chan = open(ce['vpnBootstrap']['channelFile']).read()
d = tempfile.mkdtemp(prefix='ra-v2-'); os.chmod(d, 0o700)
sh = lambda *a, **k: subprocess.run(a, check=True, timeout=k.get('t', 30), capture_output=True, text=True).stdout
# 1. ключ ПК
sh('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'ra-pc:' + name, '-f', d + '/k')
open(H + '/.ssh/authorized_keys', 'a').write(open(d + '/k.pub').read())
# 2. узел входа sparfum: client.json лежит только на sparfum, берём через ПК (ra-lab)
entries, secrets = [], {}
if '--no-fetch' not in sys.argv:
    open(d + '/sp.json', 'w').write(sh('ra-lab', 'exec', 'ssh -n -o BatchMode=yes -o ConnectTimeout=8 sparfum cat /opt/rd-entry/client.json', '--max-time', '20', t=30))
    sp = json.load(open(d + '/sp.json'))
    entries, secrets = ['sparfum'], {'sparfum': json.dumps(sp, separators=(',', ':'))}
pub = open('/etc/ssh/ssh_host_ed25519_key.pub').read().split()
subnets = json.load(open('/tmp/ra-lan.json')) if os.path.exists('/tmp/ra-lan.json') else None
cfg = {"format": "remoteagents-2", "name": name,
       "server": {"host": ce['serverAddress'], "port": ce.get('serverPort', 22), "user": ce['workerUser'],
                  "hostKey": pub[0] + ' ' + pub[1], "key": open(d + '/k').read()},
       "paths": {"entries": entries, "relays": cat['relays'], "hops": [], "cdn": [],
                 "wsEntries": [{"name": "sslip", "host": "109-199-110-63.sslip.io", "address": ce['serverAddress'], "port": 2053,
                                "path": "/3efaa47d01be14ab", "certificate": subprocess.run(['sudo', 'cat', '/etc/sing-box/ws-tls.crt'], capture_output=True, text=True, timeout=10).stdout}],
                 "secrets": secrets, "channel": chan},
       "control": True, "autostart": True, "vpn": {"mode": "auto", "bridges": [], "direct": {"domains": []}},
       "lan": [{"name": "Клиника", "host": "192.168.88.244", "port": 22, "share": subnets or {
           "enabled": True, "domains": ["*.eastclinic.ru"], "subnets": []}}],
       "tun": {"enabled": True}, "happier": {"localWeb": {"enabled": True, "port": 47831, "serverPort": 47831}},
       "disk": {"home": "%LOCALAPPDATA%\\RemoteDisk"}}
# подсети ЛВС из сервера (единый источник)
if not subnets:
    lan = json.loads(subprocess.run(['sudo', 'cat', '/etc/remoteagents/export/server-config-lan.json'], capture_output=True, text=True, timeout=10).stdout)
    L = (lan.get('lan') or lan.get('lans') or [lan])[0] if isinstance(lan, dict) else lan[0]
    sh_ = L.get('share') or L
    cfg['lan'][0]['share'] = {"enabled": True, "subnets": sh_.get('subnets') or [], "domains": sh_.get('domains') or ["*.eastclinic.ru"]}
cfg, pr = v2config._validate(json.dumps(cfg)); assert not pr, pr
# проверка полноты ДО запечатывания
need = {'узел sparfum': bool(cfg['paths']['entries']), 'relay': bool(cfg['paths']['relays']), 'WS-вход': bool(cfg['paths']['wsEntries']),
        'channel': bool(cfg['paths']['channel']), 'подсети ЛВС': bool(cfg['lan'][0]['share']['subnets']), 'control': cfg['control'], 'tun': cfg['tun']['enabled']}
miss = [k for k, v in need.items() if not v]
pw = os.environ.get('RA_PASSWORD', '')
cfg['kdf'] = secretbox.new_kdf(); key = secretbox.derive(pw, cfg['kdf']); cfg['check'] = secretbox.make_check(key)
enc = lambda v: secretbox.encrypt(v, key)
cfg['server']['key'] = enc(cfg['server']['key']); cfg['paths']['channel'] = enc(cfg['paths']['channel'])
cfg['paths']['secrets'] = {k: enc(v) for k, v in cfg['paths']['secrets'].items()}
text = json.dumps(cfg, ensure_ascii=False, separators=(',', ':'))
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600); os.write(fd, text.encode()); os.close(fd)
assert not v2config.check(out), v2config.check(out)
r = v2config.apply(text, pw, tempfile.mkdtemp(prefix='ra-v2-h-')); assert r['ok'], r
import shutil; shutil.rmtree(d)
print('ГОТОВО %s: %d байт, проверка и пробное применение пройдены' % (out, len(text.encode())))
print('Путей: узлов=%d relays=%d ws=%d; в конфиге нет: %s' % (len(cfg['paths']['entries']), len(cfg['paths']['relays']), len(cfg['paths']['wsEntries']), ', '.join(miss) or 'ничего'))
