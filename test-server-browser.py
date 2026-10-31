"""Offline tests: no SSH, package installation, account login, or external HTTP."""
import pathlib
import sys
import types
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parent
SHELL = (ROOT / "server-browser-bootstrap.sh").read_text(encoding="utf-8")
BODY = SHELL.split("<<'REMOTEAGENTS_BROWSER_PY'\n", 1)[1].split("\nREMOTEAGENTS_BROWSER_PY\n", 1)[0]
MODULE = {"__name__": "offline_browser", "__file__": "browser.py"}
exec(compile(BODY, "browser.py", "exec"), MODULE)


class BrowserTests(unittest.TestCase):
    def test_origin_and_host_boundary(self):
        allow = MODULE["allowed_origin"]
        self.assertTrue(allow("127.0.0.1:6091", "http://127.0.0.1:6091"))
        self.assertTrue(allow("127.0.0.1:55000", "http://127.0.0.1:55000"))
        for host, origin in [(None, None), ("evil.test:6091", "http://evil.test:6091"),
                             ("127.0.0.1:6091", "https://evil.test"),
                             ("127.0.0.1:6091", None), ("127.0.0.1:6091", "null"),
                             ("127.0.0.1:6091", "http://127.0.0.1:6092"),
                             ("127.0.0.1:65536", "http://127.0.0.1:65536"),
                             ("127.0.0.1:0", "http://127.0.0.1:0"),
                             ("127.0.0.1:6091@evil.test", "http://127.0.0.1:6091@evil.test")]:
            with self.subTest(host=host, origin=origin):
                self.assertFalse(allow(host, origin))

    def test_proxy_policy_is_used(self):
        recorded = {}

        class Handler:
            def do_GET(self): self.success = True
            def validate_connection(self): self.validated = True
            def send_error(self, code, message): self.error = code
            def send_header(self, key, value): self.sent[key] = value
            def end_headers(self): pass

        class Proxy:
            def __init__(self, **kwargs): recorded.update(kwargs)
            def start_server(self): recorded["started"] = True

        fake = types.ModuleType("websockify.websocketproxy")
        fake.ProxyRequestHandler, fake.WebSocketProxy = Handler, Proxy
        with patch.dict(sys.modules, {"websockify": types.ModuleType("websockify"), "websockify.websocketproxy": fake}):
            MODULE["run_proxy"]()
        self.assertEqual(recorded["listen_host"], "127.0.0.1")
        self.assertEqual(recorded["unix_target"], "/run/remoteagents-browser/vnc.sock")
        self.assertTrue(recorded["started"])
        instance = recorded["RequestHandlerClass"]()
        instance.server = types.SimpleNamespace(EClose=ValueError)
        instance.headers = {"Host": "127.0.0.1:50000", "Origin": "http://127.0.0.1:50000"}
        instance.validate_connection()
        self.assertTrue(instance.validated)
        instance.headers["Origin"] = "https://attacker.test"
        with self.assertRaises(ValueError): instance.validate_connection()
        instance.headers["Host"] = "attacker.test:50000"
        instance.do_GET()
        self.assertEqual(instance.error, 403)
        instance.sent = {}
        instance.end_headers()
        self.assertEqual(instance.sent["X-Frame-Options"], "DENY")

    def test_root_desktop_fails_before_any_child(self):
        with patch.object(MODULE["os"], "getuid", return_value=0, create=True), patch.object(MODULE["subprocess"], "Popen") as child:
            with self.assertRaisesRegex(RuntimeError, "non-root"): MODULE["run_desktop"]()
            child.assert_not_called()

    def test_install_and_browser_boundary(self):
        self.assertIn("$VERSION_ID == 22.04 || $VERSION_ID == 24.04", SHELL)
        self.assertIn("-nolisten\", \"tcp", BODY)
        self.assertIn('"-rfbport", "0", "-rfbportv6", "0", "-noipv6"', BODY)
        self.assertIn('"-listen", "127.0.0.1", "-listenv6", "::1"', BODY)
        self.assertIn('"-unixsock", str(socket_path)', BODY)
        self.assertNotIn("--no-sandbox", BODY)
        self.assertNotIn("remote-debugging", BODY)
        self.assertNotIn("auth.json", BODY)
        self.assertNotIn("password-store=basic", BODY)
        self.assertIn("--proto-redir '=https'", SHELL)
        self.assertIn("Restart=on-failure", SHELL)


if __name__ == "__main__": unittest.main()
