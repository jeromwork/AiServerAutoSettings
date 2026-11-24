"""Уборка собственных следов Windows; данные программы и Диск сохраняются.

proxy-set.json: {"ProxyEnable": 0, "ProxyServer": null, ...}; null означает,
что значения прежде не было. Допускается {"values": {...}} и запись значения
как {"value": ..., "type": <тип winreg>}. Метка удаляется только после отката.
log(текст) получает короткие сообщения без содержимого системных настроек.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


_ADAPTERS = r"""Get-NetAdapter -IncludeHidden | Where-Object {
    ($_.Name -like 'RA2-LAN*' -or $_.Name -like 'RA2-VPN*' -or
     $_.Name -like 'RemoteAgents-Lab*' -or
     $_.Name -like 'ralab-tun*' -or $_.Name -like 'ralab-vpn*') -and
    $_.InterfaceDescription -in @('sing-tun Tunnel', 'Wintun Userspace Tunnel')
}"""
_NRPT = "Get-DnsClientNrptRule | Where-Object { $_.Comment -like 'RemoteAgents-Lab*' }"
_TASKS = "Get-ScheduledTask | Where-Object { $_.TaskName -like 'RemoteAgents-Lab*' }"
_INTERNET = r'Software\Microsoft\Windows\CurrentVersion\Internet Settings'
_PROXY_NAMES = {'ProxyEnable', 'ProxyServer', 'ProxyOverride', 'AutoConfigURL', 'AutoDetect'}
_BEGIN = re.compile(r'(?m)^#[ \t]*(RemoteAgents-Lab[^\r\n]*?)[ \t]+begin[ \t]*(?:\r?\n|$)')
_BLOCK = re.compile(r'(?m)^#[ \t]*(RemoteAgents-Lab[^\r\n]*?)[ \t]+begin[ \t]*\r?\n'
                    r'[\s\S]*?^#[ \t]*\1[ \t]+end[^\r\n]*(?:\r?\n|$)')


def _quote(value):
    return "'" + str(value).replace("'", "''") + "'"


class _Cleanup:
    def __init__(self, home, log, mode='startup', reading=False):
        self.home = Path(home).resolve()
        if self.home == Path(self.home.anchor):
            raise ValueError('Нужна папка данных программы')
        self.log, self.mode, self.reading = log, mode, reading
        self.end = time.monotonic() + (28 if mode == 'exit' else 59)
        self.issues = []

    def remaining(self):
        left = self.end - time.monotonic()
        if left <= 0:
            raise TimeoutError('Время уборки истекло')
        return left

    def command(self, argv, accepted=(0,), env=None):
        # Резерв на остановку дерева: дочерний cmd не должен пережить тайм-аут.
        limit = min(20, self.remaining() - 1)
        if limit <= 0:
            raise TimeoutError('Время уборки истекло')
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, env=env, creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            out, _ = proc.communicate(timeout=limit)
        except subprocess.TimeoutExpired:
            try:
                subprocess.run(['taskkill.exe', '/F', '/T', '/PID', str(proc.pid)],
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW,
                               timeout=min(0.5, self.remaining()))
            except (OSError, subprocess.SubprocessError, TimeoutError):
                pass
            try:
                proc.kill()
                proc.wait(timeout=min(0.25, self.remaining()))
            except (OSError, subprocess.SubprocessError, TimeoutError):
                pass
            # Не используем Popen как контекстный менеджер: его __exit__ ждёт без
            # тайм-аута. Не ждём и закрытия каналов зависшими потомками.
            raise TimeoutError('Команда не завершилась за отведённое время') from None
        if proc.returncode not in accepted:
            raise RuntimeError('Код команды: %d' % proc.returncode)
        return out.decode('utf-8-sig', 'replace').strip()

    def ps(self, script):
        prefix = ("$ErrorActionPreference='Stop'; "
                  "[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false); ")
        return self.command(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', prefix + script])

    def query(self, script):
        data = json.loads(self.ps('ConvertTo-Json -InputObject @(' + script + ') -Compress -Depth 5') or '[]')
        return data if isinstance(data, list) else ([] if data is None else [data])

    def step(self, name, action):
        try:
            self.remaining()
            action()
        except Exception as exc:
            self.note('%s: не удалось выполнить (%s)' % (name, type(exc).__name__))

    def note(self, text):
        if text in self.issues:
            return
        self.issues.append(text)
        if self.log:
            try:
                self.log(text)
            except Exception:
                pass

    def owned_conditions(self):
        conds = [
            '$_.ProcessId -ne %d' % os.getpid(),
            '$_.ProcessId -ne $PID',
            '$_.ExecutablePath',
            '$_.ExecutablePath.StartsWith(%s, [StringComparison]::OrdinalIgnoreCase)'
            % _quote(str(self.home).rstrip('\\/') + '\\'),
        ]
        try:
            ppid = os.getppid()
            if ppid > 0:
                conds.append('$_.ProcessId -ne %d' % ppid)
        except (AttributeError, OSError):
            pass
        ra_exe = os.environ.get('RA_EXE')
        if ra_exe:
            conds.append('(-not ($_.ExecutablePath -eq %s))' % _quote(ra_exe))
        return ' -and '.join(conds)

    def owned(self):
        # Граница каталога исключает соседнюю папку с тем же началом имени.
        return 'Get-CimInstance Win32_Process | Where-Object { %s }' % self.owned_conditions()

    def processes(self):
        if not self.reading:
            self.ps("$failed=0; @(%s) | ForEach-Object { $id=$_.ProcessId; "
                    "try { Stop-Process -Id $id -Force } "
                    "catch { if (Get-Process -Id $id -ErrorAction SilentlyContinue) { $failed++ } }; "
                    "if ($failed) { throw 'processes' }"
                    % self.owned())
            if self.query(self.owned() + ' | Select-Object ProcessId'):
                self.note('Процессы: остались запущенные программы из папки данных')
        else:
            script = (
                "$all = @(Get-CimInstance Win32_Process); "
                "$desc = [System.Collections.Generic.HashSet[int]]::new(); "
                "$q = [System.Collections.Generic.Queue[int]]::new(); "
                "$q.Enqueue(%d); "
                "while ($q.Count -gt 0) { "
                "  $cur = $q.Dequeue(); "
                "  foreach ($p in $all) { "
                "    if ($p.ParentProcessId -eq $cur -and $desc.Add([int]$p.ProcessId)) { $q.Enqueue([int]$p.ProcessId) } "
                "  } "
                "}; "
                "@($all | Where-Object { %s -and (-not $desc.Contains([int]$_.ProcessId)) }) | Select-Object ProcessId"
                % (os.getpid(), self.owned_conditions())
            )
            if self.query(script):
                self.note('Процессы: остались запущенные программы из папки данных')

    def net_running(self):
        return bool(self.query(self.owned() + " | Where-Object { "
            "$_.Name -match '^(sing-box.*|ralab-core|RA2-VPN)\\.exe$' } | Select-Object ProcessId"))

    def adapters(self):
        if self.net_running():
            if not self.reading:
                self.note('Адаптеры: удаление пропущено, сетевой процесс ещё работает')
            return
        adapters = self.query(_ADAPTERS + ' | Select-Object PnPDeviceID, Name, Status')
        for adapter in adapters:
            self.remaining()
            name = str(adapter.get('Name') or 'адаптер')
            status = str(adapter.get('Status') or '')
            if status.lower() == 'up':
                self.note('Адаптеры: %s в состоянии Up, удаление пропущено' % name)
                continue
            if self.reading:
                self.note('Адаптеры: осталось устройство программы')
            else:
                self.step('Адаптер', lambda a=adapter: self.command(
                    ['pnputil.exe', '/remove-device', a['PnPDeviceID']], accepted=(0, 3010)))

    def rules(self):
        if self.reading:
            if self.query(_NRPT + ' | Select-Object Name'):
                self.note('DNS: остались правила программы')
        else:
            self.ps('$failed=0; @(%s) | ForEach-Object { try { '
                    'Remove-DnsClientNrptRule -Name $_.Name -Force } catch { $failed++ } }; '
                    "if ($failed) { throw 'dns' }" % _NRPT)

    def hosts(self):
        path = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/drivers/etc/hosts'
        raw = path.read_bytes()
        bom, encoding = b'', 'latin-1'
        for prefix, codec in ((b'\xef\xbb\xbf', 'latin-1'), (b'\xff\xfe', 'utf-16-le'), (b'\xfe\xff', 'utf-16-be')):
            if raw.startswith(prefix):
                bom, encoding = prefix, codec
                break
        # Latin-1 даёт обратимое соответствие байтам, в том числе для UTF-8 без
        # BOM и старых кодировок. UTF-16 с BOM также сохраняется без перекодировки.
        text = raw[len(bom):].decode(encoding, errors='surrogatepass')
        clean = _BLOCK.sub('', text)
        if self.reading:
            if _BEGIN.search(text):
                self.note('Имена компьютеров: остались записи программы')
            return
        if _BEGIN.search(clean):
            self.note('Имена компьютеров: найден незакрытый блок, требуется проверка')
        if clean == text:
            return
        self.remaining()
        fd, name = tempfile.mkstemp(prefix='RemoteAgents-Lab-', suffix='.tmp', dir=path.parent)
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(bom + clean.encode(encoding, errors='surrogatepass'))
                stream.flush()
                os.fsync(stream.fileno())
            self.remaining()
            os.replace(name, path)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    def proxy(self):
        marker = self.home / 'state/proxy-set.json'
        if not marker.exists():
            return
        if self.reading:
            self.note('Прокси: осталось сохранённое изменение настроек')
            return
        import winreg
        data = json.loads(marker.read_text(encoding='utf-8-sig'))
        values = data.get('values', data)
        if not isinstance(values, dict) or not values or not values.keys() <= _PROXY_NAMES:
            raise ValueError('Неверная запись прежних настроек прокси')
        restore = []
        for name, entry in values.items():
            if isinstance(entry, dict) and ('value' not in entry or not entry.keys() <= {'value', 'type'}):
                raise ValueError('Неверная запись прежнего значения прокси')
            value = entry.get('value') if isinstance(entry, dict) else entry
            kind = entry.get('type') if isinstance(entry, dict) else None
            kind = kind if kind is not None else (winreg.REG_DWORD if type(value) is int else winreg.REG_SZ)
            if value is not None and not ((kind == winreg.REG_DWORD and type(value) is int and 0 <= value <= 0xffffffff)
                    or (kind in (winreg.REG_SZ, winreg.REG_EXPAND_SZ) and isinstance(value, str))):
                raise ValueError('Неверный тип прежнего значения прокси')
            restore.append((name, value, kind))
        with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, _INTERNET, 0, winreg.KEY_SET_VALUE) as key:
            for name, value, kind in restore:
                self.remaining()
                if value is None:
                    try:
                        winreg.DeleteValue(key, name)
                    except FileNotFoundError:
                        pass
                else:
                    winreg.SetValueEx(key, name, 0, kind, value)
        # Уведомление WinINet в отдельном процессе с общим ограничением времени.
        self.ps("Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; "
                "public class ProxyNotify { [DllImport(\"wininet.dll\")] public static extern bool "
                "InternetSetOption(IntPtr h, int o, IntPtr b, int l); }'; "
                "if (-not [ProxyNotify]::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0)) { throw 'notify' }; "
                "if (-not [ProxyNotify]::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0)) { throw 'refresh' }")
        marker.unlink()

    def tasks(self):
        if self.reading:
            if self.query(_TASKS + ' | Select-Object TaskName'):
                self.note('Автозапуск: остались прежние задачи программы')
        else:
            self.ps('$failed=0; @(%s) | ForEach-Object { try { Unregister-ScheduledTask -TaskName $_.TaskName '
                    '-TaskPath $_.TaskPath -Confirm:$false } catch { $failed++ } }; '
                    "if ($failed) { throw 'tasks' }" % _TASKS)

    def registry(self):
        if self.reading:
            script = r"""$run='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';
