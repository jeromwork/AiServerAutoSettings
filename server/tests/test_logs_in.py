import base64
import gzip
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'server'))
import logs_in  # noqa: E402

MASKS = ROOT / 'app/launcher/tests/fixtures/logging/mask-cases.json'


def b64url(text):
    return base64.urlsafe_b64encode(text.encode()).decode().rstrip('=')


def batch(lines, device='Компьютер', host='WIN-1', stream='launcher', fp='aa', start=0, batch_id='b1', extra=''):
    body = ''.join(l + '\n' for l in lines)
    end = start + len(body.encode())
    text = 'RA-LOGS 1 batch=%s device=%s host=%s ver=1 sent=2026-11-20T09:00:00Z\n@@ %s fp=%s from=%d to=%d lines=%d\n%s%s' % (
        batch_id, b64url(device), host, stream, fp, start, end, len(lines), body, extra)
    return gzip.compress(text.encode()), end


def line(minute, event='x', level='INFO', rest=''):
    return '2026-11-20T09:%02d:00.000Z 12:%02d:00.000+03:00 %-5s vpn       %-14s s=1111 %s' % (minute, minute, level, event, rest)


class LogsIn(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def files(self):
        out = {}
        for d in Path(self.root).iterdir():
            if d.is_dir():
                for f in d.iterdir():
                    out[d.name + '/' + f.name] = f
        return out

    def test_stores_batch_and_repeat_is_ignored(self):
        gz, _ = batch([line(1), line(2, 'y')])
        self.assertEqual(logs_in.recv(gz, self.root), 'OK batch=b1 stored=2')
        self.assertEqual(logs_in.recv(gz, self.root), 'OK batch=b1 stored=0')
        name = [n for n in self.files() if n.endswith('launcher-2026-11-20.log')]
        self.assertEqual(len(name), 1)
        self.assertEqual(len(self.files()[name[0]].read_text(encoding='utf-8').splitlines()), 2)
        self.assertTrue(name[0].startswith('Компьютер--WIN-1/'))
        self.assertIn('stored=2', (Path(self.root) / '_receiver.log').read_text())

    def test_partial_overlap_keeps_only_new_lines(self):
        first, end = batch([line(1), line(2)])
        logs_in.recv(first, self.root)
        second, _ = batch([line(1), line(2), line(3, 'new')], batch_id='b2')
        self.assertEqual(logs_in.recv(second, self.root), 'OK batch=b2 stored=1')
        text = next(v for k, v in self.files().items() if k.endswith('.log')).read_text(encoding='utf-8')
        self.assertEqual(text.count('\n'), 3)
        self.assertIn(' new ', text)

    def test_dangerous_device_names(self):
        for device, host in (('../x', 'h'), ('a/b', 'h'), ('..', '..'), ('Ноутбук Ева', 'WIN-2'), ('x' * 200, 'h')):
            gz, _ = batch([line(1)], device=device, host=host, batch_id='d')
            logs_in.recv(gz, self.root)
        for d in Path(self.root).iterdir():
            self.assertEqual(d.parent, Path(self.root))
            self.assertTrue(d.is_dir() or d.name == '_receiver.log')
        names = sorted(d.name for d in Path(self.root).iterdir() if d.is_dir())
        self.assertTrue(all('/' not in n and n not in ('.', '..') for n in names), names)
        self.assertIn('Ноутбук_Ева--WIN-2', names)
        self.assertTrue(all(len(n) <= 64 + 2 + 64 for n in names))

    def test_too_big_and_bad_input(self):
        big = gzip.compress(b'RA-LOGS 1 batch=b device=%s host=h\n@@ launcher fp=aa from=0 to=1 lines=1\n' % b64url('d').encode() + b'x' * (9 * 1024 * 1024))
        with self.assertRaises(logs_in.ReceiveError) as caught:
            logs_in.recv(big, self.root)
        self.assertEqual(caught.exception.code, 'too-big')
        for bad in (b'not gzip', gzip.compress(b'HELLO 2\n')):
            with self.assertRaises(logs_in.ReceiveError):
                logs_in.recv(bad, self.root)

    def test_mask_cases_and_receiver_masks_again(self):
        for case in json.loads(MASKS.read_text(encoding='utf-8')):
            self.assertEqual(logs_in.mask(case['in']), case['out'], case['in'])
        gz, _ = batch([line(1, 'x', rest='token=abc123 msg=ok')])
        logs_in.recv(gz, self.root)
        text = next(v for k, v in self.files().items() if k.endswith('.log')).read_text(encoding='utf-8')
        self.assertNotIn('abc123', text)

    def test_unknown_stream_and_long_line(self):
        gz, _ = batch(['2026-11-20T09:01:00.000Z ' + 'y' * 20000], stream='../evil')
        logs_in.recv(gz, self.root)
        names = [k for k in self.files() if k.endswith('.log')]
        self.assertEqual(len(names), 1)
        self.assertIn('other-2026-11-20.log', names[0])
        self.assertLessEqual(len(self.files()[names[0]].read_text().splitlines()[0]), logs_in.MAX_LINE + 20)

    def test_prune_by_age_and_size(self):
        d = Path(self.root) / 'dev--h'
        d.mkdir()
        old = d / 'launcher-2026-01-01.log'
        old.write_text('x' * 10)
        os.utime(old, (time.time() - 40 * 86400,) * 2)
        for i in range(3):
            f = d / ('core-2026-11-0%d.log' % (i + 1))
            f.write_text('y' * 1000)
            os.utime(f, (time.time() - (3 - i) * 3600,) * 2)
        logs_in.prune(str(d), max_days=30, max_bytes=2500)
        left = sorted(p.name for p in d.iterdir())
        self.assertNotIn(old.name, left)
        self.assertEqual(left, ['core-2026-11-02.log', 'core-2026-11-03.log'])

    def test_production_invocation(self):
        gz, _ = batch([line(1), line(2)], batch_id='prod1')
        code = base64.b64encode((ROOT / 'server/logs_in.py').read_bytes()).decode()
        env = dict(os.environ, RA_LOGS_IN_ROOT=self.root)
        run = subprocess.run([sys.executable, '-c', 'import base64;exec(base64.b64decode("%s"))' % code, 'recv'], input=gz, capture_output=True, env=env, timeout=30)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(run.stdout.decode().strip(), 'OK batch=prod1 stored=2')
        bad = subprocess.run([sys.executable, '-c', 'import base64;exec(base64.b64decode("%s"))' % code, 'recv'], input=b'junk', capture_output=True, env=env, timeout=30)
        self.assertEqual(bad.returncode, 2)
        self.assertTrue(bad.stdout.decode().startswith('ERR bad-gzip'))


if __name__ == '__main__':
    unittest.main()
