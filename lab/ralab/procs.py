"""Процессы: потоки-читатели stdout/stderr, поток ожидания (событие proc.exited), Job Object (Windows) / killpg (Linux).

Читатели работают до конца потока, ожидание - до выхода процесса. Мягкой остановке TUN даём до 3 с.
Пределы: живых процессов 64, строка 8 КБ.
"""
import os, signal, subprocess, sys, threading, time

from . import journal
from .bus import bus

WIN = sys.platform == 'win32'
NO_WINDOW = 0x08000000 if WIN else 0  # CREATE_NO_WINDOW
MAX_PROCS, LINE_MAX = 64, 8192
_lock = threading.Lock()
_procs = {}
_job = None


def _job_init():
    """Свой Job Object Python: если Python умрёт, Windows погасит всех детей (KILL_ON_JOB_CLOSE)."""
    global _job
    import ctypes
    from ctypes import wintypes

    class IO(ctypes.Structure):
        _fields_ = [(n, ctypes.c_ulonglong) for n in ('r', 'w', 'o', 'rb', 'wb', 'ob')]

    class BASIC(ctypes.Structure):
        _fields_ = [('PerProcessUserTimeLimit', ctypes.c_int64), ('PerJobUserTimeLimit', ctypes.c_int64), ('LimitFlags', wintypes.DWORD),
                    ('MinimumWorkingSetSize', ctypes.c_size_t), ('MaximumWorkingSetSize', ctypes.c_size_t), ('ActiveProcessLimit', wintypes.DWORD),
                    ('Affinity', ctypes.c_size_t), ('PriorityClass', wintypes.DWORD), ('SchedulingClass', wintypes.DWORD)]

    class EXT(ctypes.Structure):
        _fields_ = [('Basic', BASIC), ('Io', IO), ('ProcessMemoryLimit', ctypes.c_size_t), ('JobMemoryLimit', ctypes.c_size_t),
                    ('PeakProcessMemoryUsed', ctypes.c_size_t), ('PeakJobMemoryUsed', ctypes.c_size_t)]
    k = ctypes.WinDLL('kernel32', use_last_error=True)
    k.CreateJobObjectW.restype = wintypes.HANDLE
    k.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
    k.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    k.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    h = k.CreateJobObjectW(None, None)
    info = EXT()
    info.Basic.LimitFlags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if not h or not k.SetInformationJobObject(h, 9, ctypes.byref(info), ctypes.sizeof(info)):
        journal.log('procs', 'job.failed', {'err': ctypes.get_last_error()})
        return None
    _job = (k, h)
    return _job


def _assign(popen):
    if not WIN:
        return
    j = _job or _job_init()
    if j and not j[0].AssignProcessToJobObject(j[1], int(popen._handle)):  # сразу после Popen: за доли секунды потомков ещё нет
        journal.log('procs', 'job.assign_failed', {'pid': popen.pid})


