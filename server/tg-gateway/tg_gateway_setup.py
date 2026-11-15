#!/usr/bin/python3
"""Non-root installation and read-only readiness check (stdlib + ip/openssl/systemd)."""
import argparse
import datetime
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.request

SOURCE = Path(__file__).resolve().parent
UNIT = 'tg-gateway.service'
FILES = ('gateway.py', 'tg_gateway_keys.py', 'tg_gateway_setup.py', 'install.sh', 'README.md')


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=15, **kwargs).stdout.strip()


def validate_host(host):
    if not isinstance(host, str) or not host:
        raise ValueError('Некорректный публичный хост шлюза: нужно IP или DNS-имя')
    try:
        return str(ipaddress.ip_address(host))
    except ValueError:
        # No URL, port, shell/systemd escapes, or openssl config syntax in a host.
        if (len(host) > 253 or not all(re.fullmatch(r'[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?', label)
                                      for label in host.rstrip('.').split('.'))):
            raise ValueError('Некорректный TG_GW_PUBLIC_HOST: нужно IP или DNS-имя без схемы и порта')
        return host.rstrip('.').lower()


def public_host():
    if os.environ.get('TG_GW_PUBLIC_HOST'):
        return validate_host(os.environ['TG_GW_PUBLIC_HOST'])
    hint = 'Не удалось определить публичный IPv4 из default таблицы main; задайте TG_GW_PUBLIC_HOST (IP или DNS-имя).'
    try:
        routes = json.loads(run('ip', '-j', 'route', 'show', 'table', 'main', 'default'))
        addresses = json.loads(run('ip', '-j', '-4', 'addr'))
        routes.sort(key=lambda item: item.get('metric', 0))
        for route in routes:
            # Defend against mixed-table fixtures/output and ignore tunnel defaults.
            if route.get('table', 'main') not in ('main', 254) or route.get('type', 'unicast') != 'unicast':
                continue
            hops = route.get('nexthops') or [route]
            for hop in hops:
                device = hop.get('dev', '')
                if not device or device.lower().startswith(('lo', 'docker', 'tun', 'tap', 'veth', 'br-', 'sing', 'wg')):
                    continue
                for interface in addresses:
                    if interface.get('ifname') != device or interface.get('link_type') in ('none', 'loopback'):
                        continue
                    candidates = sorted(interface.get('addr_info', []),
                                        key=lambda item: item.get('local') != route.get('prefsrc'))
                    for item in candidates:
                        if item.get('family') != 'inet' or item.get('scope') != 'global':
                            continue
                        address = ipaddress.IPv4Address(item['local'])
                        if address.is_global and not address.is_multicast and not address.is_reserved:
                            return str(address)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError) as exc:
        raise ValueError(hint) from exc
    raise ValueError(hint)


def valid_port(value):
    if isinstance(value, bool) or not re.fullmatch(r'[0-9]{1,5}', str(value)) or not 1 <= int(value) <= 65535:
        raise ValueError('Некорректный порт шлюза (TG_GW_PORT/settings.json/unit): ожидается 1..65535')
    return int(value)


def settings(base):
    path = base / 'state/settings.json'
    if not path.exists():
        return {}
    value = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(value, dict):
        raise ValueError('Повреждён state/settings.json')
    validate_host(value['public_host'])
    valid_port(value['port'])
    return value


def service_value(prop):
    try:
        return run('systemctl', '--user', 'show', UNIT, '--property=' + prop, '--value')
    except (OSError, subprocess.SubprocessError):
        return ''


def legacy_port(base):
    if not (base / 'gateway.py').exists():
        return None
    for value in shlex.split(service_value('Environment')):
        if value.startswith('TG_GW_PORT='):
            return valid_port(value.split('=', 1)[1])
    return None


def listeners(port):
    """All listening TCP socket inodes for a port, across IPv4/IPv6 addresses."""
    found = set()
    for table in ('/proc/net/tcp', '/proc/net/tcp6'):
        try:
            lines = Path(table).read_text().splitlines()[1:]
        except FileNotFoundError:
            continue
        for line in lines:
            fields = line.split()
            if int(fields[1].split(':')[1], 16) == port and fields[3] == '0A':
                found.add(fields[9])
    return found