if ((Test-Path -LiteralPath $run) -and
    ((Get-Item -LiteralPath $run).GetValueNames() -contains 'RemoteAgents-Lab')) { 'startup' }
"""
            if self.ps(script):
                self.note('Реестр: осталась запись автозапуска')
        else:
            script = r"""$base='HKCU:\Software\Classes\Directory\shell';
if (Test-Path -LiteralPath $base) {
    Get-ChildItem -LiteralPath $base | Where-Object { $_.PSChildName -like 'RemoteAgents.LabDisk.*' } |
    ForEach-Object { Remove-Item -LiteralPath $_.PSPath -Recurse -Force }
}
$run='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';
if ((Test-Path -LiteralPath $run) -and
    ((Get-Item -LiteralPath $run).GetValueNames() -contains 'RemoteAgents-Lab')) {
    Remove-ItemProperty -LiteralPath $run -Name 'RemoteAgents-Lab'
}
"""
            self.ps(script)

    @staticmethod
    def linked(path):
        return path.is_symlink() or path.is_junction()

    def walk(self, folder):
        self.remaining()
        if not folder.exists() or self.linked(folder):
            return
        with os.scandir(folder) as entries:
            for entry in entries:
                self.remaining()
                path = Path(entry.path)
                if entry.is_dir(follow_symlinks=False) and not self.linked(path):
                    yield from self.walk(path)
                else:
                    yield path

    def remove(self, path):
        self.remaining()
        # Не обходим ссылки и точки соединения: данные за ними не принадлежат уборке.
        if self.linked(path):
            os.rmdir(path) if path.is_junction() else path.unlink()
        elif path.is_dir():
            with os.scandir(path) as entries:
                for entry in entries:
                    self.remaining()
                    self.step('Временный файл', lambda p=Path(entry.path): self.remove(p))
            path.rmdir()
        else:
            path.unlink(missing_ok=True)

    def file(self, path):
        if self.reading:
            self.note('Файлы: остался временный файл или файл отката')
        else:
            self.step('Временный файл', lambda: self.remove(path))

    def files(self):
        for path in self.walk(self.home):
            if path.name.lower().endswith(('.ralab-part', '.ralab-tmp')):
                self.file(path)
        temp = os.environ.get('TEMP') or os.environ.get('TMP')
        folders = [(Path(temp), True)] if temp else []
        folders.append((self.home / 'tmp', False))
        for folder, old_only in folders:
            self.remaining()
            if self.linked(folder):
                if not old_only:
                    self.file(folder)
                else:
                    self.note('Временные файлы: папка является ссылкой, обход пропущен')
                continue
            if not folder.exists():
                continue
            with os.scandir(folder) as entries:
                for entry in entries:
                    self.remaining()
                    path = Path(entry.path)
                    if old_only and not entry.name.lower().startswith('ralab'):
                        continue
                    if path == self.home or path in self.home.parents:
                        continue
                    self.file(path)
        desktop = self.ps("[Environment]::GetFolderPath('DesktopDirectory')")
        if not desktop:
            raise RuntimeError('Не удалось найти рабочий стол')
        stop = Path(desktop) / 'RemoteAgents-Lab СТОП.cmd'
        if stop.exists():
            self.file(stop)

    def undo(self):
        folder = self.home / 'undo'
        if self.linked(folder):
            self.note('Откат изменений: папка является ссылкой, обход пропущен')
            return
        if not folder.exists():
            return
        files = []
        with os.scandir(folder) as entries:
            for entry in entries:
                self.remaining()
                if entry.name.lower().endswith('.cmd'):
                    if self.linked(Path(entry.path)):
                        self.note('Откат изменений: файл является ссылкой, запуск пропущен')
                    elif entry.is_file(follow_symlinks=False):
                        files.append((entry.stat().st_mtime_ns, entry.name, Path(entry.path)))
        for _, _, path in sorted(files, reverse=True):
            self.remaining()
            def apply(path=path):
                # Значение переменной не проходит повторное раскрытие % в cmd;
                # отключаем !-подстановки и сохраняем кавычки для пути с пробелами.
                argv = subprocess.list2cmdline([os.environ.get('ComSpec', 'cmd.exe')])
                self.command(argv + ' /D /S /V:OFF /C ""%RA_UNDO_FILE%""',
                             env={**os.environ, 'RA_UNDO_FILE': str(path)})
                path.unlink()  # Неудачный откат сохраняем для следующего запуска.
            if self.reading:
                self.note('Файлы: остался файл отката')
            else:
                self.step('Откат изменения', apply)


def _perform(mode, home, log=None, reading=False):
    if os.name != 'nt':
        return ['Уборка системы доступна только в Windows']
    work = _Cleanup(home, log, mode=mode, reading=reading)
    steps = [('Процессы', work.processes), ('Откат изменений', work.undo),
             ('Адаптеры', work.adapters), ('DNS', work.rules),
             ('Имена компьютеров', work.hosts), ('Прокси', work.proxy), ('Задачи', work.tasks)]
    if reading or mode == 'exit':
        steps.append(('Реестр', work.registry))
    steps.append(('Файлы', work.files))
    for name, action in steps:
        work.step(name, action)
    return work.issues


def run(mode: str, home, log) -> list[str]:
    """Убрать свои следы до подъёма сети или после остановки; вернуть неудавшиеся шаги."""
    if mode not in ('startup', 'exit'):
        raise ValueError('Неизвестный режим уборки')
    return _perform(mode, home, log)


def check(home) -> list[str]:
    """Перечислить оставшиеся следы и ошибки проверки, ничего не изменяя."""
    return _perform('exit', home, reading=True)