class Proc:
    def __init__(self, name, popen, src, binary, on_out, on_err, join_readers, graceful):
        self.name, self.popen, self.src, self.binary = name, popen, src, binary
        self.on_out, self.on_err, self.join_readers = on_out, on_err, join_readers
        self.pid, self.killed = popen.pid, False
        self.graceful = graceful
        self.readers = [threading.Thread(target=self._read, args=(popen.stdout, True), daemon=True),
                        threading.Thread(target=self._read, args=(popen.stderr, False), daemon=True)]

    def start(self):
        for t in self.readers:
            t.start()
        threading.Thread(target=self._wait, daemon=True).start()

    def _read(self, stream, is_out):
        raw = is_out and self.binary
        cb = self.on_out if is_out else self.on_err
        buf = b''
        try:
            while True:
                chunk = stream.read1(65536)
                if not chunk:
                    break
                if raw:
                    cb and cb(chunk)
                    continue
                buf += chunk
                while True:
                    i = buf.find(b'\n')
                    if i < 0:
                        break
                    line, buf = buf[:i], buf[i + 1:]
                    self._line(line, is_out, cb)
                if len(buf) > LINE_MAX:  # слишком длинная строка режется
                    self._line(buf[:LINE_MAX], is_out, cb)
                    buf = b''
            if buf and not raw:
                self._line(buf, is_out, cb)
        except (OSError, ValueError):
            pass  # поток закрыт при гашении процесса

    def _line(self, b, is_out, cb):
        text = b.decode('utf-8', 'replace').rstrip('\r')
        journal.log(self.src, 'stdout' if is_out else 'stderr', {'pid': self.pid, 'line': text})
        cb and cb(text)

    def _wait(self):
        code = self.popen.wait()
        if self.join_readers:
            for t in self.readers:
                t.join()
        with _lock:
            _procs.pop(self.name, None)
        journal.log(self.src, 'exit', {'name': self.name, 'pid': self.pid, 'code': code})
        bus.publish('proc.exited', {'name': self.name, 'code': code, 'pid': self.pid, 'killed': self.killed})

    def write(self, data):
        try:
            self.popen.stdin.write(data)
            self.popen.stdin.flush()
            return True
        except (OSError, ValueError, AttributeError):
            return False

    def close_stdin(self):
        try:
            self.popen.stdin.close()
        except (OSError, ValueError, AttributeError):
            pass

    def alive(self):
        return self.popen.poll() is None

    def _soft_stop(self):
        method = 'AttachConsole+CTRL_BREAK' if WIN else 'SIGTERM'
        try:
            deadline = time.monotonic() + 3
            if WIN:
                # Хелпер не меняет консоль/стандартные handles многопоточного Python из EXE.
                code = ('import ctypes,sys; k=ctypes.WinDLL("kernel32",use_last_error=True); '
                        'pid=int(sys.argv[1]); '
                        'ok=k.AttachConsole(pid) and k.GenerateConsoleCtrlEvent(1,pid); '
                        'sys.exit(0 if ok else (ctypes.get_last_error() or 1))')
                r = subprocess.run([sys.executable, '-c', code, str(self.pid)], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=NO_WINDOW, timeout=1)
                if r.returncode:
                    raise OSError('console helper: %s' % r.returncode)
            else:
                os.killpg(self.pid, signal.SIGTERM)
            self.popen.wait(timeout=max(0, deadline - time.monotonic()))
            journal.log(self.src, 'stop.soft', {'pid': self.pid, 'method': method, 'code': self.popen.returncode})
            return True
        except (OSError, subprocess.SubprocessError) as e:
            journal.log(self.src, 'stop.fallback', {'pid': self.pid, 'method': method, 'error': str(e)})
            return False

    def kill(self):
        if not self.alive():
            return
        self.killed = True
        if self.graceful and self._soft_stop():
            return
        journal.log(self.src, 'kill', {'name': self.name, 'pid': self.pid})
        try:
            if WIN:  # дерево процессов: cmd /c и его потомки
                subprocess.run(['taskkill', '/F', '/T', '/PID', str(self.pid)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, creationflags=NO_WINDOW)
            else:
                os.killpg(self.pid, signal.SIGKILL)
        except (OSError, subprocess.SubprocessError):
            pass
        try:
            self.popen.kill()
        except OSError:
            pass


def start(name, argv, src=None, binary=False, on_out=None, on_err=None, stdin=False, cwd=None, env=None, join_readers=True, graceful=False):
    """Запуск процесса. argv - список (или строка командной строки на Windows). Строки stderr (и stdout, если не binary) идут
    в журнал и в колбэки по одной; при binary=True stdout отдаётся колбэку кусками байт."""
    with _lock:
        if name in _procs:
            raise ValueError('процесс %s уже запущен' % name)
        if len(_procs) >= MAX_PROCS:
            raise ValueError('слишком много процессов (%d)' % MAX_PROCS)
    kw = dict(stdin=subprocess.PIPE if stdin else subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=cwd, env=env)
    if WIN:
        kw['creationflags'] = subprocess.CREATE_NEW_PROCESS_GROUP if graceful else NO_WINDOW
        if graceful:  # Без NO_WINDOW: консоль нужна для CTRL_BREAK; из EXE Windows создаст её скрытой.
            si = subprocess.STARTUPINFO()
            si.dwFlags, si.wShowWindow = subprocess.STARTF_USESHOWWINDOW, subprocess.SW_HIDE
            kw['startupinfo'] = si
    else:
        kw['start_new_session'] = True
    p = subprocess.Popen(argv, **kw)
    _assign(p)
    pr = Proc(name, p, src or name.split(':')[0], binary, on_out, on_err, join_readers, graceful)
    with _lock:
        _procs[name] = pr
    journal.log(pr.src, 'start', {'name': name, 'pid': p.pid, 'argv': argv if isinstance(argv, str) else list(argv)})
    pr.start()
    return pr


def get(name):
    return _procs.get(name)


def kill(name):
    p = _procs.get(name)
    if p:
        p.kill()


def kill_all():
    for p in list(_procs.values()):
        p.kill()


def names():
    return list(_procs)
