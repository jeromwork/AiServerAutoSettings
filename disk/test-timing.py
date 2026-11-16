#!/usr/bin/env python3
"""Timing injection must work without starting installed services."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('disk_tests', Path(__file__).with_name('test-disk.py'))
disk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(disk)


class TimingTests(unittest.TestCase):
    def test_cron_override_replaces_only_managed_schedule(self):
        with tempfile.TemporaryDirectory() as home, mock.patch.dict(os.environ, {
            'REMOTE_DISK_AUTO_CRON_MINUTES': '3',
        }), disk.server_helpers(home) as ns:
            old = b'5 * * * * echo untouched\n* * * * * bash "$HOME/.local/share/remote-disk/server-disk.sh" bootstrap >/dev/null 2>&1\n'
            written = []

            def run(args, **kwargs):
                if args[-1] == '-l':
                    return disk.subprocess.CompletedProcess(args, 0, stdout=old)
                written.append(kwargs['input'])
                return disk.subprocess.CompletedProcess(args, 0)

            with mock.patch.object(ns['subprocess'], 'run', run):
                ns['ensure_cron']()
            self.assertEqual(written, [b'5 * * * * echo untouched\n' + ns['CRON_LINE'] + b'\n'])

    def test_server_defaults_and_overrides(self):
        with tempfile.TemporaryDirectory() as home, disk.server_helpers(home) as ns:
            self.assertEqual(ns['API_WRITE_TIMEOUT'], 30)
            self.assertEqual(ns['MISSING_AFTER_S'], 30)
            self.assertEqual(ns['CHANNEL_PROBE_INTERVAL'], 60)
        with tempfile.TemporaryDirectory() as home, mock.patch.dict(os.environ, {
            'REMOTE_DISK_API_WRITE_TIMEOUT_S': '.007', 'REMOTE_DISK_MISSING_AFTER_S': '.009',
            'REMOTE_DISK_AUTO_CRON_MINUTES': '3',
            'REMOTE_DISK_CHANNEL_PROBE_INTERVAL_S': '.005',
        }), disk.server_helpers(home) as ns:
            self.assertEqual(ns['API_WRITE_TIMEOUT'], .007)
            self.assertEqual(ns['MISSING_AFTER_S'], .009)
            self.assertEqual(ns['CHANNEL_PROBE_INTERVAL'], .005)
            self.assertTrue(ns['CRON_LINE'].startswith(b'*/3 * * * * '))

    def test_invalid_timing_fails_before_mutations(self):
        for value in ('NaN', 'inf', '-1', '0', 'garbage'):
            with tempfile.TemporaryDirectory() as home, mock.patch.dict(os.environ, {
                'REMOTE_DISK_MISSING_AFTER_S': value,
            }):
                with self.assertRaises(ValueError):
                    with disk.server_helpers(home):
                        self.fail('invalid duration accepted')
                self.assertEqual(list(Path(home).iterdir()), [])


if __name__ == '__main__':
    unittest.main(failfast=True)