def our_listener(port):
    pid = service_value('MainPID')
    if not pid.isdecimal() or int(pid) <= 0:
        return False
    try:
        owned = {os.readlink(fd)[8:-1] for fd in Path('/proc', pid, 'fd').iterdir()
                 if os.readlink(fd).startswith('socket:[')}
        bound = listeners(port)
        return bool(bound) and bound <= owned
    except OSError:
        return False


def port_free(port):
    if listeners(port):
        return False
    with socket.socket() as sock:
        # Match ThreadingHTTPServer: an old connection in TIME_WAIT is not an occupied listener.
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(('127.0.0.1', port))
        except OSError:
            return False
    return True


def choose_port(saved, legacy=None):
    selected = os.environ.get('TG_GW_PORT') or saved.get('port') or legacy
    if selected is not None:
        port = valid_port(selected)
        if port_free(port) or our_listener(port):
            return port
        raise ValueError(f'Порт {port} занят другим процессом; освободите его или задайте TG_GW_PORT.')
    for port in range(8444, 8500):
        if port_free(port):
            return port
    raise ValueError('Нет свободного порта 8444..8499; задайте TG_GW_PORT.')


def atomic_write(path, content, mode=0o600):
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.' + path.name, delete=False) as output:
        temporary = Path(output.name)
        try:
            os.fchmod(output.fileno(), mode)
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        except BaseException:
            temporary.unlink()
            raise
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def certificate_matches(cert, key, host):
    # Parse SAN exactly (checkhost would also accept wildcard/CN-only certificates).
    decoded = ssl._ssl._test_decode_cert(str(cert))
    wanted = ('DNS', host)
    try:
        wanted = ('IP Address', str(ipaddress.ip_address(host)))
    except ValueError:
        pass
    sans = {(kind, value.lower() if kind == 'DNS' else str(ipaddress.ip_address(value)))
            for kind, value in decoded.get('subjectAltName', ()) if kind in ('DNS', 'IP Address')}
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)  # Refuse mismatched/damaged pairs before touching the installation.
    return wanted in sans and ('IP Address', '127.0.0.1') in sans


def ensure_certificate(base, host):
    tls = base / 'tls'
    tls.mkdir(mode=0o700, exist_ok=True)
    tls.chmod(0o700)
    cert, key = tls / 'cert.pem', tls / 'key.pem'
    exists = cert.exists() or key.exists()
    if exists:
        if not cert.is_file() or not key.is_file():
            raise ValueError('Нужны оба файла tls/cert.pem и tls/key.pem; существующие файлы не изменены.')
        if os.environ.get('TG_GW_PRESERVE_IDENTITY') == '1':
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert, key)
            return
        if certificate_matches(cert, key, host):
            key.chmod(0o600)
            return
    try:
        ipaddress.ip_address(host)
        san = 'IP:' + host
    except ValueError:
        san = 'DNS:' + host
    with tempfile.TemporaryDirectory(prefix='.new-', dir=tls) as stage:
        new_cert, new_key = Path(stage) / 'cert.pem', Path(stage) / 'key.pem'
        run('openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
            '-sha256', '-nodes', '-days', '3650', '-subj', '/CN=' + host,
            '-addext', 'subjectAltName=' + san + ',IP:127.0.0.1',
            '-keyout', str(new_key), '-out', str(new_cert))
        if exists:
            archive = tls / ('old-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
            archive.mkdir(mode=0o700)
            shutil.copy2(cert, archive / cert.name)
            shutil.copy2(key, archive / key.name)
            (archive / key.name).chmod(0o600)
            print('Предупреждение: публичный хост/SAN изменился; клиентам нужен новый сертификат. Старый сохранён в ' + str(archive), file=sys.stderr)
        atomic_write(key, new_key.read_bytes())
        atomic_write(cert, new_cert.read_bytes())


def unit_quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"'


def health(base, port):
    context = ssl.create_default_context(cafile=str(base / 'tls/cert.pem'))
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context))
    with opener.open(f'https://127.0.0.1:{port}/health', timeout=1) as response:
        return response.status == 200 and response.read(16) == b'ok'


