"""Конфиг «remoteagents-2»: проверка, применение, возврат и вид для остального кода.

Файлы в папке данных (home):
  config\\active.json   - применённый конфиг как вставлен (секреты остаются зашифрованными), config\\prev.json - прежний
  private\\v2\\          - то, что раскладывается из конфига: id_key, known_hosts, ssh-profile.json, channel.json, secrets\\entries\\<имя>.json
  state\\vpn.json, state\\control.json - выбор из конфига, пишутся только при применении

Режим для сервера: python3 -m ralab.v2config seal <вход.json> <выход.json> | check <файл.json>
Значения секретов нигде не печатаются и в журнал не пишутся.
"""
import csv, glob, json, os, re, shutil, subprocess, sys, time

from . import journal

try:
    from . import secretbox
except ImportError:  # дорожка v14-1 ещё не влита
    secretbox = None

FORMAT = 'remoteagents-2'
MAX_BYTES = 1024 * 1024
NAME_RE = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$')
VPN_MODES = ('off', 'auto', 'only')
KDF_MAX = 5000000
KEYS = ('entries', 'relays', 'cdn', 'hops', 'wsEntries')
NOT_CONFIG = 'Это не конфиг RemoteAgents.'


def _dirs(home):
    return (os.path.join(home, 'config', 'active.json'), os.path.join(home, 'config', 'prev.json'),
            os.path.join(home, 'private', 'v2'), os.path.join(home, 'private', 'v2.prev'))


def _protect(path):
    """Убрать наследование ACL секретного файла в Windows."""
    if sys.platform != 'win32':
        return

    def failed(tool, **data):
        try:
            journal.log('v2config', 'acl.failed', dict(data, tool=tool, file=os.fspath(path)))
        except Exception:
            pass

    options = dict(timeout=15, creationflags=0x08000000, stdin=subprocess.DEVNULL, capture_output=True)
    user = os.environ.get('USERNAME', '')
    try:
        result = subprocess.run(['whoami', '/user', '/fo', 'csv', '/nh'], **options)
        if result.returncode:
            failed('whoami', code=result.returncode)
        else:
            row = next(csv.reader(result.stdout.decode('utf-8-sig', 'replace').splitlines()))
            sid = row[1].strip()
            if re.fullmatch(r'S-\d+(?:-\d+)+', sid):
                user = '*' + sid
            else:
                failed('whoami', reason='invalid SID')
    except Exception as e:
        failed('whoami', kind=e.__class__.__name__)
    try:
        if not user:
            failed('icacls', reason='no current user')
            return
        result = subprocess.run(['icacls', os.fspath(path), '/inheritance:r', '/grant:r',
                                 '*S-1-5-18:F', '*S-1-5-32-544:F', user + ':F'], **options)
        if result.returncode:
            failed('icacls', code=result.returncode)
    except Exception as e:
        failed('icacls', kind=e.__class__.__name__)


def protect_existing(home):
    """Исправить права секретных файлов, записанных прежними версиями."""
    if sys.platform != 'win32':
        return
    active, prev, v2, _ = _dirs(home)
    paths = [os.path.join(v2, 'id_key'), os.path.join(v2, 'channel.json'), active, prev]
    paths += glob.glob(os.path.join(v2, 'secrets', 'entries', '*.json'))
    for path in paths:
        if os.path.isfile(path):
            _protect(path)


