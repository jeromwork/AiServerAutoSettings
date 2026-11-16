#!/usr/bin/env python3
"""Production helpers, fake REST/clock, disposable HOME. No installed engine."""
import contextlib
import importlib.util
import inspect
import io
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock


def module(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), Path(__file__).with_name(name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


disk = module('test-disk')
timing = module('test-timing')


class TransitionTests(unittest.TestCase):
    def test_unavailable_empty_or_replaced_base_resets_absence(self):
        for mode in ('unavailable', 'empty', 'replaced'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp, disk.server_helpers(tmp) as ns:
                root = disk.make_disk(Path(tmp))
                rest = disk.ContractRest([dict(id='Missing', path=str(root / 'Missing'))])
                ns['forget_missing'](rest, rest('config/folders'), root, now=100)
                if mode == 'empty':
                    (root / '.mounted').unlink()
                else:
                    root.rename(Path(tmp) / 'unmounted')
                    if mode == 'replaced':
                        disk.make_disk(Path(tmp))
                ns['forget_missing'](rest, rest('config/folders'), root, now=200)
                self.assertFalse(rest.deletes)
                if mode == 'empty':
                    (root / '.mounted').touch()
                elif mode == 'unavailable':
                    (Path(tmp) / 'unmounted').rename(root)
                ns['forget_missing'](rest, rest('config/folders'), root, now=210)
                self.assertFalse(rest.deletes)

    def test_discovery_shares_idempotently_and_preserves_pause_and_bytes(self):
        with tempfile.TemporaryDirectory() as tmp, disk.server_helpers(tmp) as ns:
            path = Path(tmp) / 'Disk/Project'
            disk.make_project(path)
            (path / 'data.txt').write_text('preserved')
            rest = disk.ContractRest()
            ns['reconcile'](rest, 'SERVER')
            rest.folders['Project']['paused'] = True
            for _ in range(2):
                ns['reconcile'](rest, 'SERVER')
            self.assertEqual(rest.puts, ['Project'])
            self.assertTrue(rest.folders['Project']['paused'])
            self.assertEqual({d['deviceID'] for d in rest.folders['Project']['devices']}, {'SERVER', 'PEER'})
            self.assertEqual((path / 'data.txt').read_text(), 'preserved')

    def test_missing_grace_return_reset_delete_retry_and_never_reoffer(self):
        with tempfile.TemporaryDirectory() as tmp, disk.server_helpers(tmp) as ns:
            root = disk.make_disk(Path(tmp))
            path = Path(tmp) / 'Disk/Project'
            disk.make_project(path)
            rest = disk.ContractRest()
            ns['reconcile'](rest, 'SERVER')
            shutil.rmtree(path)

            def tick(now):
                with contextlib.redirect_stderr(io.StringIO()):
                    return ns['forget_missing'](rest, rest('config/folders'), root, now=now)

            tick(100)
            tick(129.999)
            self.assertFalse(rest.deletes)
            disk.make_project(path)
            tick(130)
            shutil.rmtree(path)
            tick(200)
            tick(229.999)
            self.assertFalse(rest.deletes)
            tick(230)
            self.assertEqual(rest.deletes, ['Project'])
            rest.offers = {'Project': disk.upload_offer('Project')}
            for _ in range(2):
                with contextlib.redirect_stderr(io.StringIO()):
                    ns['reconcile'](rest, 'SERVER')
                self.assertFalse(path.exists())
                self.assertFalse(rest.folders)

    def test_failed_or_lost_put_reuses_reservation_while_other_offers_continue(self):
        for committed in (False, True):
            with self.subTest(committed=committed), tempfile.TemporaryDirectory() as tmp, disk.server_helpers(tmp) as ns:
                disk.make_disk(Path(tmp))
                first, second = disk.upload_id('first'), disk.upload_id('second')
                rest = disk.ContractRest(offers={first: disk.upload_offer('First'), second: disk.upload_offer('Second')})
                fail = True

                def api(route, method='GET', body=None):
                    if fail and method == 'PUT' and route.endswith(first):
                        if committed:
                            rest(route, method, body)
                        raise TimeoutError('lost write')
                    if route.endswith(first) and method == 'GET' and first not in rest.folders:
                        raise OSError('not found')
                    return rest(route, method, body)

                with contextlib.redirect_stderr(io.StringIO()):
                    ns['reconcile'](api, 'SERVER')
                self.assertIn(second, rest.folders)
                fail = False
                ns['reconcile'](api, 'SERVER')
                self.assertEqual(set(rest.folders), {first, second})
                self.assertEqual(sorted(p.name for p in (Path(tmp) / 'Disk').iterdir() if p.is_dir()), ['First', 'Second'])


def suite():
    result = unittest.TestSuite()
    for cls in (timing.TimingTests, disk.ContractTests, TransitionTests,
                disk.ServerHardeningTests, disk.StaleConnectionTests):
        for name in unittest.defaultTestLoader.getTestCaseNames(cls):
            # The two true-engine connection tests and old Stand tests belong to live/all.
            if 'Stand(' not in inspect.getsource(getattr(cls, name)):
                result.addTest(cls(name))
    return result


if __name__ == '__main__':
    with mock.patch.object(disk, 'Stand', side_effect=AssertionError('live fixture in fast suite')):
        outcome = unittest.TextTestRunner(verbosity=1, failfast=True).run(suite())
    raise SystemExit(not outcome.wasSuccessful())
