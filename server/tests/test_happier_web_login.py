"""Official signed UI in a real browser, with all external APIs intercepted by CDP."""
import os
import signal
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_happier_web import FIXTURE, SOURCE, running
import happier_web as web
import happier_web_release as release
from resource_guard import wait_for_memory


class NativeLoginTests(unittest.TestCase):
    def test_chrome_official_ui_native_login(self):
        self.check_native_login()

    def test_chrome_official_ui_native_login_slow_bundles(self):
        self.check_native_login(js_delay_ms=25000)

    def check_native_login(self, js_delay_ms=0):
        self.assertTrue(Path('/usr/bin/google-chrome').is_file(), 'Chrome is required')
        self.assertTrue(wait_for_memory(attempts=0), 'not enough memory for required real-UI check')
        with tempfile.TemporaryDirectory(prefix='ra-native-login-') as tmp:
            root = Path(tmp)
            name = 'happier-ui-web-v0.2.21-web-any.tar.gz'
            mirror = Path(os.environ.get('REMOTEAGENTS_HAPPIER_WEB_RELEASE_DIR', '/tmp/happier-uiweb-research'))
            archive = mirror / name
            if not archive.is_file():
                archive = root / name
                release.download('https://github.com/happier-dev/happier/releases/download/ui-web-v0.2.21/' + name,
                                 archive, 512 * 1024 * 1024)
            checks = FIXTURE / 'checksums-happier-ui-web-v0.2.21.txt'
            base = root / 'service'; base.mkdir()
            release.install(base, 'ui-web-v0.2.21', archive, checks, Path(str(checks) + '.minisig'))
            with running(web.make_server(base, 0)) as origin:
                process = subprocess.Popen(['nice', '-n', '10', 'node', str(SOURCE / 'tests/happier_web_login.cjs'),
                                            origin, str(root / 'chrome')], stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, text=True, start_new_session=True,
                                           env=dict(os.environ, HAPPIER_TEST_JS_DELAY_MS=str(js_delay_ms)))
                try:
                    stdout, stderr = process.communicate(timeout=100 + js_delay_ms / 1000)
                    result = subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
                finally:
                    # Only our Node/Chrome group, including helpers on timeout.
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS: official ui-web', result.stdout)
            if js_delay_ms:
                self.assertIn(f'PASS: UI script delay {js_delay_ms} ms', result.stdout)
            print(result.stdout.strip())


if __name__ == '__main__':
    unittest.main()
