#!/usr/bin/env python3
"""Root-side master-config reconciler. Network transactions belong to the existing managers.

All filesystem paths and commands go through System; tests supply a disposable root
and command runner. Child output is private: only fixed, secret-free summaries leave
this process. No shell interprets configuration values.
"""
import argparse
import contextlib
import fcntl
import getpass
import hashlib
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import subprocess
import sys
import tempfile
import time
import traceback
from urllib.parse import urlsplit

MARKER = '---remoteagents-stdin---'
HIDDEN = '<есть, скрыт>'
SOURCE = Path(__file__).resolve().parent
CODE_FILES = ('server_apply.py', 'server-apply.sh', 'lan_vpn.py', 'lan-vpn.sh', 'proxy_out.py', 'proxy-out.sh', 'remoteagents_config.py', 'base_network.py', 'lan_share.py', 'lan_pc_access.py', 'server_recovery.py', 'server_components.py', 'server_packages.py', 'component_files.py', 'lan-config.schema.json', 'happier-web.schema.json',
                     'happier_web.py', 'happier_web_common.py', 'happier_web_release.py', 'happier_web_quotas.py', 'agy_usage_scrape.py', 'happier_web_verify.cjs', 'happier_web_settings.cjs', 'happier_web_addon.js')


class Error(Exception):
    pass


def require(ok, message):
    if not ok:
        raise Error(message)


def module(name):
    spec = importlib.util.spec_from_file_location(name, SOURCE / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


lan = module('lan_vpn')
lan_share = module('lan_share')
config_crypto = module('remoteagents_config')
base = module('base_network')
packages = module('server_packages')
components = module('server_components')
component_files = module('component_files')


def strict_json(text, limit=4 * 1024 * 1024):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'JSON содержит повторные поля.')
            result[key] = value
        return result
    require(len(text.encode('utf-8')) <= limit, 'JSON превышает допустимый размер.')
    try:
        return json.loads(text.lstrip('\ufeff').replace('\r\n', '\n'), object_pairs_hook=pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(Error('Некорректный JSON.')))
    except (ValueError, TypeError):
        raise Error('Некорректный JSON; значения скрыты.') from None


def valid_url(value):
    u = urlsplit(value)
    require(u.scheme == 'https' and u.hostname and not u.username and not u.password and
            len(value) <= 2048 and not any(c.isspace() or ord(c) < 32 for c in value),
            'Нужен HTTPS checkUrl без логина и пароля.')


def validate(config):
    require(isinstance(config, dict) and config.get('kind') == 'remoteagents-config' and
            type(config.get('schema')) is int and config['schema'] == 1, 'Нужен мастер-конфиг remoteagents-config, schema=1.')
    # Use the published schema when available; installed copies carry it too. The
    # small validator handles precisely its declarative vocabulary, without pip.
    schema_path = SOURCE / 'config.paste.schema.json'
    if not schema_path.exists():
        schema_path = SOURCE.parent / 'app/launcher/config.paste.schema.json'
    schema = strict_json(schema_path.read_text())
    # Server-owned additions are shipped independently of the client schema.
    web = strict_json((SOURCE / 'happier-web.schema.json').read_text())
    schema['properties']['serverComponents']['properties']['happierWeb'] = web['$defs']['serverComponent']
    schema['properties']['happier']['properties']['localWeb'] = web['$defs']['localWeb']
    def check(value, rule):
        if 'oneOf' in rule:
            matches = 0
            for variant in rule['oneOf']:
                try:
                    check(value, variant)
                    matches += 1
                except Error:
                    pass
            require(matches == 1, 'Поле конфига не соответствует схеме.')
            return
        for clause in rule.get('allOf', []):
            try:
                check(value, clause.get('if', {}))
            except Error:
                check(value, clause.get('else', {}))
            else:
                check(value, clause.get('then', {}))
        kind = rule.get('type')
        types = {'object': dict, 'array': list, 'string': str, 'integer': int, 'boolean': bool}
        require(not kind or type(value) is types[kind], 'Неверный тип поля конфига.')
        require('const' not in rule or type(value) is type(rule['const']) and value == rule['const'], 'Неверная версия/вид конфига.')
        require('enum' not in rule or value in rule['enum'], 'Недопустимое значение поля конфига.')
        if isinstance(value, dict):
            require(all(k in value for k in rule.get('required', [])), 'Отсутствует обязательное поле конфига.')
            require(len(value) <= rule.get('maxProperties', 100000), 'Слишком много полей.')
            for k, v in value.items():
                if 'propertyNames' in rule:
                    check(k, rule['propertyNames'])
                prop = rule.get('properties', {}).get(k, rule.get('additionalProperties', {}))
                require(prop is not False, 'Неизвестное поле конфига.')
                if isinstance(prop, dict):
                    check(v, prop)
        if isinstance(value, list):
            require(len(value) <= rule.get('maxItems', 100000), 'Слишком много элементов.')
            if rule.get('uniqueItems'):
                require(len({json.dumps(v, sort_keys=True) for v in value}) == len(value), 'Повторные элементы массива.')
            for v in value:
                check(v, rule.get('items', {}))
        if isinstance(value, str):
            require(rule.get('minLength', 0) <= len(value) <= rule.get('maxLength', 4 * 1024 * 1024), 'Неверная длина поля.')
            if rule.get('pattern'):
                # C# appends a portable end-of-input assertion to its patterns.
                pattern = rule['pattern']
                require(re.search(pattern, value) is not None, 'Неверный формат поля конфига.')
            if rule.get('format') == 'happier-server-url':
                try:
                    module('happier_web_common').server_origin(value)
                except ValueError:
                    raise Error('serverComponents.happierWeb.serverUrl: нужен HTTP(S) origin без пароля, пути и query.') from None
            if rule.get('format') == 'https-url':
                valid_url(value)
        if type(value) is int:
            require(rule.get('minimum', value) <= value <= rule.get('maximum', value), 'Число вне диапазона.')
    config.pop('tailscale', None)  # Migration: old field is ignored, never reissued.
    check(config, schema)
    lan_share.policy(config)
    proxy = config.get('proxyOut')
    if proxy:
        proxy.setdefault('ipv6', 'block')
    if proxy:
        if 'exitIp' in proxy:
            ipaddress.ip_address(proxy['exitIp'])
    network = config.get('serverNetwork', {})
    if network.get('tunAddress'):
        ipaddress.IPv4Interface(network['tunAddress'])
    names = set()
    for item in config.get('lan', []):
        lan.name_ok(item['name'])
        require(item['name'] not in names, 'Имена ЛВС повторяются.')
        names.add(item['name'])
        lan.networks(item.get('subnets', []))
        if item.get('serverFingerprint'):
            lan.normalize_server_fingerprint(item['serverFingerprint'])
        require(bool(item.get('dnsDomain')) == bool(item.get('dnsServer')), 'Для ЛВС нужны оба поля dnsDomain/dnsServer.')
        for key in ('host', 'testHost'):
            if item.get(key):
                ipaddress.IPv4Address(item[key])
        require(not (item.get('host') and item.get('testHost') and item['host'] != item['testHost']), 'host и testHost ЛВС отличаются.')
        require(not (item.get('port') and item.get('testPort') and item['port'] != item['testPort']), 'port и testPort ЛВС отличаются.')


def secret_values(value):
    """Also cover individual credentials inside JSON secret exports."""
    if isinstance(value, dict):
        for child in value.values():
            yield from secret_values(child)
    elif isinstance(value, (list, tuple)):
        for child in value:
            yield from secret_values(child)
    elif isinstance(value, str) and len(value) >= 4:
        yield value
        try:
            parsed = json.loads(value)
        except (ValueError, TypeError):
            return
        if isinstance(parsed, (dict, list)):
            yield from secret_values(parsed)


def hidden_exception(system, exc, mode, part, values=(), fallback='Проверка/команда не выполнена; детали скрыты.'):
    # Diagnostic failures must never alter the original operation's result.
    try:
        known = sorted(set(secret_values(values)) | system.diagnostic_values, key=len, reverse=True)

        def redact(message):
            for value in known:
                message = message.replace(value, '***')
            message = re.sub(r'(?i)(password|token|secret|key)=\S+', r'\1=***', message)
            return re.sub(r'[A-Za-z0-9+/=_-]{32,}', '***', message)[:500]

        cause = exc.__cause__ or exc.__context__
        record = dict(mode=mode, part=part, type=type(exc).__name__, message=redact(str(exc)),
                      where=[Path(frame.filename).name + ':' + str(frame.lineno) + ':' + frame.name
                             for frame in traceback.extract_tb(exc.__traceback__)[-5:]])
        if cause is not None:
            record['cause'] = redact(type(cause).__name__ + ': ' + str(cause))
        ident = system.diag(record)
        if ident:
            return fallback.removesuffix('.') + ' (журнал сервера, запись ' + ident + ').'
    except Exception:
        pass
    return fallback


