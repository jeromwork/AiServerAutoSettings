"""Автозапуск RemoteAgents при входе текущего пользователя в Windows."""
import ntpath
import os
import re
import subprocess
import xml.etree.ElementTree as ET


_TASK = 'RemoteAgents Автозапуск'


def _command(*args):
    return subprocess.run(['schtasks.exe', *args], stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0), timeout=20)


def apply(on: bool, exe: str, log):
    """Установить задачу с актуальным путём EXE либо удалить её; log(текст)."""
    try:
        if os.name != 'nt':
            raise RuntimeError('Автозапуск доступен только в Windows')
        if on:
            exe = os.fspath(exe)
            if not ntpath.isabs(exe) or any(c in exe for c in '\"\r\n'):
                raise ValueError('Нужен полный путь к программе')
            domain, user = os.environ.get('USERDOMAIN', ''), os.environ['USERNAME']
            account = domain + '\\' + user if domain else user
            # /F обновляет также задачу, созданную для предыдущего пути EXE.
            result = _command('/Create', '/TN', _TASK, '/SC', 'ONLOGON', '/RL', 'HIGHEST',
                              '/F', '/TR', '"%s" --autostart' % exe, '/RU', account, '/IT')
            if result.returncode:
                result = _command('/Create', '/TN', _TASK, '/SC', 'ONLOGON', '/RL', 'HIGHEST',
                                  '/F', '/TR', '"%s" --autostart' % exe)
            if result.returncode:
                raise RuntimeError('Планировщик вернул код %d' % result.returncode)
        else:
            q = _command('/Query', '/TN', _TASK)
            if q.returncode == 0:
                result = _command('/Delete', '/TN', _TASK, '/F')
                if result.returncode:
                    raise RuntimeError('Планировщик вернул код %d' % result.returncode)
    except Exception as exc:
        if log:
            log('Не удалось изменить автозапуск (%s)' % type(exc).__name__)
        raise
    if log:
        log('Автозапуск включён' if on else 'Автозапуск выключен')


def enabled() -> bool:
    """Есть ли включённая задача автозапуска текущей установки."""
    if os.name != 'nt':
        return False
    try:
        result = _command('/Query', '/TN', _TASK, '/XML')
        if result.returncode:
            return False
        raw = result.stdout
        text = None
        for enc in ('oem', 'cp866', 'cp1251', 'mbcs', 'latin-1'):
            try:
                text = raw.decode(enc)
                break
            except (UnicodeError, LookupError):
                continue
        if text is None:
            return False
        text = re.sub(r'<\?xml[^>]*\?>', '', text, count=1).strip()
        root = ET.fromstring(text)
        return root.findtext('{*}Settings/{*}Enabled', default='true').lower() != 'false'
    except (OSError, subprocess.SubprocessError, ET.ParseError):
        return False
