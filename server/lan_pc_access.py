#!/usr/bin/env python3
"""Доступ с ПК в ЛВС сервера: правила канала sing-box из локального файла, как .env.

Файл /etc/remoteagents/lan-pc-access.json (root, 600) — единственный источник правды:
  {"lans": [{"name": "clinic", "subnets": "auto" | ["10.0.0.0/24"], "domains": ["*.corp.example"]}]}
Адресов ЛВС в коде нет. "auto" берёт подсети, которые менеджер ЛВС сервера уже подтвердил.
Правила пишутся тем же генератором, что и lan_share (выход direct с bind_interface tun-lan-ИМЯ),
идемпотентно; при сбое проверки после перезапуска sing-box прежний конфиг возвращается сразу.

  lan_pc_access.py sync      привести sing-box к файлу (по таймеру и после загрузки)
  lan_pc_access.py status    только чтение: что в файле и совпадает ли с sing-box
  lan_pc_access.py remove    снять свои правила (файл не трогает)
  lan_pc_access.py install   положить код и включить таймер (root)
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time

CONF = '/etc/remoteagents/lan-pc-access.json'
STATE = '/var/lib/remoteagents/lan-pc-access/state.json'
SINGBOX = '/etc/sing-box/config.json'
LAN_DIR = '/etc/remoteagents/lan'
SHARE_MANIFEST = '/etc/remoteagents/server-apply/lan-share.json'
LIB = '/usr/local/lib/remoteagents/server/'
CHANNEL = ('vless', 'vmess', 'trojan', 'shadowsocks', 'hysteria2', 'tuic', 'hysteria')


def _share():
    path = Path(__file__).with_name('lan_share.py')
    spec = importlib.util.spec_from_file_location('lan_share_for_pc_access', path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


share = _share()
Error = share.Error


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return default
    except ValueError:
        raise Error(str(path) + ': не JSON.') from None


def auto_subnets(name, lan_dir=LAN_DIR):
    base = Path(lan_dir) / name
    found = list(read_json(base / 'config.json', {}).get('subnets', []))
    if (base / 'subnets').is_file():
        found += (base / 'subnets').read_text().split()
    return sorted(set(str(share.cidr(n)) for n in found))


def policy(conf, lan_dir=LAN_DIR):
    """Чистая функция: файл настроек -> политика формата lan_share.generate."""
    lans = []
    share.require(isinstance(conf, dict) and isinstance(conf.get('lans', []), list), 'lans: нужен список.')
    for item in conf.get('lans', []):
        name = item.get('name', '')
        share.require(isinstance(name, str) and share.LAN_NAME.fullmatch(name), 'lans.name: [a-z][a-z0-9]{0,6}.')
        subnets = item.get('subnets', 'auto')
        subnets = auto_subnets(name, lan_dir) if subnets == 'auto' else sorted(set(str(share.cidr(n)) for n in subnets))
        share.require(subnets, 'ЛВС ' + name + ': нет подсетей (подтверждённых менеджером ЛВС или в файле).')
        domains = sorted(set(share.domain(d) for d in item.get('domains', [])))
        lans.append(dict(name=name, subnets=subnets, lanSubnets=subnets, domains=domains, forwards=[]))
    lans.sort(key=lambda x: x['name'])
    return dict(subnets=sorted({n for x in lans for n in x['subnets']}), domains=sorted({d for x in lans for d in x['domains']}),
                forwards=[], lanSubnets=sorted({n for x in lans for n in x['subnets']}), lans=lans)


def plan(current, conf, previous, lan_dir=LAN_DIR):
    p = policy(conf, lan_dir) if conf is not None else policy({}, lan_dir)
    generated, record = share.generate(current, p, 'singbox', previous)
    if share.enabled(p):
        issues = share.egress_issues(generated, p['lans'])
        share.require(not issues, 'Маршрут ЛВС в sing-box неверен: ' + '; '.join(issues))
    return generated, record, p


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def channel_port(config):
    for i in config.get('inbounds', []):
        if i.get('type') in CHANNEL and i.get('listen_port'):
            return i['listen_port']


def healthy(config, wait=12):
    """sing-box жив, вход канала слушает, обычный выход через прокси работает."""
    port = channel_port(config)
    deadline = time.time() + wait
    while time.time() < deadline:
        time.sleep(1)
        try:
            run(['systemctl', 'is-active', '--quiet', 'sing-box'])
            if port:
                socket.create_connection(('127.0.0.1', port), 2).close()
            run(['curl', '-sS', '-m', '6', '-o', '/dev/null', '--socks5', '127.0.0.1:1080', 'https://api.ipify.org'])
            return True
        except (subprocess.CalledProcessError, OSError):
            continue
    return False


def sync(conf_path=CONF, state_path=STATE, singbox=SINGBOX, remove=False, lan_dir=LAN_DIR):
    if os.geteuid() != 0:
        raise Error('Нужен root.')
    manifest = read_json(SHARE_MANIFEST, {})
    share.require(not manifest, 'Доступ с ПК уже ведёт server_apply (lan-share.json); два владельца правил не нужны.')
    state = read_json(state_path, {})
    conf = None if remove else read_json(conf_path)
    if conf is None and not remove and not state:
        print('Файл ' + str(conf_path) + ' не задан и правил нет — ничего не делаю.')
        return 0
    share.require(conf is not None or remove, 'Файл ' + str(conf_path) + ' пропал; снять правила — «remove».')
    path = Path(singbox)
    current = json.loads(path.read_text())
    generated, record, p = plan(current, conf, state.get('record'), lan_dir)
    if generated == current:
        print('OK: sing-box уже соответствует файлу.')
        return 0
    tmp = Path(str(path) + '.lan-pc-access.tmp')
    tmp.write_text(json.dumps(generated) + '\n')
    try:
        run(['sing-box', 'check', '-c', str(tmp)])
    finally:
        tmp.unlink(missing_ok=True)
    backup = Path(state_path).with_name('sing-box.before.json')
    backup.parent.mkdir(parents=True, exist_ok=True)
    st = path.stat()
    shutil.copy2(path, backup)
    path.write_text(json.dumps(generated) + '\n')
    os.chmod(path, st.st_mode & 0o777)
    os.chown(path, st.st_uid, st.st_gid)
    run(['systemctl', 'restart', 'sing-box'])
    if not healthy(generated):
        shutil.copy2(backup, path)
        os.chown(path, st.st_uid, st.st_gid)
        run(['systemctl', 'restart', 'sing-box'])
        raise Error('После применения sing-box не прошёл проверку; конфиг возвращён.')
    Path(state_path).write_text(json.dumps(dict(record=record, at=int(time.time()))) + '\n')
    print('Применено: ' + (', '.join(x['name'] + ' (' + str(len(x['subnets'])) + ' подсетей)' for x in p['lans']) or 'правила сняты'))
    return 0


def status(conf_path=CONF, state_path=STATE, singbox=SINGBOX, lan_dir=LAN_DIR):
    conf = read_json(conf_path)
    if conf is None:
        print('Файл ' + str(conf_path) + ' не задан.')
        return 0
    current = json.loads(Path(singbox).read_text())
    generated, _, p = plan(current, conf, read_json(state_path, {}).get('record'), lan_dir)
    print(('OK' if generated == current else 'РАСХОЖДЕНИЕ: нужен sync') + '; ЛВС: ' + ', '.join(x['name'] + ' ' + str(len(x['subnets'])) for x in p['lans']))
    return 0 if generated == current else 1


UNIT = ('[Unit]\nDescription=LAN access for PCs (sing-box rules from /etc/remoteagents/lan-pc-access.json)\n'
        'After=sing-box.service openvpn.service network-online.target\n'
        '[Service]\nType=oneshot\nExecStart=/usr/bin/python3 -I ' + LIB + 'lan_pc_access.py sync\n')
TIMER = ('[Unit]\nDescription=Keep PC LAN access rules in place\n'
         '[Timer]\nOnBootSec=2min\nOnUnitActiveSec=10min\n[Install]\nWantedBy=timers.target\n')


def install():
    if os.geteuid() != 0:
        raise Error('Нужен root.')
    here = Path(__file__).resolve().parent
    Path(LIB).mkdir(parents=True, exist_ok=True)
    for name in ('lan_pc_access.py', 'lan_share.py'):
        shutil.copy2(here / name, LIB + name)
    Path('/etc/systemd/system/remoteagents-lan-pc-access.service').write_text(UNIT)
    Path('/etc/systemd/system/remoteagents-lan-pc-access.timer').write_text(TIMER)
    run(['systemctl', 'daemon-reload'])
    run(['systemctl', 'enable', '--now', 'remoteagents-lan-pc-access.timer'])
    print('Установлено: таймер remoteagents-lan-pc-access.timer.')
    return 0


def main(argv):
    cmd = argv[0] if argv else ''
    try:
        if cmd == 'sync':
            return sync()
        if cmd == 'remove':
            return sync(remove=True)
        if cmd == 'status':
            return status()
        if cmd == 'install':
            return install()
        print(__doc__)
        return 2
    except (Error, subprocess.CalledProcessError, OSError) as exc:
        print('Ошибка: ' + str(exc), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
