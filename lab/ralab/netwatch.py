"""Сторож сети: уведомления Windows о смене интерфейсов и маршрутов (iphlpapi, ctypes). Только публикует net.changed.

Колбэк хранится в поле объекта (иначе его соберёт сборщик мусора), внутри - только bus.publish. Повторы сворачиваются флагом,
который снимает подписчик (ack()). На не-Windows ничего не делает.
"""
import sys

from . import journal
from .bus import bus


class NetWatch:
    def __init__(self, ctx):
        self.ctx, self.pending, self.handles, self._cb = ctx, False, [], None
        bus.subscribe('app.start', self._on_start)
        bus.subscribe('app.stop', self._on_stop)

    def ack(self):
        self.pending = False

    def _changed(self, *_):
        if not self.pending:
            self.pending = True
            bus.publish('net.changed')

    def _on_start(self, _):
        if sys.platform != 'win32':
            return
        import ctypes
        from ctypes import wintypes
        ip = ctypes.WinDLL('iphlpapi')
        self._cb = ctypes.WINFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int)(self._changed)
        for fn in (ip.NotifyIpInterfaceChange, ip.NotifyRouteChange2):
            h = wintypes.HANDLE()
            # (Family=AF_UNSPEC, Callback, Context, InitialNotification=FALSE, &Handle)
            rc = fn(0, self._cb, None, False, ctypes.byref(h))
            if rc == 0:
                self.handles.append(h)
            else:
                journal.log('netwatch', 'register.failed', {'fn': fn.__name__, 'code': rc})
        journal.log('netwatch', 'ready', {'handles': len(self.handles)})

    def _on_stop(self, _):
        if sys.platform != 'win32':
            return
        import ctypes
        ip = ctypes.WinDLL('iphlpapi')
        for h in self.handles:
            ip.CancelMibChangeNotify2(h)
        self.handles = []