def read_input(path, stream, secret_stdin=False, diagnostic=None):
    text = stream.read() if path == '-' or secret_stdin else ''
    text = text.replace('\r\n', '\n')
    before, marker, after = text.partition(MARKER + '\n')
    config = strict_json(before if path == '-' else Path(path).read_text(encoding='utf-8-sig'))
    if diagnostic is not None and isinstance(config, dict):
        diagnostic.diagnostic_values.update(secret_values(config.get('secrets', {})))
    validate(config)
    relay = strict_json(after) if marker else {}
    require(isinstance(relay, dict), 'После маркера нужен JSON-объект.')
    # A plain dictionary is the separate secret export. A wrapped relay can also
    # carry the master password without putting it in argv or environment.
    master = relay.get('masterPassword') if 'secrets' in relay or 'masterPassword' in relay else None
    extra = relay.get('secrets', {}) if 'secrets' in relay or 'masterPassword' in relay else relay
    if diagnostic is not None:
        diagnostic.diagnostic_values.update(secret_values([master, extra]))
    require(isinstance(extra, dict) and all(isinstance(v, str) for v in extra.values()), 'Неверный словарь секретов.')
    section = config.get('secrets', {})
    if section.get('protected'):
        if master is None and sys.stdin.isatty():
            master = getpass.getpass('Мастер-пароль (не отображается): ')
        if master is None:
            section = {}  # plan can still inspect public state and list missing names.
        else:
            try:
                section = config_crypto.unprotect(section, master)
            except Exception:
                raise Error('Не удалось открыть секреты: проверьте мастер-пароль и полный экспорт.') from None
    if diagnostic is not None:
        diagnostic.diagnostic_values.update(secret_values([master, section]))
    values = {**section, **extra}
    require(all(isinstance(v, str) for v in values.values()), 'Неверный словарь секретов.')
    return config, {k: v for k, v in values.items() if v and v != HIDDEN}


class System:
    def __init__(self, root='/', runner=None, source=SOURCE):
        self.root, self.runner, self.source = Path(root), runner or subprocess.run, Path(source)
        self.actions = []
        self.download_proxy = None
        self.diagnostic_values = set()

    def path(self, absolute):
        return self.root / str(absolute).lstrip('/')

    def read(self, path, default=None):
        p = self.path(path)
        return json.loads(p.read_text()) if p.exists() else default

    def run(self, args, input=None, check=True, change=False, timeout=60):
        args = [str(a) for a in args]
        if change:
            self.actions.append(args[0] + ' ' + (args[1] if len(args) > 1 else ''))
        try:
            environment = {k: v for k, v in os.environ.items() if k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')}
            if self.download_proxy and (args[0] in ('apt-get', 'pip', 'pip3', 'python3', 'bash', 'runuser') or args[0] == 'curl' and any(x in args for x in ('-o', '--output'))):
                environment.update(http_proxy=self.download_proxy, https_proxy=self.download_proxy, all_proxy=self.download_proxy)
                if args[0] == 'curl' and '--noproxy' in args:
                    i = args.index('--noproxy')
                    del args[i:i + 2]
            if args[0] == 'apt-get':
                environment['DEBIAN_FRONTEND'] = 'noninteractive'
                environment['NEEDRESTART_MODE'] = 'l'
            result = self.runner(args, input=input, text=True, capture_output=True, timeout=timeout, env=environment)
        except FileNotFoundError:
            if not check:
                return subprocess.CompletedProcess(args, 127, '', '')
            raise Error('Нужная программа не установлена.') from None
        except Exception:
            raise Error('Не удалось выполнить команду; диагностический вывод скрыт.') from None
        if check:
            require(result.returncode == 0, 'Команда завершилась ошибкой; диагностический вывод скрыт.')
        result.stdout = result.stdout.replace('\r', '')
        return result

    def write(self, absolute, value, mode=0o600):
        path = self.path(absolute)
        for parent in (path, *path.parents):
            require(not parent.is_symlink(), 'Отказ записи через символическую ссылку.')
            if parent == self.root:
                break
        data = value.encode() if isinstance(value, str) else value
        if path.exists() and path.read_bytes() == data and path.stat().st_mode & 0o777 == mode and (self.root != Path('/') or (path.stat().st_uid == 0 and path.stat().st_gid == 0)):
            return False
        require(not path.is_symlink(), 'Отказ записи по символической ссылке.')
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=path.parent)
        try:
            os.fchmod(fd, mode)
            if os.geteuid() == 0:
                os.fchown(fd, 0, 0)
            with os.fdopen(fd, 'wb') as out:
                out.write(data)
            os.replace(tmp, path)
        finally:
            Path(tmp).unlink(missing_ok=True)
        self.actions.append('файл ' + absolute)
        return True

    def active(self, unit):
        return self.run(['systemctl', 'is-active', '--quiet', unit], check=False).returncode == 0

    @contextlib.contextmanager
    def network_lock(self):
        directory = self.path('/var/lib/remoteagents')
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (directory / 'network.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    def audit(self, rows):
        # Operational logging does not count as a configuration action.
        self._journal('/var/log/remoteagents/server-apply.log',
                      {'at': int(time.time()), 'parts': rows})

    def diag(self, record):
        # Disposable roots support unprivileged tests; the real journal is root-only.
        if self.root == Path('/') and os.geteuid() != 0:
            return None
        try:
            ident = secrets.token_hex(4)
            self._journal('/var/log/remoteagents/server-apply-errors.log',
                          dict(record, id=ident, at=int(time.time())), private=True)
            return ident
        except Exception:
            return None

    def _journal(self, absolute, record, private=False):
        path = self.path(absolute)
        for parent in (path, *path.parents):
            require(not parent.is_symlink(), 'Журнал не должен быть символической ссылкой.')
            if parent == self.root:
                break
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if private:
            os.chmod(path.parent, 0o700)
            if os.geteuid() == 0:
                os.chown(path.parent, 0, 0)
        # The periodic reconciler calls this every 30 s. Keep one bounded
        # archive instead of growing the operational journal indefinitely.
        if path.exists() and path.stat().st_size > 1024 * 1024:
            archive = path.with_name(path.name + '.1')
            if private:
                require(not archive.is_symlink(), 'Журнал не должен быть символической ссылкой.')
            os.replace(path, archive)
            os.chmod(archive, 0o600)
            if os.geteuid() == 0:
                os.chown(archive, 0, 0)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'a') as out:
            os.fchmod(out.fileno(), 0o600)
            if os.geteuid() == 0:
                os.fchown(out.fileno(), 0, 0)
            out.write(json.dumps(record, ensure_ascii=False) + '\n')

    @contextlib.contextmanager
    def private_file(self, data):
        directory = self.path('/run/remoteagents-server-apply')
        require(not directory.is_symlink(), 'Недопустимый временный каталог.')
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        require(self.root != Path('/') or directory.stat().st_uid == 0, 'Временный каталог должен принадлежать root.')
        os.chmod(directory, 0o700)
        fd, path = tempfile.mkstemp(dir=directory)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, 'w') as out:
                out.write(data)
            yield Path(path)
        finally:
            Path(path).unlink(missing_ok=True)


INBOUND_WARNING = 'ответы на входящие подключения (SSH, VPN) уйдут в sing-box — мосты компьютеров отвалятся'


def inbound_nft(iface):
    require(re.fullmatch(r'[a-zA-Z0-9_.:-]{1,15}', iface) is not None, 'Не удалось определить внешний интерфейс.')
    return ('table inet remoteagents_inbound {\n'
            ' chain pre { type filter hook prerouting priority mangle; policy accept;\n'
            '  iifname "' + iface + '" ct state new ct mark set 0x5241\n }\n'
            ' chain out { type route hook output priority mangle; policy accept;\n'
            # Connections opened before the guard have no prerouting mark.
            # Their first reply after TUN activation must survive too. Locally
            # originated traffic has original direction and remains intercepted.
            '  ct direction reply ct mark 0 ct mark set 0x5241\n'
            '  ct mark 0x5241 meta mark set 0x5241\n }\n}\n')


def ipv6_nft():
    # Reply direction preserves inbound sessions, including ones predating the
    # guard. Established *outbound* sessions must not get an exemption.
    return ('table inet remoteagents_ipv6 {\n'
            ' chain out { type filter hook output priority -5; policy accept;\n'
            '  meta nfproto ipv6 oifname "lo" accept\n'
            '  meta nfproto ipv6 ct direction reply ct state established,related accept\n'
            '  meta l4proto ipv6-icmp icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept\n'
            '  meta nfproto ipv6 drop\n }\n}\n')


