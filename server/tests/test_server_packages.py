#!/usr/bin/env python3
import json
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from test_server_apply import Fake, app, config
from test_base_network import Fresh


class PackageTests(unittest.TestCase):
    def test_deleted_packages_are_reinstalled_before_kernel_service_restore(self):
        with tempfile.TemporaryDirectory() as root:
            f = Fresh(root); c = config(); c['serverNetwork'] = {'enabled': True}
            self.assertTrue(f.complete(c)['ok'])
            old_run = f.system.runner
            missing = {'sing-box', 'openvpn', 'curl', 'jq'}
            def runner(args, **kw):
                if args[0] == 'which' and args[-1] in missing:
                    return subprocess.CompletedProcess(args, 1, '', '')
                if args[:2] == ['apt-get', 'install']:
                    missing.clear()
                return old_run(args, **kw)
            f.system.runner = runner
            f.calls.clear()
            self.assertTrue(app.module('server_recovery').reconcile(app, f.system))
            install = next(a for a in f.calls if a[:2] == ['apt-get', 'install'])
            self.assertTrue({'sing-box', 'openvpn', 'curl', 'jq'} <= set(install))
            self.assertFalse(missing)

    def test_packages_without_binaries_are_detected_by_dpkg_status(self):
        with tempfile.TemporaryDirectory() as root:
            f = Fake(root); c = config()
            self.assertTrue(f.complete(c)['ok'])
            original = f.system.runner
            def runner(args, **kw):
                if args[0] == 'dpkg-query' and args[-1] in ('ca-certificates', 'python3-cryptography'):
                    return subprocess.CompletedProcess(args, 1, '', '')
                return original(args, **kw)
            f.system.runner = runner; f.calls.clear()
            self.assertTrue(app.packages.ensure(f.engine(c), True))
            install = next(a for a in f.calls if a[:2] == ['apt-get', 'install'])
            self.assertIn('ca-certificates', install)
            self.assertIn('python3-cryptography', install)
            self.assertIn('Dpkg::Options::=--force-confold', install)

    def test_proxy_environment_is_private_and_egress_probe_remains_direct(self):
        with tempfile.TemporaryDirectory() as root:
            seen = []
            def runner(args, **kw):
                seen.append((args, kw['env']))
                return subprocess.CompletedProcess(args, 0, '', '')
            s = app.System(root, runner)
            s.download_proxy = 'http://login:SECRET_SENTINEL@proxy.invalid:3128'
            s.run(['apt-get', 'update'])
            s.run(['curl', '--noproxy', '*', '--output', '/tmp/key', 'https://vendor.invalid'])
            s.run(['curl', '--noproxy', '*', 'https://ip.invalid'])
            self.assertIn('SECRET_SENTINEL', seen[0][1]['http_proxy'])
            self.assertNotIn('--noproxy', seen[1][0])
            self.assertNotIn('http_proxy', seen[2][1])
            self.assertIn('--noproxy', seen[2][0])
            self.assertNotIn('SECRET_SENTINEL', json.dumps([a for a, env in seen]))


if __name__ == '__main__':
    unittest.main()
