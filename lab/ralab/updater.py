"""Приём присланного кода (ra-lab push): zip -> проверка -> code\\<имя>\\ -> code\\pending.json -> перезапуск (код выхода 3).

В zip берутся только .py и code-version.txt в корне zip (run_lab.py, ralab/**/*.py). Пути с .. и абсолютные отклоняются, не больше
500 файлов, не больше 1 МБ на файл и 20 МБ всего. Каждый .py компилируется (compile, без записи pyc): ошибка возвращается ассистенту
как «файл:строка», ничего не перезапускается. Имя папки = c-<12 знаков sha256 zip>; версия кода = имя папки.
pending.json = {"dir": "<имя>"}. Папки current/lastGood из code\\state.json (пишет только EXE) и emb-* не удаляются; новых не больше 5.
"""
import hashlib, io, json, os, re, shutil, zipfile

from . import journal
from .bus import bus

FILES_MAX, FILE_MAX, TOTAL_MAX, DIRS_MAX = 500, 1 << 20, 20 << 20, 5
NAME_OK = re.compile(r'^(run_lab\.py|code-version\.txt|ralab/[A-Za-z0-9_./-]*\.py)$')


class Updater:
    def __init__(self, ctx):
        self.ctx = ctx
        self.code = os.path.join(ctx.home, 'code')

    def clear_pending(self):
        try:
            os.remove(os.path.join(self.code, 'pending.json'))
        except OSError:
            pass

    def install(self, data, sha):
        """-> {'ok': True, 'dir': имя} или {'ok': False, 'errors': [...]}. Вызывается из потока агента."""
        bus.publish('code.received', {'bytes': len(data)})

        def reject(errors):
            bus.publish('code.rejected', {'errors': errors[:20]})
            return {'ok': False, 'errors': errors[:20]}
        digest = hashlib.sha256(data).hexdigest()
        if sha and sha.lower() != digest:
            return reject(['не сошёлся sha256 (получено %s)' % digest[:12]])
        try:
            z = zipfile.ZipFile(io.BytesIO(data))
        except zipfile.BadZipFile:
            return reject(['это не zip'])
        infos = [i for i in z.infolist() if not i.is_dir()]
        if len(infos) > FILES_MAX or sum(i.file_size for i in infos) > TOTAL_MAX or any(i.file_size > FILE_MAX for i in infos):
            return reject(['слишком много или слишком большие файлы (>%d, >%d МБ всего, >%d МБ файл)' % (FILES_MAX, TOTAL_MAX >> 20, FILE_MAX >> 20)])
        errors, files = [], {}
        for i in infos:
            n = i.filename
            if n.startswith('/') or '\\' in n or ':' in n or '..' in n.split('/') or not NAME_OK.match(n):
                errors.append('недопустимый путь в zip: %s' % n[:80])
                continue
            files[n] = z.read(i)
        if 'run_lab.py' not in files:
            errors.append('в zip нет run_lab.py')
        for n, b in files.items():
            if n.endswith('.py'):
                try:
                    compile(b, n, 'exec')
                except SyntaxError as e:
                    errors.append('%s:%s: %s' % (n, e.lineno, e.msg))
        if errors:
            return reject(errors)
        name = 'c-' + digest[:12]
        tmp, final = os.path.join(self.code, name + '.tmp'), os.path.join(self.code, name)
        try:
            shutil.rmtree(tmp, ignore_errors=True)
            for n, b in files.items():
                p = os.path.join(tmp, *n.split('/'))
                os.makedirs(os.path.dirname(p), exist_ok=True)
                with open(p, 'wb') as f:
                    f.write(b)
            if os.path.isdir(final):
                shutil.rmtree(tmp, ignore_errors=True)  # тот же код уже распакован
            else:
                os.rename(tmp, final)
            with open(os.path.join(self.code, 'pending.json.tmp'), 'w', encoding='utf-8') as f:
                json.dump({'dir': name}, f)
            os.replace(os.path.join(self.code, 'pending.json.tmp'), os.path.join(self.code, 'pending.json'))
        except OSError as e:
            return reject(['не записать код: %s' % e.__class__.__name__])
        self._prune(name)
        journal.log('updater', 'installed', {'dir': name, 'files': len(files)}, 'код принят и проверен, перезапуск Python с кодом 3')
        return {'ok': True, 'dir': name, 'files': len(files)}

    def _prune(self, keep_name):
        protect = {keep_name}
        try:
            with open(os.path.join(self.code, 'state.json'), encoding='utf-8-sig') as f:
                protect |= {v for v in json.load(f).values() if isinstance(v, str)}
        except (OSError, ValueError):
            pass
        protect.add(self.ctx.version)
        try:
            dirs = [d for d in os.listdir(self.code) if os.path.isdir(os.path.join(self.code, d))]
            for d in dirs:
                if d.endswith('.tmp') and d != keep_name + '.tmp':
                    shutil.rmtree(os.path.join(self.code, d), ignore_errors=True)
            ours = sorted((d for d in dirs if d.startswith('c-') and d not in protect), key=lambda d: os.path.getmtime(os.path.join(self.code, d)), reverse=True)
            for d in ours[max(0, DIRS_MAX - len(protect)):]:
                shutil.rmtree(os.path.join(self.code, d), ignore_errors=True)
        except OSError:
            pass
