import importlib.machinery
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / 'server/agent-tools/ra-logs'

SAMPLE = '''\
2026-11-20T09:00:00.000Z 12:00:00.000+03:00 INFO  launcher  launcher.start s=aaaa ver=1.6.0 device=Компьютер
2026-11-20T09:10:00.000Z 12:10:00.000+03:00 INFO  vpn       vpn.click.on   s=aaaa att=on-091000-aa fromCard=False
2026-11-20T09:10:01.000Z 12:10:01.000+03:00 WARN  conflict  conflict.detected s=bbbb name=Happ iface=happ-xray ifIndex=12 route=0.0.0.0/0 metric=0 why=known-vpn-full-route
2026-11-20T09:10:02.000Z 12:10:02.000+03:00 WARN  vpn       vpn.on.response s=aaaa att=on-091000-aa state=conflict stage=conflicts conflict=Happ ms=1800
2026-11-20T09:20:00.000Z 12:20:00.000+03:00 INFO  vpn       vpn.click.on   s=aaaa att=on-092000-bb fromCard=False
2026-11-20T09:20:03.000Z 12:20:03.000+03:00 INFO  vpn       vpn.on.ok      s=aaaa att=on-092000-bb ms=3000
2026-11-20T09:20:05.000Z 12:20:05.000+03:00 WARN  net       net.e2e        s=aaaa att=on-092000-bb result=fail stage=7 reason=dns-fail detail=timeout
2026-11-20T09:30:00.000Z 12:30:00.000+03:00 WARN  net       net.state      s=aaaa from=ok to=fail vpn=on stage=4 reason=port-closed detail="port=ssh:2222(timeout)"
2026-11-20T09:31:00.000Z 12:31:00.000+03:00 INFO  net       net.state      s=aaaa from=fail to=ok vpn=on down_ms=60000
2026-11-20T09:32:00.000Z 12:32:00.000+03:00 INFO  transport switch         s=cccc from=vless-direct to=vless-relay why=verdict-path-dial-failed verified=True
2026-11-20T09:33:00.000Z 12:33:00.000+03:00 WARN  core      core.exit      s=dddd code=1 ms_alive=5000 tail="FATAL boom\\nsecond"
2026-11-20T09:34:00.000Z 12:34:00.000+03:00 WARN  ship      ship.gap       s=aaaa stream=core lost=unknown
2026-11-20T09:35:00.000Z old-format-event some text here
2026-11-20T09:36:00.000Z 12:36:00.000+03:00 ERROR launcher launcher.failed s=aaaa err=example
this line is not a log line
'''


def load():
    loader = importlib.machinery.SourceFileLoader('ra_logs', str(TOOL))
    spec = importlib.util.spec_from_loader('ra_logs', loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class RaLogs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        device = Path(self.tmp.name) / 'Компьютер--WIN-1'
        device.mkdir()
        (device / 'launcher-2026-11-20.log').write_text('﻿' + SAMPLE, encoding='utf-8')
        self.env = dict(os.environ, RA_LOGS_IN_ROOT=self.tmp.name, RA_LOGS_NOW='2026-11-20T10:00:00Z')

    def tearDown(self):
        self.tmp.cleanup()

    def run_tool(self, *args):
        run = subprocess.run([sys.executable, str(TOOL)] + list(args), capture_output=True, env=self.env, timeout=30)
        self.assertEqual(run.returncode, 0, run.stderr.decode())
        return run.stdout.decode()

    def test_parse_old_and_new_format(self):
        module = load()
        new = module.parse_line('2026-11-20T09:30:00.000Z 12:30:00.000+03:00 WARN  net net.state s=1 stage=4 detail="a b"')
        self.assertEqual((new['level'], new['comp'], new['event'], new['fields']['detail']), ('WARN', 'net', 'net.state', 'a b'))
        old = module.parse_line('2026-11-20T09:35:00.000Z old-format-event text')
        self.assertEqual((old['level'], old['event']), ('INFO', 'old-format-event'))
        self.assertIsNone(module.parse_line('garbage'))

    def test_list(self):
        out = self.run_tool('list')
        self.assertIn('Компьютер--WIN-1', out)
        self.assertIn('ошибка: 2026-11-20T09:36:00.000Z launcher.failed', out)

    def test_show_filters(self):
        out = self.run_tool('show', 'win-1', '--hours', '2', '--comp', 'net', '--level', 'WARN')
        self.assertIn('net.e2e', out)
        self.assertNotIn('vpn.click.on', out)
        out = self.run_tool('show', 'Компьютер', '--att', 'on-092000-bb')
        self.assertIn('vpn.on.ok', out)
        self.assertNotIn('on-091000-aa', out)
        self.assertIn('port-closed', self.run_tool('show', 'WIN-1', '--grep', 'port-closed'))

    def test_diag_finds_failures(self):
        out = self.run_tool('diag', 'WIN-1', '--hours', '2')
        self.assertIn('on-091000-aa: отказ', out)
        self.assertIn('conflict=Happ', out)
        self.assertIn('on-092000-bb: включён, сеть не идёт', out)
        self.assertIn('ступень 7: dns-fail', out)
        self.assertIn('ok->fail ступень 4 port-closed', out)
        self.assertIn('простой 60000 мс', out)
        self.assertIn('КОНФЛИКТ Happ', out)
        self.assertIn('vless-direct -> vless-relay', out)
        self.assertIn('код 1', out)
        self.assertIn('пропусков: 1', out)
        self.assertIn('Ступень отказа: 4 port-closed', out)

    def test_latest_failure_wins_across_groups(self):
        directory = Path(self.tmp.name) / 'Компьютер--WIN-1'
        with (directory / 'launcher-2026-11-20.log').open('a') as handle:
            handle.write('2026-11-20T09:40:00Z WARN vpn vpn.on.step att=on-later step=8 result=fail reason=http-fail\n')
        self.assertIn('Ступень отказа: 8 http-fail', self.run_tool('diag', 'WIN-1'))

    def test_fractional_time_sort_and_huge_hours_and_log_directory(self):
        directory = Path(self.tmp.name) / 'Компьютер--WIN-1'
        (directory / 'core-2026-11-20.log').mkdir()
        with (directory / 'launcher-2026-11-20.log').open('a') as handle:
            handle.write('2026-11-20T09:50:00Z INFO net first msg=ok\n')
            handle.write('2026-11-20T09:50:00.100Z INFO net second msg=ok\x1b[31m\x7f\n')
        output = self.run_tool('show', 'WIN-1', '--hours', '1e12')
        self.assertLess(output.index(' first '), output.index(' second '))
        self.assertNotIn('\x1b', output)
        self.assertNotIn('\x7f', output)
        self.run_tool('diag', 'WIN-1', '--hours', '1e12')
        self.run_tool('list')

    def test_last_error_does_not_read_older_files(self):
        directory = Path(self.tmp.name) / 'Компьютер--WIN-1'
        old = directory / 'core-2026-11-19.log'
        old.write_text('2026-11-19T23:59:00Z ERROR core older msg=error\n')
        module = load()
        original = module.events_in_file
        def checked(path, stream):
            self.assertNotEqual(Path(path), old)
            return original(path, stream)
        with mock.patch.object(module, 'events_in_file', side_effect=checked):
            self.assertIn('launcher.failed', module.last_error(str(directory)))


if __name__ == '__main__':
    unittest.main()