def _write(path, text, secret=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    if secret:
        try:
            os.chmod(tmp, 0o600)
        except OSError:
            pass
    try:
        os.replace(tmp, path)
    except OSError:
        _rm(tmp)
        raise
    if secret:
        _protect(path)


def _write_bytes(path, data):
    tmp = path + '.tmp'
    with open(tmp, 'wb') as f:
        f.write(data)
    os.replace(tmp, path)


def _rm(path):
    if os.path.isdir(path):
        shutil.rmtree(path, ignore_errors=True)
    elif os.path.exists(path):
        try:
            os.remove(path)
        except OSError:
            pass


def _port(server):
    p = server.get('port', 22)
    return p if isinstance(p, int) and not isinstance(p, bool) and 0 < p < 65536 else None


def _has(d, k):
    return isinstance(d.get(k), str) and bool(d[k].strip())


def _validate(text):
    """-> (cfg | None, [проблемы]); без расшифровки."""
    if not isinstance(text, str) or len(text.encode('utf-8', 'ignore')) > MAX_BYTES:
        return None, ['Конфиг слишком большой или пустой.']
    try:
        cfg = json.loads(text.lstrip('﻿'))
    except ValueError:
        return None, [NOT_CONFIG]
    if not isinstance(cfg, dict) or cfg.get('format') != FORMAT:
        return None, [NOT_CONFIG]
    pr = []
    srv, paths = cfg.get('server'), cfg.get('paths')
    srv = srv if isinstance(srv, dict) else {}
    paths = paths if isinstance(paths, dict) else {}
    if not _has(cfg, 'name'):
        pr.append('В конфиге нет имени.')
    for k in ('host', 'user', 'hostKey', 'key'):
        if not _has(srv, k):
            pr.append('В конфиге нет сведений о сервере (%s).' % k)
    if _port(srv) is None:
        pr.append('В конфиге неверный порт сервера.')
    vpn = cfg.get('vpn')
    if vpn is not None and (not isinstance(vpn, dict) or vpn.get('mode', 'off') not in VPN_MODES):
        pr.append('Неверный режим VPN (допустимо: off, auto, only).')
    kdf = cfg.get('kdf')
    if kdf is not None and not (isinstance(kdf, dict) and isinstance(kdf.get('iterations'), int) and not isinstance(kdf['iterations'], bool)
                                and 1 <= kdf['iterations'] <= KDF_MAX):
        pr.append('Неверные параметры пароля в конфиге.')
    if not (paths.get('entries') or paths.get('channel')):
        pr.append('В конфиге нет путей канала.')
    for n in paths.get('entries') or []:
        nm = n.get('name') if isinstance(n, dict) else n
        if not isinstance(nm, str) or not NAME_RE.match(nm):
            pr.append('Неверное имя узла входа.')
            break
    if not isinstance(paths.get('secrets') or {}, dict):
        pr.append('Неверный раздел секретов.')
    for n in (paths.get('secrets') or {}) if isinstance(paths.get('secrets') or {}, dict) else []:
        if not NAME_RE.match(str(n)):
            pr.append('Неверное имя секрета узла.')
            break
    return cfg, pr


def _secret_values(cfg):
    """[(где, значение)] для всех секретов конфига."""
    paths = cfg.get('paths') or {}
    out = [('server.key', (cfg.get('server') or {}).get('key'))]
    if paths.get('channel'):
        out.append(('paths.channel', paths['channel']))
    out += [('paths.secrets.' + str(k), v) for k, v in (paths.get('secrets') or {}).items()]
    return out


def apply(text, password, home):
    """Принять вставленный конфиг. -> {"ok", "problems"}."""
    cfg, pr = _validate(text)
    if pr:
        return {'ok': False, 'problems': pr}
    if secretbox is None:
        return {'ok': False, 'problems': ['Не удалось проверить пароль: нет модуля шифрования.']}
    try:
        if not isinstance(cfg.get('kdf'), dict) or not isinstance(cfg.get('check'), str):
            return {'ok': False, 'problems': ['Конфиг не защищён паролем.']}
        key = secretbox.derive(password or '', cfg['kdf'])
        if not secretbox.password_ok(cfg['check'], key):
            return {'ok': False, 'problems': ['Неверный пароль.']}
        plain = {}
        for where, v in _secret_values(cfg):
            if not isinstance(v, str) or not v.startswith('enc1:'):
                return {'ok': False, 'problems': ['В конфиге есть незашифрованный секрет.']}
            plain[where] = secretbox.decrypt(v, key)
    except (ValueError, TypeError, KeyError):
        return {'ok': False, 'problems': ['Неверный пароль.']}
    srv, paths = cfg['server'], cfg.get('paths') or {}
    port = _port(srv)
    active, prev, v2, v2prev = _dirs(home)
    base = v2 + '.new'
    undo = []  # что сделать при сбое (в обратном порядке)
    try:
        _rm(base)
        _rm(prev + '.old'), _rm(v2prev + '.old')  # остатки прерванного применения
        key_text = plain['server.key'].replace('\r\n', '\n')
        _write(os.path.join(base, 'id_key'), key_text if key_text.endswith('\n') else key_text + '\n', secret=True)
        host = srv['host']
        _write(os.path.join(base, 'known_hosts'), '%s %s\n' % (host if port == 22 else '[%s]:%d' % (host, port), srv['hostKey'].strip()))
        _write(os.path.join(base, 'ssh-profile.json'), json.dumps({
            'serverAddress': host, 'login': srv['user'], 'keyPath': os.path.join(v2, 'id_key'),
            'knownHostsPath': os.path.join(v2, 'known_hosts'), 'arguments': ['-p', str(port)]}, ensure_ascii=False, indent=1))
        if paths.get('channel'):
            json.loads(plain['paths.channel'])
            _write(os.path.join(base, 'channel.json'), plain['paths.channel'], secret=True)
        for n in (paths.get('secrets') or {}):
            json.loads(plain['paths.secrets.' + str(n)])
            _write(os.path.join(base, 'secrets', 'entries', str(n) + '.json'), plain['paths.secrets.' + str(n)], secret=True)
        vpn = cfg.get('vpn') if isinstance(cfg.get('vpn'), dict) else {}
        _write(active + '.new', text if text.endswith('\n') else text + '\n', secret=True)
        # переключение: каждый шаг запоминает, как его отменить; прежняя пара prev/v2.prev уходит в .old и либо возвращается, либо удаляется
        pair = os.path.isfile(prev) and os.path.isdir(v2prev)
        moved = []

        def restore_pair():
            for f in reversed(moved):
                _rm(f)
                os.replace(f + '.old', f)
        undo.append(restore_pair)
        if pair:
            os.replace(prev, prev + '.old')
            moved.append(prev)
            os.replace(v2prev, v2prev + '.old')
            moved.append(v2prev)
        else:
            _rm(prev), _rm(v2prev)
        if os.path.isdir(v2):
            os.replace(v2, v2prev)
            undo.append(lambda: os.replace(v2prev, v2))
        os.replace(base, v2)
        undo.append(lambda: _rm(v2))
        if os.path.isfile(active):
            os.replace(active, prev)
            undo.append(lambda: os.replace(prev, active))
        os.replace(active + '.new', active)
        undo.append(lambda: _rm(active))
        for name, val in (('vpn.json', {'mode': vpn.get('mode') or 'off'}), ('control.json', {'enabled': bool(cfg.get('control'))})):
            f = os.path.join(home, 'state', name)
            if os.path.isfile(f):
                with open(f, 'rb') as fh:
                    old = fh.read()
                undo.append(lambda f=f, old=old: _write_bytes(f, old))
            elif not os.path.exists(f):
                undo.append(lambda f=f: _rm(f))
            _write(f, json.dumps(val))
    except Exception as e:  # в ответ и журнал идёт только имя ошибки: текст может содержать лишнее
        for fn in reversed(undo):
            try:
                fn()
            except Exception:
                pass
        _rm(base)
        _rm(active + '.new')
        return {'ok': False, 'problems': ['Не удалось применить конфиг (%s).' % e.__class__.__name__]}
    _rm(prev + '.old')
    _rm(v2prev + '.old')
    return {'ok': True, 'problems': []}


def revert(home):
    """Вернуть прежний конфиг; прежнего нет - убрать текущий (снова прежний путь чтения)."""
    active, prev, v2, v2prev = _dirs(home)
    old = v2 + '.old'
    undo = []
    try:
        _rm(old)
        if os.path.isfile(prev) and os.path.isdir(v2prev):
            if os.path.exists(v2):
                os.replace(v2, old)
                undo.append(lambda: os.replace(old, v2))
            os.replace(v2prev, v2)
            undo.append(lambda: os.replace(v2, v2prev))
            os.replace(prev, active)
        else:
            _rm(active), _rm(prev), _rm(v2), _rm(v2prev)
    except Exception as e:
        for fn in reversed(undo):
            try:
                fn()
            except Exception:
                pass
        return {'ok': False, 'problems': ['Не удалось вернуть прежний конфиг (%s).' % e.__class__.__name__]}
    _rm(old)
    return {'ok': True, 'problems': []}


def _read(home):
    try:
        with open(_dirs(home)[0], encoding='utf-8-sig') as f:
            cfg = json.load(f)
        return cfg if isinstance(cfg, dict) and cfg.get('format') == FORMAT else None
    except (OSError, ValueError):
        return None


def status(home):
    cfg = _read(home)
    if not cfg:
        return {'has': False, 'name': '', 'server': '', 'time': ''}
    try:
        t = time.strftime('%Y-%m-%d %H:%M', time.localtime(os.path.getmtime(_dirs(home)[0])))
    except OSError:
        t = ''
    return {'has': True, 'name': str(cfg.get('name') or ''), 'server': str((cfg.get('server') or {}).get('host') or ''), 'time': t}


def _items(v):
    return [{'name': x} if isinstance(x, str) else x for x in (v or []) if isinstance(x, (str, dict))]


def legacy_view(home):
    """Словарь той же формы, что даёт конфиг Программы (settings.load); None - своего конфига нет."""
    cfg = _read(home)
    if not cfg:
        return None
    v2 = _dirs(home)[2]
    p, srv = cfg.get('paths') or {}, cfg.get('server') or {}
    t = {'profilePath': os.path.join(v2, 'ssh-profile.json'), 'cacheRoot': v2}
    if p.get('channel'):
        t['channelPath'] = os.path.join(v2, 'channel.json')
    for k in KEYS:
        t[k] = _items(p.get(k))
    if isinstance(cfg.get('disk'), dict) and cfg['disk'].get('syncPort'):
        t['syncPort'] = cfg['disk']['syncPort']
    elif cfg.get('syncPort'):
        t['syncPort'] = cfg['syncPort']
    out = {'transport': t}
    for k in ('lan', 'happier', 'forwards', 'lanProxy', 'tun'):
        if k in cfg:
            out[k] = cfg[k]
    if isinstance(cfg.get('vpn'), dict):
        out['vpn'] = {k: v for k, v in cfg['vpn'].items() if k != 'mode'}
    d = cfg.get('disk')
    if isinstance(d, dict) and d.get('home'):
        out['disk'] = {'home': d['home']}
    return out


# --- режим для сервера -------------------------------------------------------------------------------------------

def _need_box():
    if secretbox is None:
        sys.exit('Нет модуля шифрования (secretbox).')


def seal(src, dst):
    _need_box()
    import getpass
    with open(src, encoding='utf-8-sig') as f:
        text = f.read()
    cfg, pr = _validate(text)
    if pr:
        sys.exit('; '.join(pr))
    pw = os.environ.get('RA_PASSWORD') or getpass.getpass('Пароль конфига: ')
    if not pw:
        sys.exit('Пароль пустой.')
    cfg['kdf'] = secretbox.new_kdf()
    key = secretbox.derive(pw, cfg['kdf'])
    cfg['check'] = secretbox.make_check(key)

    def enc(v):
        return secretbox.encrypt(v, key)
    cfg['server']['key'] = enc(cfg['server']['key'])
    paths = cfg.setdefault('paths', {})
    if paths.get('channel'):
        paths['channel'] = enc(paths['channel'] if isinstance(paths['channel'], str) else json.dumps(paths['channel']))
    if paths.get('secrets'):
        paths['secrets'] = {k: enc(v if isinstance(v, str) else json.dumps(v)) for k, v in paths['secrets'].items()}
    tmp = dst + '.tmp'
    with open(tmp, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(cfg, f, ensure_ascii=False, indent=1)
        f.write('\n')
    os.chmod(tmp, 0o600)
    os.replace(tmp, dst)


def check(path):
    """Проверка без расшифровки: формат, поля, что секреты уже зашифрованы. -> [проблемы]"""
    with open(path, encoding='utf-8-sig') as f:
        cfg, pr = _validate(f.read())
    if cfg is None:
        return pr
    if not isinstance(cfg.get('kdf'), dict) or not isinstance(cfg.get('check'), str) or not cfg['check'].startswith('enc1:'):
        pr.append('Конфиг не запечатан (нет kdf или check).')
    pr += ['Секрет не зашифрован: %s.' % w for w, v in _secret_values(cfg) if not (isinstance(v, str) and v.startswith('enc1:'))]
    return pr


def main(argv):
    if len(argv) == 4 and argv[1] == 'seal':
        seal(argv[2], argv[3])
        print('Готово: %s' % argv[3])
        return 0
    if len(argv) == 3 and argv[1] == 'check':
        pr = check(argv[2])
        print('Конфиг в порядке.' if not pr else '\n'.join(pr))
        return 1 if pr else 0
    print('Использование: python3 -m ralab.v2config seal <вход.json> <выход.json> | check <файл.json>', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
