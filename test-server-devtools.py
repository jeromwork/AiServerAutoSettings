#!/usr/bin/env python3
"""Ubuntu-only integration smoke; isolated Chrome profile, never an owner profile."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import urllib.request

assert os.getuid() != 0, "Run as the non-root desktop user"
workspace = Path.home() / "work/devtools-smoke"
assert not workspace.is_symlink()
assert (workspace / ".remoteagents-smoke").read_text().strip() == "devtools-smoke-v1"
with socket.socket() as reserve:
    reserve.bind(("127.0.0.1", 0))
    port = reserve.getsockname()[1]
url = f"http://127.0.0.1:{port}/"
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with tempfile.TemporaryDirectory(prefix="remoteagents-devtools-http-") as temporary:
    with open(Path(temporary) / "php.log", "wb") as logfile:
        server = subprocess.Popen(
            ["/usr/bin/php8.3", "-S", f"127.0.0.1:{port}", "-t", "public", "router.php"],
            cwd=workspace, stdout=logfile, stderr=logfile, start_new_session=True,
        )
        try:
            for attempt in range(100):
                assert server.poll() is None, "PHP server exited"
                try:
                    with opener.open(url + "api.php", timeout=1) as response:
                        data = json.load(response)
                    break
                except OSError:
                    time.sleep(0.1)
            else:
                raise AssertionError("PHP readiness timeout")
            assert data["marker"] == "remoteagents-php-smoke"
            assert data["php"].startswith("8.3.")
            with opener.open(url, timeout=3) as response:
                assert b'type="module"' in response.read()
            listeners = subprocess.check_output(["ss", "-H", "-ltn", f"sport = :{port}"], text=True)
            assert listeners and all(line.split()[3] == f"127.0.0.1:{port}" for line in listeners.splitlines())
            chrome = subprocess.run(
                ["/usr/bin/google-chrome", "--headless=new", "--disable-gpu", "--no-first-run",
                 "--no-default-browser-check", "--no-proxy-server", "--disable-background-networking",
                 "--disable-component-update", "--disable-sync", "--password-store=basic",
                 "--user-data-dir=" + str(Path(temporary) / "new-chrome-profile"),
                 "--dump-dom", "--virtual-time-budget=10000", url],
                capture_output=True, text=True, timeout=45,
            )
            assert chrome.returncode == 0, "Isolated Chrome exit " + str(chrome.returncode)
            assert 'data-smoke="ready"' in chrome.stdout, "Vue did not mark the rendered document ready"
            assert "VUE_PHP_SMOKE_OK" in chrome.stdout, "Vue/PHP rendering marker missing"
            print("HTTP_GET=PASS PHP=" + data["php"])
            print("HTTP_BIND=127.0.0.1-only")
            print("ISOLATED_SERVER_CHROME_VUE_PHP=PASS")
        finally:
            if server.poll() is None:
                os.killpg(server.pid, signal.SIGTERM)
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(server.pid, signal.SIGKILL)
                    server.wait(timeout=5)
            listeners = subprocess.check_output(["ss", "-H", "-ltn", f"sport = :{port}"], text=True)
            assert not listeners.strip(), "Test listener survived cleanup"
            print("TEST_HTTP_CLEANUP=PASS")