def unit_contents(base, port):
    state = base / 'state'
    contents = '[Unit]\nDescription=Telegram Bot API HTTPS gateway\n\n[Service]\nType=simple\n'
    contents += 'ExecStart=/usr/bin/python3 -I -u ' + unit_quote(base / 'gateway.py') + '\n'
    for name, value in {'TG_GW_PORT': port, 'TG_GW_CERT': base / 'tls/cert.pem',
                        'TG_GW_KEY': base / 'tls/key.pem', 'TG_GW_KEYS': state / 'keys.json'}.items():
        contents += 'Environment=' + unit_quote(f'{name}={value}') + '\n'
    contents += ('UnsetEnvironment=HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy\n'
                 'Restart=always\nRestartSec=2\nNoNewPrivileges=yes\nUMask=0077\n\n[Install]\nWantedBy=default.target\n')
    return contents


def ready(base):
    saved = settings(base)
    unit = Path.home() / '.config/systemd/user' / UNIT
    files_ok = all((base / n).is_file() and (base / n).read_bytes() == (SOURCE / n).read_bytes() for n in FILES)
    return bool(saved and files_ok and unit.is_file() and unit.read_text() == unit_contents(base, valid_port(saved['port'])) and service_value('ActiveState') == 'active' and
                service_value('UnitFileState') == 'enabled' and health(base, valid_port(saved['port'])))


def install(base):
    for tool in ('openssl', 'systemctl'):
        if not shutil.which(tool):
            raise ValueError('Администратору сервера нужно установить: ' + tool)
    base.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (base / '.install.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        host = public_host()
        saved = settings(base)
        port = choose_port(saved, legacy_port(base) if not saved else None)
        ensure_certificate(base, host)
        for name in FILES:
            target = base / name
            if SOURCE / name != target:
                atomic_write(target, (SOURCE / name).read_bytes(), 0o700 if name.endswith('.sh') or name == 'tg_gateway_keys.py' else 0o600)
        state = base / 'state'
        state.mkdir(mode=0o700, exist_ok=True)
        state.chmod(0o700)
        atomic_write(state / 'settings.json', (json.dumps({'public_host': host, 'port': port}, indent=2) + '\n').encode())
        binary = Path.home() / '.local/bin/tg-gateway-keys'
        binary.parent.mkdir(parents=True, exist_ok=True)
        binary.unlink(missing_ok=True)
        binary.symlink_to(base / 'tg_gateway_keys.py')
        unit = Path.home() / '.config/systemd/user' / UNIT
        unit.parent.mkdir(parents=True, exist_ok=True)
        contents = unit_contents(base, port)
        atomic_write(unit, contents.encode())
        try:
            run('loginctl', 'enable-linger', '--no-ask-password', str(os.getuid()))
        except (OSError, subprocess.SubprocessError):
            print('Предупреждение: не удалось включить linger без sudo; после выхода пользователя служба может остановиться.', file=sys.stderr)
        for command in ('daemon-reload', 'enable', 'restart'):
            args = () if command == 'daemon-reload' else (UNIT,)
            run('systemctl', '--user', command, *args)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                if health(base, port):
                    break
            except (OSError, ValueError):
                pass
            time.sleep(0.2)
        else:
            raise ValueError('Шлюз не прошёл TLS-проверку /health за 10 секунд.')
        public = '[' + host + ']' if ':' in host else host
        print(f'Шлюз работает: https://{public}:{port}\nСертификат: {base / "tls/cert.pem"}')
        print(run('openssl', 'x509', '-in', str(base / 'tls/cert.pem'), '-noout', '-fingerprint', '-sha256'))


def main():
    parser = argparse.ArgumentParser(description='Установка шлюза Telegram без root')
    parser.add_argument('--check', action='store_true', help='Только проверка службы и /health')
    args = parser.parse_args()
    base = Path.home() / '.local/opt/tg-gateway'
    try:
        if args.check:
            return 0 if ready(base) else 1
        install(base)
        return 0
    except (OSError, ValueError, KeyError, TypeError, ssl.SSLError, subprocess.SubprocessError) as exc:
        print('Ошибка установки шлюза: ' + str(exc), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
