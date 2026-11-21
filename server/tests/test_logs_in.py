import base64
import gzip
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
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
        self.root = str(Path(self.tmp.name) / 'root')
        Path(self.root).mkdir()
        outside_before = set(Path(self.root).parent.iterdir())
        for device, host in (('../x', 'h'), ('a/b', 'h'), ('..', '..'), ('Ноутбук Ева', 'WIN-2'), ('x' * 200, 'h'), ('Я' * 64, 'Я' * 64)):
            gz, _ = batch([line(1)], device=device, host=host, batch_id='d')
            logs_in.recv(gz, self.root)
        for d in Path(self.root).iterdir():
            self.assertTrue(d.resolve().is_relative_to(Path(self.root).resolve()))
            self.assertTrue(d.is_dir() or d.name == '_receiver.log')
        names = sorted(d.name for d in Path(self.root).iterdir() if d.is_dir())
        self.assertTrue(all('/' not in n and n not in ('.', '..') for n in names), names)
        self.assertIn('Ноутбук_Ева--WIN-2', names)
        self.assertTrue(all(len(n.encode()) <= 64 + 2 + 64 for n in names))
        self.assertEqual(set(Path(self.root).parent.iterdir()), outside_before)

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

    def test_bus_stream_is_stored_by_line_date(self):
        bus_line = '2026-11-20T09:05:00.123Z 12:05:00.123+03:00 INFO  bus       vpn.state      s=1111 seq=1 source=vpn-core state=on'
        gz, _ = batch([bus_line], stream='bus')
        self.assertEqual(logs_in.recv(gz, self.root), 'OK batch=b1 stored=1')
        names = [k for k in self.files() if k.endswith('.log') and not k.endswith('_receiver.log')]
        self.assertEqual(len(names), 1)
        self.assertTrue(names[0].endswith('/bus-2026-11-20.log'), names[0])
        self.assertIn('state=on', self.files()[names[0]].read_text(encoding='utf-8'))

    def test_health_stream_is_stored_by_line_date(self):
        health_line = '2026-11-20T09:05:00.123Z 12:05:00.123+03:00 INFO  health    component.exit s=1111 seq=1 source=supervisor name=sing-box code=1'
        gz, _ = batch([health_line], stream='health')
        self.assertEqual(logs_in.recv(gz, self.root), 'OK batch=b1 stored=1')
        names = [k for k in self.files() if k.endswith('.log') and not k.endswith('_receiver.log')]
        self.assertEqual(len(names), 1)
        self.assertTrue(names[0].endswith('/health-2026-11-20.log'), names[0])
        self.assertIn('code=1', self.files()[names[0]].read_text(encoding='utf-8'))

    def test_mask_linear_time(self):
        for text in ('.' * 8192, '_-' * 4000):
            logs_in.mask(text)
            started = time.perf_counter()
            self.assertEqual(logs_in.mask(text), text)
            self.assertLess(time.perf_counter() - started, .050)

    def test_overlap_uses_original_bytes(self):
        # Обрезка длинной строки, пустые строки, CR и неверный UTF-8 не меняют курсор.
        rows = [b'.' * 12288 + b'\n', b'\n', ('Я' * 5000).encode() + b'\n', b'bad \xff\r\n']
        header = ('RA-LOGS 1 batch=raw device=%s host=h\n' % b64url('d')).encode()
        body = b''.join(rows)
        def raw_batch(body, count):
            return gzip.compress(header + ('@@ launcher fp=aa from=0 to=%d lines=%d\n' % (len(body), count)).encode() + body)
        self.assertIn('stored=4', logs_in.recv(raw_batch(body, 4), self.root))
        self.assertIn('stored=1', logs_in.recv(raw_batch(body + b'new line\n', 5), self.root))
        text = next(v for k, v in self.files().items() if k.endswith('.log')).read_bytes()
        self.assertIn(b'new line\n', text)
        self.assertTrue(all(len(row) <= logs_in.MAX_LINE for row in text.split(b'\n')))

    def test_cursor_shapes_and_controls(self):
        gz, _ = batch([line(1, rest='msg=ok\x1b[31m\x00\x7f')])
        header, _ = logs_in.parse_batch(gz)
        directory = Path(logs_in.device_dir(header, self.root))
        directory.mkdir(mode=0o700)
        for value in ([], {'launcher|aa': 'x'}, {'launcher|aa': None}, {'launcher|aa': {}}):
            (directory / '.cursors.json').write_text(json.dumps(value))
            self.assertIn('stored=1', logs_in.recv(gz, self.root))
        text = next(directory.glob('*.log')).read_text()
        self.assertNotRegex(text, r'[\x00-\x08\x0b-\x1f\x7f]')

    def test_only_complete_segment_headers_and_bounded_offsets(self):
        for text in ('@@ launcher fp=aa from=0 to=999999999 lines=1', '@@ anything'):
            gz, _ = batch([text, line(2, 'new')])
            self.assertIn('stored=2', logs_in.recv(gz, self.root))
            # Вложенная строка заголовка осталась данными, курсор не отравлен.
            _, segments = logs_in.parse_batch(gz)
            self.assertEqual(len(segments), 1)
            (Path(logs_in.device_dir(logs_in.parse_batch(gz)[0], self.root)) / '.cursors.json').unlink()
        gz, _ = batch([line(1)])
        raw = gzip.decompress(gz).replace(b'from=0 to=', b'from=999999999999 to=')
        self.assertEqual(logs_in.recv(gzip.compress(raw), self.root), 'OK batch=b1 stored=0')
        self.assertIn('bad-segment', (Path(self.root) / '_receiver.log').read_text())

    def test_bad_segment_does_not_block_good_segment(self):
        good, good_end = batch([line(2, 'good')], stream='transport', fp='bb')
        good_segment = gzip.decompress(good).split(b'\n', 1)[1]
        bad, bad_end = batch([line(1, 'bad', rest='password=never-store-this')])
        original = gzip.decompress(bad)
        # Ошибка длины в обе стороны, неверное число строк и недопустимые смещения.
        mutations = (
            (b'to=%d' % bad_end, b'to=%d' % (bad_end + 1), bad_end + 1),
            (b'to=%d' % bad_end, b'to=%d' % (bad_end - 1), bad_end - 1),
            (b'lines=1', b'lines=2', bad_end),
            (b'lines=1', b'lines=0', bad_end),
            (b'lines=1', b'lines=999999999', bad_end),
            (b'from=0', b'from=999999999', bad_end),
            (b'to=%d' % bad_end, b'to=999999999', 999999999),
        )
        for old, new, skipped_to in mutations:
            with self.subTest(mutation=new), tempfile.TemporaryDirectory() as root:
                mixed = gzip.compress(original.replace(old, new, 1) + good_segment)
                self.assertEqual(logs_in.recv(mixed, root), 'OK batch=b1 stored=1')
                header, segments = logs_in.parse_batch(mixed)
                self.assertEqual(len(segments), 2)
                directory = Path(logs_in.device_dir(header, root))
                self.assertFalse(list(directory.glob('launcher-*.log')))
                self.assertIn(' good ', next(directory.glob('transport-*.log')).read_text())
                cursors = json.loads((directory / '.cursors.json').read_text())
                self.assertEqual(cursors['launcher|aa'], skipped_to)
                self.assertEqual(cursors['transport|bb'], good_end)
                receiver_log = (Path(root) / '_receiver.log').read_text()
                self.assertIn('bad-segment stream=launcher fp=aa', receiver_log)
                self.assertNotIn('never-store-this', receiver_log)
                self.assertEqual(logs_in.recv(mixed, root), 'OK batch=b1 stored=0')

    def test_no_symlinks_followed(self):
        gz, _ = batch([line(1)])
        header, _ = logs_in.parse_batch(gz)
        directory = Path(logs_in.device_dir(header, self.root))
        with tempfile.TemporaryDirectory() as outside:
            target = Path(outside)
            directory.symlink_to(target, target_is_directory=True)
            with self.assertRaises(OSError):
                logs_in.recv(gz, self.root)
            self.assertEqual(list(target.iterdir()), [])
            directory.unlink()
            directory.mkdir()
            for name in ('.lock', '.cursors.json', '.cursors.json.tmp', 'launcher-2026-11-20.log'):
                victim = target / 'victim'
                victim.write_text('untouched')
                link = directory / name
                link.unlink(missing_ok=True)
                link.symlink_to(victim)
                if name == '.cursors.json':
                    # Чтение ссылки игнорируется как повреждённый курсор; replace заменяет саму ссылку.
                    logs_in.recv(gz, self.root)
                else:
                    (directory / '.cursors.json').unlink(missing_ok=True)
                    with self.assertRaises(OSError):
                        logs_in.recv(gz, self.root)
                self.assertEqual(victim.read_text(), 'untouched')
                link.unlink(missing_ok=True)

    def test_zlib_errors_are_bad_gzip(self):
        with mock.patch.object(logs_in.gzip.GzipFile, 'read', side_effect=logs_in.zlib.error('bad')):
            with self.assertRaises(logs_in.ReceiveError) as caught:
                logs_in.parse_batch(gzip.compress(b'x'))
        self.assertEqual(caught.exception.code, 'bad-gzip')

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
        for path in Path(self.root).rglob('*'):
            self.assertEqual(path.stat().st_mode & 0o077, 0, str(path))
        bad = subprocess.run([sys.executable, '-c', 'import base64;exec(base64.b64decode("%s"))' % code, 'recv'], input=b'junk', capture_output=True, env=env, timeout=30)
        self.assertEqual(bad.returncode, 2)
        self.assertTrue(bad.stdout.decode().startswith('ERR bad-gzip'))


if __name__ == '__main__':
    unittest.main()
