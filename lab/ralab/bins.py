"""Вшитые в EXE программы (sing-box, ssh, значок Диска, список сетей РФ): <home>\\runtime\\bin.zip -> <home>\\runtime\\bin-<12 hex>\\.
Сверка каждого файла по bin-manifest.json; при несовпадении после распаковки - в журнал и None (берутся прежние места поиска)."""
import hashlib, json, os, shutil, zipfile

from . import journal

_dir = None
_why = ''
_bad = {}
_strict = False
_said = set()


def why(rel=''):
    """Причина, почему вшитого файла нет (пустая строка - всё в порядке); rel - причина по конкретному файлу."""
    return (_bad or {}).get(rel) or ('' if _bad else _why)


def strict():
    """Режим «только свои копии»: включён, если рядом лежит runtime\\bin.zip. Без него - старый поиск (EXE без вшитых программ)."""
    return _strict


def report(key, text):
    """Одна запись в журнал на причину (чтобы повторные поиски не засоряли журнал)."""
    if key not in _said:
        _said.add(key)
        journal.log('bins', key, {}, text)


def warn_old():
    report('old-mode', 'EXE без вшитых программ: ищу чужие, старый режим')


def _fail(text):
    global _why
    _why = text
    report('why:' + text, text)
    return None


def _sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def _check(folder):
    """-> {файл: причина} для каждого файла манифеста, который отсутствует или не совпал; None - манифест не прочитать."""
    try:
        with open(os.path.join(folder, 'bin-manifest.json'), encoding='utf-8-sig') as f:
            man = json.load(f)
        items = sorted(man.items())
    except (OSError, ValueError, AttributeError):
        return None
    bad = {}
    for rel, want in items:
        try:
            if _sha(os.path.join(folder, *rel.split('/'))) != want:
                bad[rel] = 'Антивирус изменил %s: файл не используется' % rel
        except OSError:
            bad[rel] = 'Антивирус удалил %s: файла нет' % rel
    return bad


def prepare(home, log):
    """-> папка с файлами или None. log(текст) - запись в журнал. Каждый файл проверяется отдельно: испорченный не отдаётся find()."""
    global _dir, _why, _strict, _bad
    _dir, _why, _bad = None, '', {}
    rt = os.path.join(home, 'runtime')
    zp = os.path.join(rt, 'bin.zip')
    _strict = os.path.isfile(zp)
    if not _strict:
        _why = 'bin.zip не найден (EXE без вшитых программ)'
        warn_old()
        return None
    try:
        folder = os.path.join(rt, 'bin-' + _sha(zp)[:12])
    except Exception as e:
        return _fail('Не удалось прочитать bin.zip: %s' % e)
    bad = _check(folder) if os.path.isdir(folder) else None
    if bad is None or bad:
        tmp = folder + '.tmp'
        shutil.rmtree(tmp, ignore_errors=True)
        try:
            with zipfile.ZipFile(zp) as z:
                z.extractall(tmp)
        except Exception as e:  # OSError, BadZipFile, zlib.error, EOFError, RuntimeError
            shutil.rmtree(tmp, ignore_errors=True)
            if not os.path.isdir(folder) or _check(folder) is None:
                return _fail('Не удалось распаковать вшитые программы: %s' % e)
            report('extract', 'Не удалось заново распаковать вшитые программы (%s): остаётся прежняя папка' % e)
        else:
            if _check(tmp) is None:
                shutil.rmtree(tmp, ignore_errors=True)
                return _fail('Антивирус удалил или изменил bin-manifest.json: вшитые программы не используются')
            try:  # замена папки: занятый файл не должен ронять запуск; прежняя копия остаётся
                old = folder + '.old'
                shutil.rmtree(old, ignore_errors=True)
                if os.path.isdir(folder):
                    os.rename(folder, old)
                try:
                    os.rename(tmp, folder)
                except OSError:
                    if os.path.isdir(old) and not os.path.isdir(folder):
                        os.rename(old, folder)
                    raise
                shutil.rmtree(old, ignore_errors=True)
            except OSError as e:
                shutil.rmtree(tmp, ignore_errors=True)
                if not os.path.isdir(folder):
                    return _fail('Не удалось обновить вшитые программы (файл занят: %s)' % e)
                report('replace', 'Не удалось обновить вшитые программы (файл занят: %s): остаётся прежняя папка' % e)
    _bad = _check(folder)
    if _bad is None:
        _bad = {}
        return _fail('Антивирус удалил или изменил bin-manifest.json: вшитые программы не используются')
    for rel, why_ in _bad.items():
        report('bad:' + rel, why_)
    _why = '; '.join(_bad.values())
    _dir = folder
    src, dst = os.path.join(folder, 'rules', 'geoip-ru.srs'), os.path.join(home, 'state', 'vpn-geoip-ru.srs')
    if 'rules/geoip-ru.srs' not in _bad and os.path.isfile(src) and not os.path.exists(dst):
        tmpd = dst + '.tmp'
        try:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, tmpd)
            os.replace(tmpd, dst)
        except OSError as e:
            try:
                os.remove(tmpd)
            except OSError:
                pass
            log('Не удалось положить список сетей: %s' % e)
    try:  # уборка старых папок - после всего остального и без права мешать
        olds = sorted((d for d in os.listdir(rt) if d.startswith('bin-') and not d.endswith(('.tmp', '.old')) and os.path.join(rt, d) != folder
                       and os.path.isdir(os.path.join(rt, d))), key=lambda d: os.path.getmtime(os.path.join(rt, d)), reverse=True)
        for d in olds[1:]:  # остаются текущая и одна предыдущая
            shutil.rmtree(os.path.join(rt, d), ignore_errors=True)
    except OSError as e:
        report('cleanup', 'Не удалось убрать старые папки вшитых программ: %s' % e)
    return folder


def find(rel):
    """-> путь к файлу во вшитой папке или None (нет папки, файл не прошёл проверку суммы или его нет)."""
    if not _dir or rel in _bad:
        return None
    p = os.path.join(_dir, *rel.split('/'))
    return p if os.path.isfile(p) else None