def nft_normal(text):
    # Kernel pretty-printing uses padded hexadecimal marks and named priorities.
    text = re.sub(r'0x[0-9a-fA-F]+', lambda m: hex(int(m[0], 16)), text)
    text = re.sub(r'((?:ct|meta) mark(?: set)?)\s+(0x[0-9a-fA-F]+|[0-9]+)',
                  lambda m: m[1] + ' ' + hex(int(m[2], 16 if m[2].startswith('0x') else 10)), text)
    text = text.replace('priority mangle', 'priority -150')
    text = re.sub(r'priority filter\s*-\s*5', 'priority -5', text)
    text = text.replace('meta l4proto ipv6-icmp ', '')
    text = re.sub(r'(icmpv6 type|ct state)\s*\{([^{}]+)\}',
                  lambda m: m[1] + ' ' + ','.join(sorted(v.strip() for v in m[2].split(','))), text)
    text = re.sub(r'ct state\s+([a-z,]+)', lambda m: 'ct state ' + ','.join(sorted(m[1].split(','))), text)
    return re.sub(r'\s+', '', text)


class Engine:
    def __init__(self, config, secrets=None, system=None, ssh_checked=False, public_only=False):
        self.config = json.loads(json.dumps(config))
        self.config.pop("tailscale", None)  # Ignore old configurations even for direct callers.
        if 'proxyOut' in self.config:
            self.config['proxyOut'].setdefault('ipv6', 'block')
        self.secrets = dict(secrets or {})
        self.s = system or System()
        self.ssh_checked, self.public_only = ssh_checked, public_only
        self.rows = []
        self.command = 'plan'
        self.receipts = self.s.read('/var/lib/remoteagents/server-apply/receipts.json', {})
        self.module_files = component_files
        self.managed_secrets = {}
        self.checked_lans = {}
        components.hydrate(self)

    def row(self, part, state, message, **fields):
        result = dict(part=part, state=state, summary=message, **fields)
        self.rows.append(result)
        return state == 'ready'

    def secret(self, ref, standard):
        name = (ref or {}).get('secret', standard)
        value = self.secrets.get(name)
        if not value:
            raise Missing(name)
        return value

    def save_receipt(self, name, data):
        self.receipts[name] = data
        self.s.write('/var/lib/remoteagents/server-apply/receipts.json', json.dumps(self.receipts, sort_keys=True) + '\n')

    def singbox(self):
        # Read only these public fields; never cat the complete live configuration.
        projection = '{final:.route.final,tun:[.inbounds[]?|select(.type=="tun")|{auto_route,interface_name,address}],proxy:[.outbounds[]?|select(.tag=="proxy-out")|{type,server,server_port}]}'
        result = self.s.run(['jq', '-c', projection, self.s.path('/etc/sing-box/config.json')], check=False)
        return json.loads(result.stdout) if result.returncode == 0 and result.stdout else {}

    def egress_check(self):
        try:
            return self._egress_check()
        except Exception:
            return False, 'проверка выхода не выполнена; диагностический вывод скрыт'

    def _egress_check(self):
        proxy = self.config.get('proxyOut', {})
        if not proxy:
            return False, 'нужен раздел proxyOut с checkUrl и ожидаемым внешним адресом'
        expected = proxy.get('exitIp', proxy['server'])
        try:
            ipaddress.ip_address(expected)
        except ValueError:
            return False, 'для DNS-имени proxyOut.server укажите proxyOut.exitIp'
        if not proxy.get('checkUrl'):
            return False, 'нужен proxyOut.checkUrl'
        sb = self.singbox()
        if not sb.get('tun') or not any(x.get('auto_route') for x in sb['tun']):
            return False, 'нужен базовый sing-box с системным перехватом трафика; см. SERVER-APPLY.md'
        if sb.get('final') != 'proxy-out':
            return False, 'основной выход sing-box должен быть proxy-out'
        if not self.s.active('sing-box'):
            return False, 'sing-box не запущен'
        rules = self.s.run(['ip', '-j', '-4', 'rule', 'show'])
        own = [r for r in json.loads(rules.stdout) if 9000 <= r.get('priority', -1) <= 9010]
        table = next((str(r['table']) for r in own if r['priority'] == 9000 and r.get('table')), None)
        iface = sb['tun'][0].get('interface_name')
        # Check roles, including both rules with priority 9002. Merely finding
        # one priority would miss a partially deleted sing-box rule set.
        predicates = (
            lambda r: r['priority'] == 9000 and str(r.get('table')) == table,
            lambda r: r['priority'] == 9001 and str(r.get('table')) == table and r.get('suppress_prefixlen') == 0,
            lambda r: r['priority'] == 9002 and r.get('dport') == 53 and str(r.get('table')) in ('main', '254'),
            lambda r: r['priority'] == 9002 and r.get('goto') == 9010 and r.get('iif') and (not iface or r['iif'] == iface),
            lambda r: r['priority'] == 9003 and str(r.get('table')) == table and r.get('iif') == 'lo' and 'not' in r,
            lambda r: r['priority'] == 9003 and str(r.get('table')) == table and r.get('src') == '0.0.0.0',
            lambda r: r['priority'] == 9010 and 'nop' in r)
        if table is None or not all(any(test(r) for r in own) for test in predicates):
            return False, 'пропали правила выхода сервера (9000–9010)'
        got = self.s.run(['curl', '--disable', '--noproxy', '*', '--fail', '--silent', '--max-time', '15', proxy['checkUrl']], check=False)
        if got.returncode or got.stdout.strip() != expected:
            return False, 'внешний адрес сервера не совпадает с ожидаемым выходом'
        return True, 'выход сервера проверен'

    def default_iface(self):
        routes = json.loads(self.s.run(['ip', '-j', '-4', 'route', 'show', 'table', 'main', 'default']).stdout)
        routes = sorted(routes, key=lambda r: r.get('metric', 0))
        require(routes and routes[0].get('dev'), 'Нет внешнего интерфейса в маршруте по умолчанию.')
        return routes[0]['dev']

    def nft_current(self, table, wanted):
        result = self.s.run(['nft', 'list', 'table', 'inet', table], check=False)
        return result.returncode == 0 and nft_normal(result.stdout) == nft_normal(wanted)

    def nft_reconcile(self, table, wanted):
        if self.nft_current(table, wanted):
            return
        exists = self.s.run(['nft', 'list', 'table', 'inet', table], check=False).returncode == 0
        batch = ('delete table inet ' + table + '\n' if exists else '') + wanted
        self.s.run(['nft', '-c', '-f', '-'], input=batch)
        self.s.run(['nft', '-f', '-'], input=batch, change=True)

    def reply_rule(self, family, apply=False):
        rules = json.loads(self.s.run(['ip', '-j', family, 'rule', 'show']).stdout)
        def number(v):
            return int(str(v), 0) if isinstance(v, str) else v
        matching = [r for r in rules if r.get('priority') == 8990 and
                    number(r.get('fwmark', 0)) == 0x5241 and
                    number(r.get('fwmask', 0xffffffff)) == 0xffffffff and
                    str(r.get('table')) in ('main', '254') and
                    not set(r).difference({'priority', 'src', 'table', 'fwmark', 'fwmask', 'protocol'}) and
                    r.get('src', 'all') == 'all']
        if matching:
            return True
        if apply:
            require(not any(r.get('priority') == 8990 for r in rules), 'Приоритет 8990 занят другим правилом; нужно решение владельца.')
            self.s.run(['ip', family, 'rule', 'add', 'pref', '8990', 'fwmark', '0x5241', 'lookup', 'main'], change=True)
            return self.reply_rule(family)
        return False

    def split_tun_table(self):
        rules = json.loads(self.s.run(['ip', '-j', '-4', 'rule', 'show']).stdout)
        table = next((str(r['table']) for r in rules if r.get('priority') == 9000 and r.get('table')), '2022')
        result = self.s.run(['ip', '-j', '-4', 'route', 'show', 'table', table], check=False)
        routes = json.loads(result.stdout or '[]')
        return not any(r.get('dst') in ('default', '0.0.0.0/0') and
                       r.get('type', 'unicast') == 'unicast' for r in routes)

    def reply_families(self):
        addresses = []
        for tun in self.singbox().get('tun', []):
            value = tun.get('address') or []
            addresses.extend(value if isinstance(value, list) else [value])
        return ('-4', '-6') if any(':' in a for a in addresses) else ('-4',)

    def inbound_check(self):
        protected = self.nft_current('remoteagents_inbound', inbound_nft(self.default_iface()))
        protected = all([self.reply_rule(f) for f in self.reply_families()] + [protected])
        split = self.split_tun_table()
        if not protected or split:
            detail = ('нет защиты ответов' if not protected else 'защита ответов установлена')
            if split:
                detail += '; таблица sing-box (обычно 2022) без default'
            return protected, 'ВНИМАНИЕ: ' + INBOUND_WARNING + ' при отсутствии защиты; ' + detail
        return True, 'ответы на входящие подключения защищены'

    def network_guard(self):
        self.nft_reconcile('remoteagents_inbound', inbound_nft(self.default_iface()))
        for family in self.reply_families():
            self.reply_rule(family, apply=True)
        policy = self.config.get('proxyOut', {}).get('ipv6')
        if policy == 'block':
            self.nft_reconcile('remoteagents_ipv6', ipv6_nft())
        elif policy == 'allow':
            if self.s.run(['nft', 'list', 'table', 'inet', 'remoteagents_ipv6'], check=False).returncode == 0:
                self.s.run(['nft', '-f', '-'], input='delete table inet remoteagents_ipv6\n', change=True)

    def guard_apply(self):
        with self.s.network_lock():
            self.network_guard()

    def inbound(self, apply):
        if apply:
            self.guard_apply()
        ok, reason = self.inbound_check()
        return self.row('inbound', 'ready' if ok else 'change', ('уже так; ' if ok else 'будет установлена постоянная защита; ') + reason)

    def ipv6(self, apply):
        policy = self.config.get('proxyOut', {}).get('ipv6')
        if policy is None:
            blocked = self.s.run(['nft', 'list', 'table', 'inet', 'remoteagents_ipv6'], check=False).returncode == 0
            return self.row('ipv6', 'ready', 'ВНИМАНИЕ: proxyOut.ipv6 не задан; IPv6 может идти мимо sing-box; выберите block или allow' +
                            ('; прежний запрет сохранён' if blocked else '; автоматического запрета нет'), warning=True)
        same = (self.nft_current('remoteagents_ipv6', ipv6_nft()) if policy == 'block' else
                self.s.run(['nft', 'list', 'table', 'inet', 'remoteagents_ipv6'], check=False).returncode != 0)
        return self.row('ipv6', 'ready' if same else 'change', ('уже так; ' if same else 'будет настроено; ') +
                        ('исходящий IPv6 запрещён, ответы и ICMPv6 соседей/PMTU разрешены' if policy == 'block' else 'прямой IPv6 разрешён владельцем'))

    def proxy_matches(self, proxy):
        current = self.singbox().get('proxy', [])
        same = len(current) == 1 and all(current[0].get(k) == proxy.get(v) for k, v in
                    (('type', 'type'), ('server', 'server'), ('server_port', 'port')))
        if not same:
            return False
        ref = proxy.get('password')
        if self.public_only or (not ref or ref['secret'] not in self.secrets) and 'login' not in proxy:
            return True
        # Credential comparison is private. No value, hash or surrounding config
        # is returned by the helper or placed in argv.
        script = ('import json,sys; c=json.load(open(sys.argv[1])); n=json.load(sys.stdin); '
                  'o=next((o for o in c.get("outbounds",[]) if o.get("tag")=="proxy-out"),{}); '
                  'sys.exit(0 if (o.get("username","")==n["username"] and (not n["check_password"] or o.get("password","")==n["password"])) else 1)')
        supplied = bool(ref and ref['secret'] in self.secrets)
        payload = dict(username=proxy.get('login', ''), password=self.secrets[ref['secret']] if supplied else '', check_password=supplied)
        return self.s.run(['python3', '-I', '-c', script, self.s.path('/etc/sing-box/config.json')],
                          input=json.dumps(payload), check=False).returncode == 0

    def egress(self, apply):
        proxy = self.config.get('proxyOut', {})
        if not proxy:
            if self.config.get('serverNetwork', {}).get('enabled'):
                return self.row('internet', 'blocked', 'Для serverNetwork.enabled нужен раздел proxyOut с параметрами выхода; базовая сеть не настроена')
            return self.row('internet', 'ready', 'proxyOut не задан; выход не меняется')
        sb = self.singbox()
        if self.s.path(base.STATE).exists():
            if apply and self.ssh_checked:
                with self.s.network_lock():
                    base.confirm(self)
            else:
                return self.row('internet', 'pending', 'Базовая сеть включена; ждёт нового SSH и проверки входящих; автооткат 5 минут')
        if not sb.get('tun') and self.config.get('serverNetwork', {}).get('enabled'):
            require(not self.s.path('/etc/sing-box/config.json').exists(), 'Существующий sing-box без TUN не заменяется автоматически; проверьте его и наличие jq.')
            base.candidate(self)
            if not apply:
                return self.row('internet', 'change', 'Будут установлены sing-box, TUN, защита ответов и IPv6; автооткат до проверки нового SSH')
            with self.s.network_lock():
                base.apply(self)
            return self.row('internet', 'pending', 'Базовая сеть включена; ждёт нового SSH и проверки входящих; автооткат 5 минут')
        if not sb.get('tun'):
            return self.row('internet', 'blocked', 'sing-box не установлен или нет системного перехвата трафика — нужен базовый сетевой конфиг с правилами сохранения SSH; см. SERVER-APPLY.md')
        # Reject foreign ownership and invalid/missing inbound secrets before
        # any guard/proxy mutation, even when proxy and inbounds change together.
        base.inbound_change(self)
        # Install reply protection before a restart can recreate split TUN routes.
        if apply:
            self.guard_apply()
        pending = self.s.path('/var/lib/remoteagents/proxy-out/pending')
        if pending.exists():
            require(self.proxy_matches(proxy), 'Мастер-конфиг отличается от ожидающего proxy-out; сначала завершите прежнее изменение.')
            if apply and self.ssh_checked:
                ok, reason = self.egress_check()
                require(ok, reason)
                self.check_ssh(None)
                self.s.run(['bash', self.s.source / 'proxy-out.sh', 'confirm', '--ssh-checked'], change=True)
                with self.s.network_lock():
                    module('server_recovery').pin_network(self)
            else:
                return self.row('internet', 'pending', 'ждёт нового SSH и --confirm-ssh-checked; автооткат остаётся')
        same = bool(proxy) and self.proxy_matches(proxy)
        ok, reason = self.egress_check()
        if not ok and apply:
            self.s.run(['systemctl', 'restart', 'sing-box'], change=True)
            ok, reason = self.egress_check()
        if not same and proxy:
            if not proxy.get('checkUrl'):
                return self.row('internet', 'blocked', 'нужен proxyOut.checkUrl')
            password = self.secret(proxy['password'], 'proxy-out-password') if proxy.get('password') else ''
            if not apply:
                return self.row('internet', 'change', 'будет проверен и применён proxy-out с автоматическим откатом')
            payload = {'username': proxy.get('login', ''), 'password': password}
            args = ['bash', self.s.source / 'proxy-out.sh', 'apply', '--type', proxy['type'], '--server', proxy['server'],
                    '--port', proxy['port'], '--ip-check-url', proxy['checkUrl'], '--credentials-stdin']
            self.s.run(args, input=MARKER + '\n' + json.dumps(payload), change=True)
            ok, reason = self.egress_check()
            if not ok:
                # proxy_out verified its own expected exit; master-config exitIp
                # adds an independent owner-selected expectation.
                if pending.exists():
                    self.s.run(['bash', self.s.source / 'proxy-out.sh', 'rollback'], change=True)
                return self.row('internet', 'blocked', reason)
            if pending.exists():
                return self.row('internet', 'pending', 'ждёт нового SSH и повторного apply --confirm-ssh-checked; откат через 5 минут')
        if not ok:
            return self.row('internet', 'blocked', reason + '; остальные части не устанавливаются')
        if base.inbound_change(self):
            if not apply:
                return self.row('internet', 'change', 'Входы изменятся транзакционно; нужен новый SSH, автооткат 5 минут')
            with self.s.network_lock():
                base.apply(self, update=True)
            return self.row('internet', 'pending', 'Входы изменены; ждёт нового SSH; автооткат 5 минут')
        return self.row('internet', 'ready', 'уже так; ' + reason)

    def code_files(self):
        target = '/usr/local/lib/remoteagents/server/'
        files = {}

        def read(path):
            try:
                return path.read_bytes()
            except FileNotFoundError:
                raise Error('Пакет кода сервера неполный: нет файла «' + path.name + '». Обновите программу на ПК.') from None

        for name in CODE_FILES:
            files[target + name] = (read(self.s.source / name), 0o755 if name.endswith('.sh') else 0o644)
        schema = self.s.source / 'config.paste.schema.json'
        if not schema.exists():
            schema = self.s.source.parent / 'app/launcher/config.paste.schema.json'
        files[target + 'config.paste.schema.json'] = (read(schema), 0o644)
        for name in ('gateway.py', 'tg_gateway_keys.py', 'tg_gateway_setup.py', 'install.sh', 'README.md'):
            files[target + 'tg-gateway/' + name] = (read(self.s.source / 'tg-gateway' / name), 0o755 if name.endswith('.sh') else 0o644)
        for name, path in components.assets(self.s.source):
            files[target + 'assets/' + name] = (read(path), 0o644)
        return files

    def code_current(self):
        for path, (data, mode) in self.code_files().items():
            p = self.s.path(path)
            if not p.is_file() or p.is_symlink() or p.read_bytes() != data or p.stat().st_mode & 0o777 != mode:
                return False
            if self.s.root == Path('/') and (p.stat().st_uid != 0 or p.stat().st_gid != 0):
                return False
        return True

    def install_code(self):
        target = '/usr/local/lib/remoteagents/server'
        changed = False
        for absolute in ('/usr/local/lib/remoteagents', target, target + '/tg-gateway', target + '/assets', target + '/assets/disk'):
            parent = self.s.path(absolute)
            require(not parent.is_symlink(), 'Каталог установленного кода не должен быть ссылкой.')
            parent.mkdir(parents=True, exist_ok=True, mode=0o755)
            if parent.stat().st_mode & 0o777 != 0o755 or (self.s.root == Path('/') and (parent.stat().st_uid != 0 or parent.stat().st_gid != 0)):
                os.chmod(parent, 0o755)
                if os.geteuid() == 0:
                    os.chown(parent, 0, 0)
                changed = True
        for path, (data, mode) in self.code_files().items():
            changed = self.s.write(path, data, mode) or changed
        # Parents are part of the privilege boundary, including on old installs.
        for parent in (self.s.path('/usr/local/lib/remoteagents'), self.s.path(target), self.s.path(target + '/tg-gateway'), self.s.path(target + '/assets'), self.s.path(target + '/assets/disk')):
            if parent.is_symlink():
                raise Error('Каталог установленного кода не должен быть ссылкой.')
            if parent.stat().st_mode & 0o777 != 0o755 or (self.s.root == Path('/') and (parent.stat().st_uid != 0 or parent.stat().st_gid != 0)):
                os.chmod(parent, 0o755)
                if os.geteuid() == 0:
                    os.chown(parent, 0, 0)
                changed = True
        return changed

    def recovery(self, apply):
        return module('server_recovery').install(self, apply)

    def watch_units(self):
        public = {'kind': 'remoteagents-config', 'schema': 1, 'proxyOut': {k: v for k, v in self.config['proxyOut'].items() if k not in ('login', 'password', 'hint')}}
        return {
            '/etc/systemd/system/remoteagents-network-guard.service': ('[Unit]\nDescription=Preserve inbound replies and IPv6 policy\nWants=network-online.target\nAfter=network-online.target nftables.service\nBefore=sing-box.service\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/local/lib/remoteagents/server/server-apply.sh _network-guard --config /etc/remoteagents/server-apply/watch.json\n[Install]\nWantedBy=multi-user.target\n', 0o644),
            '/etc/remoteagents/server-apply/watch.json': (json.dumps(public, sort_keys=True) + '\n', 0o600),
            '/etc/systemd/system/remoteagents-egress-watch.service': ('[Unit]\nDescription=Check server internet exit and repair sing-box\nAfter=sing-box.service network-online.target\n[Service]\nType=oneshot\nExecStart=/usr/local/lib/remoteagents/server/server-apply.sh _egress-watch --config /etc/remoteagents/server-apply/watch.json\n', 0o644),
            '/etc/systemd/system/remoteagents-egress-watch.timer': ('[Unit]\nDescription=Check server internet exit every minute\n[Timer]\nOnBootSec=1min\nOnUnitActiveSec=1min\nAccuracySec=1s\n[Install]\nWantedBy=timers.target\n', 0o644)}

    def watch(self, apply):
        if not self.config.get('proxyOut'):
            return self.row('egressWatch', 'blocked', 'для сторожа нужен proxyOut')
        units = self.watch_units()
        same = self.code_current() and all(self.s.path(p).exists() and self.s.path(p).read_text() == v[0] for p, v in units.items())
        guard_enabled = self.s.run(['systemctl', 'is-enabled', '--quiet', 'remoteagents-network-guard.service'], check=False).returncode == 0
        same = same and guard_enabled
        live = self.s.active('remoteagents-egress-watch.timer') and self.s.run(['systemctl', 'is-enabled', '--quiet', 'remoteagents-egress-watch.timer'], check=False).returncode == 0
        if apply:
            changed = self.install_code()
            for p, (text, mode) in units.items():
                changed = self.s.write(p, text, mode) or changed
            if changed:
                self.s.run(['systemctl', 'daemon-reload'], change=True)
            if not guard_enabled:
                self.s.run(['systemctl', 'enable', 'remoteagents-network-guard.service'], change=True)
            if not live:
                self.s.run(['systemctl', 'enable', '--now', 'remoteagents-egress-watch.timer'], change=True)
            same = True
        state = self.s.read('/var/lib/remoteagents-status/egress.json', {})
        self.row('egressWatch', 'ready' if same and (live or apply) else 'change',
                 ('уже так; проверка выхода каждую минуту' if same and (live or apply) else 'будет установлен сторож выхода (раз в минуту)') +
                 ('; ВНИМАНИЕ: последняя проверка выхода не удалась' if state.get('ok') is False else ''))

    def lan_part(self, item, apply):
        name, part = item['name'], 'lan:' + item['name']
        def read_state(path, default):
            try:
                value = self.s.read(path, default)
            except (ValueError, UnicodeError):
                raise Error('ЛВС: ' + path + ' повреждён (неверный JSON/UTF-8); требуется восстановление подтверждённой копии.') from None
            except OSError:
                raise Error('ЛВС: не удалось прочитать ' + path + '; проверьте наличие и права файла.') from None
            require(isinstance(value, type(default)), 'ЛВС: ' + path + ' имеет неверную структуру JSON; требуется восстановление подтверждённой копии.')
            return value
        public = read_state('/var/lib/remoteagents-status/lan.json', [])
        require(all(isinstance(p, dict) for p in public), 'ЛВС: публичный статус имеет неверную структуру JSON.')
        current = next((p for p in public if p.get('name') == name), {})
        active = self.s.active('remoteagents-lan@' + name + '.service')
        receipt = self.receipts.get(part, {})
        settings = {k: v for k, v in item.items() if k not in ('hint', 'ovpn', 'password', 'auth', 'login', 'share')}
        if settings.get('serverFingerprint'):
            settings['serverFingerprint'] = lan.normalize_server_fingerprint(settings['serverFingerprint'])
        profile = self.secrets.get(item['ovpn']['secret'])
        digest = hashlib.sha256(profile.replace('\r\n', '\n').encode()).hexdigest() if profile else None
        pending = self.s.path('/var/lib/remoteagents/lan/pending/meta.json')
        if pending.exists():
            meta = read_state('/var/lib/remoteagents/lan/pending/meta.json', {})
            if meta.get('name') == name:
                require('pendingCreated' in receipt and receipt.get('pendingCreated') == meta.get('created'), 'Это изменение ЛВС запущено другой командой; завершите его через lan-vpn.sh.')
                require(receipt.get('settings') == settings, 'Сначала завершите предыдущее изменение ЛВС; параметры изменились.')
                require(not profile or not receipt.get('profileHash') or digest == receipt['profileHash'], 'Сначала завершите предыдущее изменение ЛВС; профиль изменился.')
                if apply and self.ssh_checked:
                    self.check_ssh(name)
                    self.lan_test(item)
                    self.s.run(['bash', self.s.source / 'lan-vpn.sh', 'confirm', name, '--ssh-checked'], change=True)
                    self.save_receipt(part, {'settings': settings, 'profileHash': digest or receipt.get('profileHash')})
                    self.checked_lans[name] = {
                        'config.json': json.dumps(read_state('/etc/remoteagents/lan/' + name + '/config.json', {})),
                        'client.conf': self.s.path('/etc/remoteagents/lan/' + name + '/client.conf').read_text()}
                    with self.s.network_lock():
                        module('server_recovery').pin_network(self, lan_name=name)
                    return self.row(part, 'ready', 'ЛВС проверена; новый SSH подтверждён')
                return self.row(part, 'pending', 'ждёт нового SSH и --confirm-ssh-checked; таймер отката остаётся')
        if self.public_only:
            # Owner-authorized live audit: no private profile or state is read.
            state = 'ready' if current.get('enabled') and current.get('ready') and active else 'waiting'
            return self.row(part, state, 'без изменений; служба работает; профиль и параметры без секретного экспорта не сравнены' if state == 'ready' else 'нужен секрет: ' + item['ovpn']['secret'])
        if not profile:
            raise Missing(item['ovpn']['secret'])
        auth = None
        if item.get('auth'):
            try:
                auth = strict_json(self.secret(item['auth'], 'lan-' + name + '-auth'))
                lan.lan_credentials(auth.get('username'), auth.get('password'))
            except Missing:
                raise
            except Exception:
                raise Error('Секрет ЛВС должен содержать JSON с username/password.') from None
        elif item.get('password'):
            auth = dict(username=item.get('login', ''), password=self.secret(item['password'], 'lan-' + name + '-password'))
        fingerprint = self.discover_fingerprint(profile) if not item.get('serverFingerprint') else None
        if fingerprint:
            return self.row(part, 'blocked', 'CA шлюза без keyUsage; сверьте отпечаток и впишите serverFingerprint: ' + fingerprint,
                            serverFingerprint=fingerprint)
        # Compare the actual normalized private profile, not just a receipt of a
        # previous run: manual edits and changed credentials must be noticed.
        client, static, gateways = lan.import_client(name, None, item.get('subnets', []),
                (auth['username'], auth['password']) if auth else None,
                item.get('directEndpoint', False), settings.get('serverFingerprint'), text=profile)
        existing = read_state('/etc/remoteagents/lan/' + name + '/config.json', {})
        actual_client = self.s.path('/etc/remoteagents/lan/' + name + '/client.conf')
        dns = {'domain': item['dnsDomain'].lower(), 'server': item['dnsServer']} if item.get('dnsDomain') else None
        try:
            actual_profile = actual_client.read_text() if actual_client.exists() else None
        except (OSError, UnicodeError):
            raise Error('ЛВС: client.conf недоступен или повреждён (неверный UTF-8); требуется восстановление подтверждённой копии.') from None
        matched = existing and actual_profile == client and existing.get('static') == static and existing.get('dns') == dns and existing.get('endpoints', []) == gateways and existing.get('server_fingerprint') == settings.get('serverFingerprint')
        tested = read_state('/var/lib/remoteagents/lan/' + name + '.test.json', {})
        confirmed = existing.get('confirmed_at') or tested.get('baseline') and tested.get('baseline') == existing.get('baseline')
        if matched and existing.get('enabled') and existing.get('ready') and active and (confirmed or current.get('ok')):
            # Later CLI/service work can be slow. Save the files checked HERE,
            # never reread a possibly damaged LAN at the end of the whole apply.
            self.checked_lans[name] = {'config.json': json.dumps(existing), 'client.conf': actual_profile}
            return self.row(part, 'ready', 'уже так; профиль и параметры совпадают; служба работает')
        if not apply:
            return self.row(part, 'change', 'будут установлены профиль ЛВС и параметры; затем проверка хоста и нового SSH')
        require(item.get('testHost', item.get('host')), 'Для проверки ЛВС укажите testHost (IPv4) и при необходимости testPort.')
        with self.s.private_file(profile) as file:
            args = ['bash', self.s.source / 'lan-vpn.sh', 'add', name, file, '--ip-check-url', item.get('checkUrl', self.config['proxyOut']['checkUrl'])]
            if existing:
                args.append('--replace')
            for subnet in item.get('subnets', []):
                args += ['--subnet', subnet]
            for field, flag in (('serverFingerprint', '--server-fingerprint'), ('dnsDomain', '--dns-domain'), ('dnsServer', '--dns-server')):
                if item.get(field):
                    args += [flag, item[field]]
            if item.get('directEndpoint'):
                args.append('--direct-endpoint')
            if auth:
                args.append('--auth-stdin')
            self.s.run(args, input=MARKER + '\n' + json.dumps(auth) if auth else None, change=True, timeout=120)
        meta = self.s.read('/var/lib/remoteagents/lan/pending/meta.json', {})
        self.save_receipt(part, {'settings': settings, 'profileHash': digest, 'pendingCreated': meta.get('created')})
        self.lan_test(item)
        self.check_ssh(name)
        # A flag supplied before enable cannot attest an SSH opened afterwards.
        return self.row(part, 'pending', 'хост ЛВС проверен; откройте новое SSH и повторите apply --confirm-ssh-checked; автооткат остаётся')

    def discover_fingerprint(self, profile):
        # NethServer presents its CA as the server certificate. Only report a
        # candidate pin, never turn a discovered certificate into trust.
        match = re.search(r'<ca>\s*(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)\s*</ca>', profile, re.S)
        if not match:
            return None
        result = self.s.run(['openssl', 'x509', '-noout', '-ext', 'keyUsage', '-fingerprint', '-sha256'], input=match[1], check=False)
        if result.returncode == 0 and 'X509v3 Key Usage' not in result.stdout:
            found = re.search(r'(?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}', result.stdout)
            if found:
                return lan.normalize_server_fingerprint(found[0])
        return None

    def lan_test(self, item):
        host, port = item.get('testHost', item.get('host')), item.get('testPort', item.get('port'))
        require(host, 'Для проверки ЛВС укажите testHost.')
        args = ['bash', self.s.source / 'lan-vpn.sh', 'test', item['name'], host]
        if port:
            args.append(port)
        self.s.run(args, change=True)

    def check_ssh(self, name):
        result = self.s.run(['ss', '-Htn', 'state', 'established', '( sport = :22 )'])
        for line in result.stdout.splitlines():
            peer = line.split()[-1].rsplit(':', 1)[0].strip('[]')
            try:
                address = ipaddress.ip_address(peer)
            except ValueError:
                raise Error('Не удалось проверить маршрут текущего SSH-клиента.') from None
            routes = json.loads(self.s.run(['ip', '-j', '-6' if address.version == 6 else '-4', 'route', 'get', peer]).stdout)
            table = str(routes[0].get('table', 254)) if routes else ''
            require(routes and not str(routes[0].get('dev', '')).startswith('tun-lan-') and
                    not (table.isdigit() and 42000 <= int(table) <= 42063), 'Маршрут SSH попал в ЛВС; подтверждение запрещено.')

    def worker(self):
        user = self.config.get('server', {}).get('login')
        require(user and user != 'root' and re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', user), 'Укажите server.login рабочего пользователя (не root).')
        if self.s.root == Path('/'):
            info = pwd.getpwnam(user)
            require(info.pw_uid != 0, 'Рабочий пользователь не должен иметь uid 0.')
            return user, info.pw_uid, Path(info.pw_dir)
        passwd = self.s.path('/etc/passwd').read_text()
        row = next((line.split(':') for line in passwd.splitlines() if line.split(':')[0] == user), None)
        require(row is not None, 'Рабочий пользователь не найден.')
        return user, int(row[2]), Path(row[5])

    def user_cmd(self, *args):
        user, uid, home = self.worker()
        return ['runuser', '-u', user, '--', 'env', 'HOME=' + str(home), 'XDG_RUNTIME_DIR=/run/user/' + str(uid),
                'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/' + str(uid) + '/bus', *args]

    def telegram(self, item, apply):
        if 'enabled' not in item:
            return self.row('telegramGateway', 'ready', 'включение не задано; без изменений')
        user, uid, home = self.worker()
        restored = components.telegram_restore(self, apply)
        try:
            settings = self.s.read(str(home / '.local/opt/tg-gateway/state/settings.json'), {})
        except ValueError:
            settings = {}
        installed = self.s.path(str(home / '.local/opt/tg-gateway/install.sh'))
        ready = settings and installed.exists() and self.s.run(self.user_cmd('bash', str(self.s.path('/usr/local/lib/remoteagents/server/tg-gateway/install.sh')), '--check'), check=False).returncode == 0
        if not item['enabled']:
            live = self.s.run(self.user_cmd('systemctl', '--user', 'is-active', '--quiet', 'tg-gateway.service'), check=False).returncode == 0
            enabled = self.s.run(self.user_cmd('systemctl', '--user', 'is-enabled', '--quiet', 'tg-gateway.service'), check=False).returncode == 0
            if apply and (live or enabled):
                self.s.run(self.user_cmd('systemctl', '--user', 'disable', '--now', 'tg-gateway.service'), change=True)
            return self.row('telegramGateway', 'change' if (live or enabled) and not apply else 'ready', 'будет выключен' if (live or enabled) and not apply else 'выключен')
        if ready and not restored and settings.get('port') == item.get('port', settings.get('port')):
            if apply:
                components.telegram_capture(self)
            return self.row('telegramGateway', 'ready', 'уже так; служба и защищённая проверка /health работают')
        if not apply:
            return self.row('telegramGateway', 'change', 'будет установлен шлюз Telegram от имени рабочего пользователя; секреты создаются установщиком')
        self.s.run(['loginctl', 'enable-linger', user], change=True)
        self.s.run(['systemctl', 'start', 'user@' + str(uid) + '.service'], change=True)
        # runuser cannot traverse root-only staging directories. Use our trusted
        # readable installed copy, not the caller's temporary checkout.
        self.install_code()
        env = ['TG_GW_PORT=' + str(item['port'])] if item.get('port') else []
        if item.get('identity'):
            env.append('TG_GW_PRESERVE_IDENTITY=1')
        if self.config.get('server', {}).get('address'):
            env.append('TG_GW_PUBLIC_HOST=' + self.config['server']['address'])
        cmd = self.user_cmd('env', *env, 'bash', self.s.path('/usr/local/lib/remoteagents/server/tg-gateway/install.sh'))
        self.s.run(cmd, change=True, timeout=90)
        require(self.s.run(self.user_cmd('bash', self.s.path('/usr/local/lib/remoteagents/server/tg-gateway/install.sh'), '--check'), check=False).returncode == 0,
                'Шлюз Telegram не прошёл проверку /health.')
        components.telegram_capture(self)
        self.row('telegramGateway', 'ready', 'шлюз Telegram установлен и проверен')

    def sudo(self, apply):
        user, uid, home = self.worker()
        explicit = 'sudo' in self.config.get('agent', {})
        mode = self.config.get('agent', {}).get('sudo', 'apply')
        full, limited = '/etc/sudoers.d/90-remoteagents', '/etc/sudoers.d/91-remoteagents-apply'
        desired = '' if mode == 'none' else user + (' ALL=(ALL) NOPASSWD: ALL\n' if mode == 'full' else ' ALL=(root) NOPASSWD: /usr/local/lib/remoteagents/server/server-apply.sh\n')
        path = full if mode == 'full' else limited
        conflict = (mode != 'full' and self.s.path(full).exists()) or (mode != 'apply' and self.s.path(limited).exists())
        if conflict and not explicit:
            return self.row('agent', 'blocked', 'существующие права отличаются; укажите agent.sudo явно; ничего не удалено')
        same = mode == 'none' and not conflict or mode != 'none' and self.s.path(path).exists() and ''.join(''.join(line.split('#', 1)[0] for line in self.s.path(path).read_text().splitlines()).split()) == ''.join(desired.split()) and not conflict
        if mode == 'apply' and not self.code_current():
            same = False
        if not apply:
            return self.row('agent', 'ready' if same else 'change', 'уже так' if same else 'будут настроены права агента: ' + mode)
        if mode == 'apply':
            self.install_code()
        if desired and (not same or self.s.path(path).stat().st_mode & 0o777 != 0o440):
            with self.s.private_file(desired) as file:
                self.s.run(['visudo', '-cf', file])
            self.s.write(path, desired, 0o440)
        if explicit:
            for old in (full, limited):
                if old != path or mode == 'none':
                    p = self.s.path(old)
                    if p.exists():
                        p.unlink()
                        self.s.actions.append('удалён ' + old)
        self.row('agent', 'ready', 'права агента: ' + mode)

    def sshd(self, apply):
        path = '/etc/ssh/sshd_config.d/10-remoteagents-startups.conf'
        wanted = 'LoginGraceTime 30\nMaxStartups 30:30:150\n'
        keepalive = self.config.get('ssh', {})
        if keepalive:
            wanted += 'ClientAliveInterval ' + str(keepalive.get('keepaliveIntervalSec', 30)) + '\nClientAliveCountMax ' + str(keepalive.get('keepaliveCountMax', 3)) + '\n'
        file = self.s.path(path)
        old = file.read_bytes() if file.exists() else None
        mode = file.stat().st_mode & 0o777 if file.exists() else 0o644
        def effective():
            r = self.s.run(['/usr/sbin/sshd', '-T'], check=False)
            fields = dict(line.split(None, 1) for line in r.stdout.splitlines() if ' ' in line)
            return r.returncode == 0 and fields.get('logingracetime') == '30' and fields.get('maxstartups') == '30:30:150' and (not keepalive or fields.get('clientaliveinterval') == str(keepalive.get('keepaliveIntervalSec', 30)) and fields.get('clientalivecountmax') == str(keepalive.get('keepaliveCountMax', 3)))
        ssh_live = self.s.active('ssh.service') or self.s.active('sshd.service')
        same = old == wanted.encode() and effective() and ssh_live
        if same or not apply:
            return self.row('sshd', 'ready' if same else 'change', 'уже так; SSH: LoginGraceTime 30, MaxStartups 30:30:150' if same else 'будут настроены лимиты подключений SSH с проверкой и reload')
        try:
            self.s.write(path, wanted, 0o644)
            self.s.run(['/usr/sbin/sshd', '-t'])
            require(effective(), 'sshd не читает drop-in до Match или параметры перекрыты; прежний файл восстановлен.')
            unit = 'sshd.service' if self.s.active('sshd.service') else 'ssh.service'
            self.s.run(['systemctl', 'reload' if ssh_live else 'enable', *([] if ssh_live else ['--now']), unit], change=True)
        except Exception:
            if old is None:
                file.unlink(missing_ok=True)
            else:
                self.s.write(path, old, mode)
            self.s.run(['/usr/sbin/sshd', '-t'], check=False)
            raise
        return self.row('sshd', 'ready', 'SSH: LoginGraceTime 30, MaxStartups 30:30:150; конфиг проверен и перечитан')

    def part(self, name, fn):
        try:
            return fn()
        except Missing as exc:
            return self.row(name, 'waiting', 'ждёт секрет «' + exc.name + '»', missing=[exc.name])
        except Exception as exc:
            message = str(exc) if isinstance(exc, (Error, base.Error, lan.Error, lan_share.Error, components.Error)) else hidden_exception(
                self.s, exc, self.command, name, [self.secrets, self.managed_secrets, self.config.get('secrets', {})])
            return self.row(name, 'error', message)

    def run(self, command):
        self.command = command
        apply = command == 'apply'
        # A channel-rules transaction owns its configs until an external new SSH
        # confirms it. Do not reinstall packages or mutate other network parts.
        if self.s.path(lan_share.STATE).exists():
            confirmed = self.part('lanShare', lambda: lan_share.reconcile(self, apply))
            if not confirmed:
                return dict(schema=1, command=command, parts=self.rows, actions=list(self.s.actions), ok=False)
        if self.config.get('deployment', {}).get('method', 'host') != 'host':
            self.row('deployment', 'blocked', 'Развёртывание docker ещё не поддерживается')
            return dict(schema=1, command=command, parts=self.rows, actions=[], ok=False)
        if self.receipts.get('base-network', {}).get('managed') or self.s.path('/etc/remoteagents/server-apply/recovery.json').exists():
            self.part('packages', lambda: packages.ensure(self, apply))
        ready = self.part('internet', lambda: self.egress(apply))
        if ready:
            # After TUN is verified, user installers use system routing. Python
            # urllib does not support a socks5h proxy environment.
            self.s.download_proxy = None
        if self.config.get('serverNetwork', {}).get('enabled'):
            self.row('bootstrapDownloads', 'ready', 'apt/curl идут через proxyOut до TUN; pip по SOCKS требует PySocks (начальных pip-загрузок нет)' if self.config.get('proxyOut', {}).get('type') == 'socks' else 'начальные загрузки будут использовать HTTP proxyOut до TUN')
        parts = [('inbound', lambda: self.inbound(apply)), ('ipv6', lambda: self.ipv6(apply)),
                 ('egressWatch', lambda: self.watch(apply))]
        if not self.config.get('proxyOut'):
            parts = []
        parts += [('lan:' + item['name'], lambda item=item: self.lan_part(item, apply)) for item in self.config.get('lan', [])]
        # Absent 'lan' = this config does not manage server LANs: keep lanShare as is.
        # Only an explicit 'lan' (even []) may change or remove the share policy.
        if 'lan' in self.config:
            parts.append(('lanShare', lambda: lan_share.reconcile(self, apply)))
        if 'telegramGateway' in self.config:
            parts.append(('telegramGateway', lambda: self.telegram(self.config['telegramGateway'], apply)))
        parts.append(('bridgeState', lambda: components.bridge_state(self, apply)))
        for kind in ('codex', 'claude'):
            if kind in self.config.get('agents', {}):
                parts.append(('agents:' + kind, lambda kind=kind: components.agents(self, kind, apply)))
        for kind in ('disk', 'bridge', 'happier', 'happierWeb'):
            if kind in self.config.get('serverComponents', {}):
                parts.append((kind, lambda kind=kind: getattr(components, kind)(self, apply)))
        parts.append(('extras', lambda: components.extras(self, apply)))
        parts.append(('agent', lambda: self.sudo(apply)))
        parts.append(('sshd', lambda: self.sshd(apply)))
        for name, fn in parts:
            if apply and ready and self.config.get('proxyOut'):
                ready, reason = self.egress_check()
                if not ready:
                    next(r for r in self.rows if r['part'] == 'internet').update(state='blocked', summary=reason)
            if apply and not ready:
                self.row(name, 'blocked', 'не устанавливается: сетевая транзакция ждёт нового SSH' if any(r['state'] == 'pending' for r in self.rows) else 'не устанавливается: выход в интернет не подтверждён')
            else:
                result = self.part(name, fn)
                if apply and not result and (name == 'inbound' or any(r['part'] == name and r['state'] == 'pending' for r in self.rows)):
                    # Do not spend the rollback window downloading CLIs. Return
                    # pending now; a NEW external SSH must confirm the network.
                    ready = False
        if apply and all(r['state'] in ('ready', 'waiting') or r['state'] == 'blocked' and r['part'] in ('desktop', 'projectViews', 'agents:codex') for r in self.rows):
            public = {k: v for k, v in self.config.items() if k in ('deployment', 'serverNetwork', 'proxyOut', 'lan', 'telegramGateway', 'agent', *components.KEYS)}
            if self.part('recovery', lambda: self.recovery(True)):
                self.s.write('/var/lib/remoteagents-status/server-config.json', json.dumps(public, ensure_ascii=False, sort_keys=True) + '\n', 0o644)
                os.chmod(self.s.path('/var/lib/remoteagents-status'), 0o755)
        elif not apply:
            self.part('recovery', lambda: self.recovery(False))
        if apply:
            self.part('log', lambda: self.s.audit(self.rows))
        return {'schema': 1, 'command': command, 'parts': self.rows, 'actions': list(self.s.actions),
                'ok': all(r['state'] == 'ready' for r in self.rows)}


class Missing(Error):
    def __init__(self, name):
        self.name = name


def egress_watch(engine):
    # Protect replies before any restart can recreate the old split routes.
    if any(engine.s.path(p).exists() for p in module('server_recovery').PENDING):
        return False  # The transaction's external confirmation/rollback owns it.
    before = len(engine.s.actions)
    inbound_ok = False
    try:
        engine.network_guard()
        inbound_ok, inbound_reason = engine.inbound_check()
    except Exception:
        inbound_reason = 'ВНИМАНИЕ: ' + INBOUND_WARNING + '; защита не восстановлена'
    if 'ВНИМАНИЕ' in inbound_reason:
        engine.s.run(['logger', '-p', 'daemon.crit', '-t', 'remoteagents-egress-watch', inbound_reason], check=False)
    repaired = len(engine.s.actions) > before
    ok, reason = engine.egress_check()
    if not ok and inbound_ok:
        engine.s.run(['logger', '-t', 'remoteagents-egress-watch', 'Выход сервера нарушен; перезапуск sing-box'], check=False)
        with contextlib.suppress(Exception):
            engine.s.run(['systemctl', 'restart', 'sing-box'], check=False, change=True)
        ok, reason = engine.egress_check()
        repaired = repaired or ok
        if not ok:
            engine.s.run(['logger', '-p', 'daemon.crit', '-t', 'remoteagents-egress-watch', 'ВНИМАНИЕ: выход сервера не восстановлен; проверьте sing-box'], check=False)
    # A split table is diagnostic: restarting would recreate it from exclusions.
    # Leave their migration to LAN; repair only our guard here.
    ok = ok and inbound_ok
    reason += '; ' + inbound_reason
    path = '/var/lib/remoteagents-status/egress.json'
    value = {'ok': ok, 'repaired': repaired, 'summary': reason, 'checkedAt': int(time.time())}
    engine.s.write(path, json.dumps(value, ensure_ascii=False) + '\n', 0o644)
    os.chmod(engine.s.path('/var/lib/remoteagents-status'), 0o755)
    return ok


def delegated():
    # Test the trusted code's real location, not SUDO_COMMAND: sudo may accept a
    # symlink to the allowed executable. The wrapper resolves symlinks too.
    return SOURCE == Path('/usr/local/lib/remoteagents/server') and bool(os.environ.get('SUDO_USER')) and os.environ['SUDO_USER'] != 'root'


def main(argv=None, system=None):
    system = system or System()
    os.umask(0o077)
    parser = argparse.ArgumentParser(description='Настроить сервер из мастер-конфига под root.')
    sub = parser.add_subparsers(dest='command', required=True)
    for command in ('plan', 'apply', 'status', '_egress-watch', '_network-guard', '_reconcile'):
        p = sub.add_parser(command)
        p.add_argument('--config', default='-', help='Файл мастер-конфига или - (stdin)')
        p.add_argument('--json', action='store_true')
        p.add_argument('--secrets-stdin', action='store_true', help='Секреты после строки-маркера stdin')
        if command not in ('_egress-watch', '_network-guard', '_reconcile'):
            p.add_argument('--confirm-ssh-checked', action='store_true', help='Внешний вызывающий уже проверил новое SSH-соединение')
            p.add_argument('--public-only', action='store_true', help='Только публичная сводка ЛВС, без чтения частных профилей')
    args = parser.parse_args(argv)
    require(os.geteuid() == 0 or args.command in ('plan', 'status'), 'Нужен root/sudo.')
    restricted = delegated()
    if restricted:
        require(args.command in ('plan', 'status', 'apply'), 'Ограниченное sudo разрешает только plan/status/apply.')
    if args.command == '_reconcile':
        lockdir = system.path('/run/remoteagents-server-apply')
        lockdir.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (lockdir / 'apply.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            return 0 if module('server_recovery').reconcile(sys.modules[__name__], system) else 1
    config, secrets = read_input(args.config, sys.stdin, args.secrets_stdin, diagnostic=system)
    if restricted:
        require(config.get('server', {}).get('login') == os.environ.get('SUDO_USER') and
                config.get('agent', {}).get('sudo', 'apply') == 'apply', 'Ограниченное sudo не может менять пользователя или расширять права.')
    engine = Engine(config, secrets, system, ssh_checked=getattr(args, 'confirm_ssh_checked', False), public_only=getattr(args, 'public_only', False))
    if args.command in ('_egress-watch', '_network-guard', '_reconcile'):
        with engine.s.network_lock():
            if args.command == '_network-guard':
                engine.network_guard()
                return 0
            return 0 if egress_watch(engine) else 1
    # Readers create no files, including locks. Apply serializes its own runs;
    # network managers retain the separate shared network transaction lock.
    if args.command == 'apply':
        lockdir = engine.s.path('/run/remoteagents-server-apply')
        lockdir.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (lockdir / 'apply.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = engine.run(args.command)
    else:
        result = engine.run(args.command)
    if args.json:
        print(json.dumps(result, ensure_ascii=False))
    else:
        for row in result['parts']:
            labels = {'inbound': 'Ответы на входящие', 'ipv6': 'IPv6', 'internet': 'Выход в интернет', 'egressWatch': 'Сторож выхода', 'telegramGateway': 'Шлюз Telegram', 'agent': 'Права агента', 'log': 'Журнал', 'sshd': 'Настройка SSH'}
            label = 'ЛВС «' + row['part'][4:] + '»' if row['part'].startswith('lan:') else labels.get(row['part'], row['part'])
            print(label + ': ' + row['summary'])
        if args.command == 'apply':
            print('Без изменений.' if not result['actions'] else 'Действий: ' + str(len(result['actions'])))
    return 0 if args.command != 'apply' or result['ok'] else 1


if __name__ == '__main__':
    system = System()
    try:
        sys.exit(main(system=system))
    except Exception as exc:
        # Never interpolate subprocess, JSON, crypto or OS exception strings.
        message = str(exc) if isinstance(exc, Error) else hidden_exception(
            system, exc, sys.argv[1] if len(sys.argv) > 1 else 'main', 'main',
            fallback='Ошибка файла/команды; детали скрыты.')
        if '--json' in sys.argv:
            print(json.dumps({'ok': False, 'error': message}, ensure_ascii=False))
        else:
            print('Ошибка: ' + message, file=sys.stderr)
        sys.exit(1)
