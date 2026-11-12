#!/usr/bin/python3
"""Local HTTPS integration tests; all listeners use 127.0.0.1:18xxx."""

import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import queue
import re
import runpy
import secrets
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


BASE = Path(__file__).resolve().parent
TOKEN = "123456789:Test_Secret-TokenABC"
ACCESS_KEY = secrets.token_urlsafe(32)
EXTRA_KEY = secrets.token_urlsafe(32)
UPSTREAM_PATH = f"/bot{TOKEN}/getMe"
PATH = f"/{ACCESS_KEY}{UPSTREAM_PATH}"
QUERY_SECRET = "HiddenQuery-987654"
HEADER_SECRET = "HiddenHeader-123456"
BODY_SECRET = "HiddenBody-456789"
REPLY = b'{"ok":false,"description":"test upstream"}'
MAX_BODY = 52 * 1024 * 1024


def free_port():
    for port in range(18000, 19000):
        with socket.socket() as sock:
            try:
                sock.bind(("127.0.0.1", port))
            except OSError:
                continue
            return port
    raise RuntimeError("No free test port in 18xxx")


class FakeUpstream(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # Expected when the gateway aborts an incomplete/oversized upload.
        pass


class UpstreamHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def respond(self):
        method = self.path.partition("?")[0].rsplit("/", 1)[-1]
        digest = hashlib.sha256()
        total = 0
        small_body = bytearray()

        def consume(size):
            nonlocal total
            while size:
                data = self.rfile.read(min(size, 65536))
                if not data:
                    raise ConnectionError()
                digest.update(data)
                total += len(data)
                if method == "streamupload":
                    self.server.upload_progress.set()
                if total <= 4096:
                    small_body.extend(data)
                size -= len(data)

        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            while True:
                line = self.rfile.readline()
                size = int(line.strip().split(b";", 1)[0], 16)
                if not size:
                    while self.rfile.readline() != b"\r\n":
                        pass
                    break
                consume(size)
                if self.rfile.read(2) != b"\r\n":
                    raise ValueError()
        else:
            consume(int(self.headers.get("Content-Length", 0)))
        self.server.records.put({
            "method": self.command,
            "path": self.path,
            "headers": self.headers,
            "length": total,
            "sha256": digest.hexdigest(),
            "body": bytes(small_body) if total <= 4096 else None,
        })
        if method == "breakupstream":
            self.close_connection = True
            return
        if method == "slow":
            time.sleep(3)
        if method == "streamresponse":
            self.send_response(200)
            self.send_header("Content-Length", str(2 * 65536))
            self.end_headers()
            self.wfile.write(b"a" * 65536)
            self.wfile.flush()
            self.server.response_continue.wait(3)
            self.wfile.write(b"b" * 65536)
            return
        self.send_response(401, "Fake Unauthorized")
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Upstream", "preserved")
        self.send_header("X-Repeated", "one")
        self.send_header("X-Repeated", "two")
        self.send_header("Proxy-Authenticate", "must disappear")
        self.send_header("Connection", "X-Upstream-Hop")
        self.send_header("X-Upstream-Hop", "must disappear")
        if method == "chunkresponse":
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for data in (REPLY[:10], REPLY[10:]):
                self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
            self.wfile.write(b"0\r\nX-Trailer: ignored\r\n\r\n")
        elif method == "nolength":
            self.send_header("Connection", "close")
            self.close_connection = True
            self.end_headers()
            self.wfile.write(REPLY)
        else:
            self.send_header("Content-Length", str(len(REPLY)))
            self.end_headers()
            self.wfile.write(REPLY)


class GatewayProcess:
    def __init__(self, suite, *, allow=None, overrides=None, constants=None):
        self.port = free_port()
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("TG_GW_")}
        env.update({
            "HOME": suite.temp.name,
            "TG_GW_PORT": str(self.port),
            "TG_GW_CERT": str(suite.cert),
            "TG_GW_KEY": str(suite.key),
            "TG_GW_KEYS": str(suite.keys),
            "TG_GW_UPSTREAM_HOST": "127.0.0.1",
            "TG_GW_UPSTREAM_PORT": str(suite.upstream.server_port),
            "TG_GW_UPSTREAM_CAFILE": str(suite.cert),
            # A working direct connection proves these are not consulted.
            "HTTPS_PROXY": "http://127.0.0.1:1",
            "HTTP_PROXY": "http://127.0.0.1:1",
            "ALL_PROXY": "http://127.0.0.1:1",
            "https_proxy": "http://127.0.0.1:1",
            "http_proxy": "http://127.0.0.1:1",
            "all_proxy": "http://127.0.0.1:1",
            "NO_PROXY": "", "no_proxy": "",
        })
        if allow is not None:
            env["TG_GW_ALLOW"] = allow
        env.update(overrides or {})
        # Production binds all interfaces. The test-only function argument binds
        # loopback without adding any production environment configuration.
        runner = (
            "import runpy,sys,json; "
            "m=runpy.run_path(sys.argv[1]); "
            "m['main'].__globals__.update(json.loads(sys.argv[2])); "
            "m['main']('127.0.0.1')"
        )
        self.process = subprocess.Popen(
            ["/usr/bin/python3", "-I", "-u", "-c", runner,
             str(BASE / "gateway.py"), json.dumps(constants or {})],
            cwd=BASE, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.output = None
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                self.stop()
                raise RuntimeError("Gateway exited during startup")
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.1):
                    return
            except OSError:
                time.sleep(0.02)
        self.stop()
        raise RuntimeError("Gateway startup timeout")

    def stop(self):
        if self.output is None:
            self.process.terminate()
            try:
                self.output = self.process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.output = self.process.communicate()
                raise AssertionError("Gateway did not stop on SIGTERM")
        return self.output


class GatewayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix=".test-gateway-", dir=BASE)
        cls.addClassCleanup(cls.temp.cleanup)
        environment = patch.dict(os.environ, HOME=cls.temp.name)
        environment.start()
        cls.addClassCleanup(environment.stop)
        cls.cert = Path(cls.temp.name) / "cert.pem"
        cls.key = Path(cls.temp.name) / "key.pem"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "ec",
            "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-days", "1",
            "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
            "-keyout", str(cls.key), "-out", str(cls.cert),
        ], check=True, env=dict(os.environ, HOME=cls.temp.name), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        cls.key.chmod(0o600)
        cls.context = ssl.create_default_context(cafile=str(cls.cert))
        cls.upstream = FakeUpstream(("127.0.0.1", free_port()), UpstreamHandler)
        cls.addClassCleanup(cls.upstream.server_close)
        cls.upstream.records = queue.Queue()
        cls.upstream.upload_progress = threading.Event()
        cls.upstream.response_continue = threading.Event()
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cls.cert, cls.key)
        cls.upstream.socket = tls.wrap_socket(cls.upstream.socket, server_side=True)
        cls.upstream_thread = threading.Thread(target=cls.upstream.serve_forever, daemon=True)
        cls.upstream_thread.start()
        cls.addClassCleanup(cls.upstream.shutdown)

    def setUp(self):
        self.upstream.upload_progress.clear()
        self.upstream.response_continue.clear()
        while not self.upstream.records.empty():
            self.upstream.records.get_nowait()
        self.state_temp = tempfile.TemporaryDirectory(dir=self.temp.name)
        self.addCleanup(self.state_temp.cleanup)
        self.keys = Path(self.state_temp.name) / "state/keys.json"
        self.extra_secrets = []
        self.write_keys({"test-client": ACCESS_KEY})
        self.gateway = self.start_gateway()

    def write_keys(self, clients):
        self.keys.parent.mkdir(mode=0o700, exist_ok=True)
        data = {"version": 1, "keys": {
            name: {"sha256": hashlib.sha256(key.encode()).hexdigest(),
                   "created": "2026-11-12T00:00:00+00:00"}
            for name, key in clients.items()
        }}
        temporary = self.keys.with_suffix(".tmp")
        temporary.write_text(json.dumps(data))
        temporary.chmod(0o600)
        os.replace(temporary, self.keys)

    def start_gateway(self, **kwargs):
        gateway = GatewayProcess(self, **kwargs)
        self.addCleanup(self.check_gateway, gateway)
        return gateway

    def check_gateway(self, gateway):
        stdout, stderr = gateway.stop()
        self.assertEqual(gateway.process.returncode, 0)
        all_output = (stdout + stderr).decode("utf-8", "replace")
        for secret in (TOKEN, ACCESS_KEY, EXTRA_KEY, QUERY_SECRET, HEADER_SECRET,
                       BODY_SECRET, *self.extra_secrets):
            self.assertNotIn(secret, all_output)
        self.assertNotRegex(all_output, r"bot\d+:")
        for line in stdout.decode().splitlines():
            self.assertRegex(line, r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z (?:[a-z0-9][a-z0-9._-]{0,39}|-) (?:[A-Za-z]+|-) \d{3} \d+ms$")
        for line in stderr.decode().splitlines():
            self.assertRegex(line, r"^(?:keys: invalid|[A-Za-z_][A-Za-z0-9_]*(:[A-Z0-9_]{1,64})?)$")

    def connection(self, gateway=None):
        conn = http.client.HTTPSConnection(
            "127.0.0.1", (gateway or self.gateway).port,
            context=self.context, timeout=8,
        )
        self.addCleanup(conn.close)
        return conn

    def raw_socket(self, gateway=None):
        raw = socket.create_connection(("127.0.0.1", (gateway or self.gateway).port), 5)
        tls = self.context.wrap_socket(raw, server_hostname="127.0.0.1")
        self.addCleanup(tls.close)
        return tls

    def record(self):
        return self.upstream.records.get(timeout=2)

    def request(self, method, path, body=None, headers=None, gateway=None):
        conn = self.connection(gateway)
        conn.request(method, path, body=body, headers=headers or {})
        response = conn.getresponse()
        data = response.read()
        conn.close()
        return response, data

    def wait_status(self, path, status):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            response, _ = self.request("GET", path)
            if response.status == status:
                return
            time.sleep(0.05)
        self.fail(f"Key reload did not produce HTTP {status}")

    def test_key_rejection_and_old_format(self):
        for method in ("GET", "POST", "PUT"):
            for path in (UPSTREAM_PATH, f"/{EXTRA_KEY}{UPSTREAM_PATH}",
                         f"/{ACCESS_KEY[:-1]}{UPSTREAM_PATH}",
                         f"/{EXTRA_KEY}/health", f"/{ACCESS_KEY}/unknown",
                         f"//{ACCESS_KEY}{UPSTREAM_PATH}"):
                with self.subTest(method=method):
                    response, data = self.request(method, path)
                    self.assertEqual((response.status, data), (404, b"404\n"))
        self.assertTrue(self.upstream.records.empty())

    def test_keys_reload_add_revoke_invalid_and_missing(self):
        path = f"/{ACCESS_KEY}/health"
        extra_path = f"/{EXTRA_KEY}/health"
        persistent = self.connection()
        persistent.request("GET", path)
        response = persistent.getresponse()
        self.assertEqual((response.status, response.read()), (200, b"ok"))
        self.assertEqual(self.request("GET", path)[0].status, 200)
        self.assertEqual(self.request("GET", extra_path)[0].status, 404)
        self.write_keys({"test-client": ACCESS_KEY, "new-client": EXTRA_KEY})
        self.wait_status(extra_path, 200)
        self.write_keys({"new-client": EXTRA_KEY})
        self.wait_status(path, 404)
        persistent.request("GET", path)
        response = persistent.getresponse()
        self.assertEqual((response.status, response.read()), (404, b"404\n"))
        self.assertEqual(self.request("GET", extra_path)[0].status, 200)
        # Parser diagnostics must not expose even malicious file contents.
        self.keys.write_text(f'{{"secret":"{ACCESS_KEY} bot{TOKEN}", invalid')
        time.sleep(2.05)
        self.assertEqual(self.request("GET", extra_path)[0].status, 200)
        self.assertEqual(self.request("GET", path)[0].status, 404)
        self.keys.unlink()
        self.wait_status(extra_path, 404)
        self.write_keys({"test-client": ACCESS_KEY})
        self.wait_status(path, 200)
        self.assertTrue(self.upstream.records.empty())
        stdout, stderr = self.gateway.stop()
        self.assertIn(b" new-client health 200 ", stdout)
        self.assertIn(b"keys: invalid\n", stderr)

    def test_missing_keys_at_start(self):
        self.keys.unlink()
        gateway = self.start_gateway()
        self.assertEqual(self.request("GET", PATH, gateway=gateway)[0].status, 404)
        self.assertEqual(self.request("GET", "/health", gateway=gateway)[0].status, 200)

    def test_file_download_and_methods(self):
        target = f"/file/bot{TOKEN}/documents/input_file-12.pdf?x=%2B%2f&x="
        response, data = self.request("GET", f"/{ACCESS_KEY}{target}")
        self.assertEqual((response.status, data), (401, REPLY))
        self.assertEqual(self.record()["path"], target)
        for method in ("POST", "HEAD", "PUT"):
            response, _ = self.request(method, f"/{ACCESS_KEY}{target}")
            self.assertEqual(response.status, 405)
            self.assertEqual(response.getheader("Allow"), "GET")
        for fp in ("..", ".", "photos/../secret", "./secret", "photos/.",
                   "photos//secret", "photos/", "%2e%2e/secret", "x%2fy"):
            response, _ = self.request("GET", f"/{ACCESS_KEY}/file/bot{TOKEN}/{fp}")
            self.assertEqual(response.status, 404)
        self.assertTrue(self.upstream.records.empty())

    def test_keyed_health_and_client_log(self):
        for method, status in (("GET", 200), ("POST", 405), ("DELETE", 405)):
            response, data = self.request(method, f"/{ACCESS_KEY}/health?x={QUERY_SECRET}")
            self.assertEqual(response.status, status)
            if status == 200:
                self.assertEqual(data, b"ok")
            else:
                self.assertEqual(response.getheader("Allow"), "GET")
        stdout, _ = self.gateway.stop()
        self.assertIn(b" test-client health 200 ", stdout)
        self.assertTrue(self.upstream.records.empty())

    def test_unkeyed_health_checks_real_peer(self):
        # Exercise the real HTTP handler with a synthetic peer, without binding
        # any non-loopback address or relying on forwarding headers.
        module = runpy.run_path(str(BASE / "gateway.py"))

        class RequestSocket:
            def __init__(self, headers):
                self.input = io.BytesIO(
                    b"GET /health HTTP/1.1\r\nHost: test\r\nConnection: close\r\n"
                    + headers + b"\r\n")
                self.output = bytearray()

            def makefile(self, *args):
                return self.input

            def sendall(self, data):
                self.output.extend(data)

        for ip, headers, expected in (
            ("203.0.113.7", b"X-Forwarded-For: 127.0.0.1\r\n", 404),
            ("127.0.0.1", b"X-Forwarded-For: 203.0.113.7\r\n", 200),
        ):
            sock = RequestSocket(headers)
            with redirect_stdout(io.StringIO()):
                module["GatewayHandler"](sock, (ip, 18001), object())
            self.assertTrue(sock.output.startswith(f"HTTP/1.1 {expected} ".encode()))

    def test_health_invalid_path_and_methods(self):
        for method, path, status in (
            ("GET", "/health", 200), ("GET", "/invalid", 404),
            ("PUT", PATH, 405), ("PATCH", PATH, 405),
            ("POST", "/health", 404),
            ("GET", f"//bot{TOKEN}/getMe", 404),
            ("GET", f"/{ACCESS_KEY}/bot{TOKEN}/getMe/extra", 404),
            ("GET", f"/{ACCESS_KEY}/bot{TOKEN}/getMe123", 404),
        ):
            with self.subTest(method=method, expected=status):
                response, data = self.request(method, path)
                self.assertEqual(response.status, status)
                if status == 200:
                    self.assertEqual(data, b"ok")
                if status == 405:
                    self.assertEqual(response.getheader("Allow"), "GET, POST")
        self.assertTrue(self.upstream.records.empty())

    def test_get_query_headers_status_and_body(self):
        target = PATH + f"?offset=1&x=%2B%2f&x=&secret={QUERY_SECRET}"
        response, data = self.request("GET", target, headers={
            "Host": "untrusted.example", "Content-Type": "application/json",
            "X-Preserved": HEADER_SECRET,
            "Connection": "keep-alive, X-Remove", "X-Remove": "remove me",
            "Keep-Alive": "timeout=1", "TE": "trailers", "Trailer": "X-Trailer",
            "Upgrade": "h2c", "Proxy-Authorization": HEADER_SECRET,
        })
        self.assertEqual((response.status, response.reason, data),
                         (401, "Fake Unauthorized", REPLY))
        self.assertEqual(response.getheader("X-Upstream"), "preserved")
        self.assertEqual(response.headers.get_all("X-Repeated"), ["one", "two"])
        self.assertEqual(response.getheader("Content-Type"), "application/json")
        self.assertIsNone(response.getheader("X-Upstream-Hop"))
        self.assertIsNone(response.getheader("Proxy-Authenticate"))
        record = self.record()
        self.assertEqual(record["path"], target.removeprefix(f"/{ACCESS_KEY}"))
        self.assertEqual(record["headers"]["Host"], "127.0.0.1")
        self.assertEqual(record["headers"]["X-Preserved"], HEADER_SECRET)
        self.assertEqual(record["headers"]["Content-Type"], "application/json")
        for header in ("Connection", "X-Remove", "Keep-Alive", "TE", "Trailer",
                       "Upgrade", "Proxy-Authorization"):
            self.assertIsNone(record["headers"].get(header))

    def test_post_json(self):
        body = json.dumps({"chat_id": 123, "text": BODY_SECRET}).encode()
        response, data = self.request("POST", PATH + "?mode=json", body,
                                      {"Content-Type": "application/json"})
        self.assertEqual((response.status, data), (401, REPLY))
        record = self.record()
        self.assertEqual((record["method"], record["path"], record["body"]),
                         ("POST", UPSTREAM_PATH + "?mode=json", body))
        self.assertEqual(record["headers"]["Content-Type"], "application/json")

    def test_multipart_five_megabytes_streamed(self):
        prefix = b'--test-boundary\r\nContent-Disposition: form-data; name="document"; filename="file.bin"\r\n\r\n'
        suffix = b"\r\n--test-boundary--\r\n"
        block = bytes(range(256)) * 256
        digest = hashlib.sha256()

        def body():
            for data in (prefix,):
                digest.update(data)
                yield data
            for _ in range(80):  # 5 MiB, no complete body allocation.
                digest.update(block)
                yield block
            digest.update(suffix)
            yield suffix

        length = len(prefix) + 80 * len(block) + len(suffix)
        response, data = self.request("POST", f"/{ACCESS_KEY}/bot{TOKEN}/sendDocument", body(), {
            "Content-Type": "multipart/form-data; boundary=test-boundary",
            "Content-Length": str(length),
        })
        self.assertEqual((response.status, data), (401, REPLY))
        record = self.record()
        self.assertEqual((record["length"], record["sha256"]), (length, digest.hexdigest()))
        self.assertEqual(record["headers"]["Content-Type"],
                         "multipart/form-data; boundary=test-boundary")

    def test_chunked_upload(self):
        chunks = [b"hello", b"\x00\xff" * 40000, BODY_SECRET.encode()]
        conn = self.connection()
        conn.request("POST", PATH, body=iter(chunks), encode_chunked=True,
                     headers={"Content-Type": "application/octet-stream"})
        response = conn.getresponse()
        self.assertEqual((response.status, response.read()), (401, REPLY))
        record = self.record()
        self.assertEqual(record["sha256"], hashlib.sha256(b"".join(chunks)).hexdigest())
        self.assertEqual(record["headers"]["Transfer-Encoding"], "chunked")
        self.assertIsNone(record["headers"].get("Content-Length"))

    def test_upload_reaches_upstream_before_client_finishes(self):
        conn = self.connection()
        conn.putrequest("POST", f"/{ACCESS_KEY}/bot{TOKEN}/streamupload")
        conn.putheader("Content-Length", str(2 * 65536))
        conn.endheaders()
        conn.send(b"a" * 65536)
        self.assertTrue(self.upstream.upload_progress.wait(2),
                        "First block must arrive before the second is sent")
        conn.send(b"b" * 65536)
        response = conn.getresponse()
        self.assertEqual((response.status, response.read()), (401, REPLY))
        self.assertEqual(self.record()["length"], 2 * 65536)

    def test_response_reaches_client_before_upstream_finishes(self):
        conn = self.connection()
        conn.request("GET", f"/{ACCESS_KEY}/bot{TOKEN}/streamresponse")
        response = conn.getresponse()
        try:
            started = time.monotonic()
            self.assertEqual(response.read(65536), b"a" * 65536)
            self.assertLess(time.monotonic() - started, 2)
        finally:
            self.upstream.response_continue.set()
        self.assertEqual(response.read(), b"b" * 65536)

    def test_chunk_extensions_trailers_and_pipeline(self):
        sock = self.raw_socket()
        sock.sendall(f"POST {PATH} HTTP/1.1\r\nHost: client\r\nTransfer-Encoding: chunked\r\n\r\n".encode()
                     + b"5;foo=bar\r\nhello\r\n0\r\nX-Trailer: ignored\r\n\r\n")
        response = http.client.HTTPResponse(sock)
        response.begin()
        self.assertEqual((response.status, response.read()), (401, REPLY))
        self.assertEqual(self.record()["body"], b"hello")
        sock.sendall(b"GET /health HTTP/1.1\r\nHost: client\r\n\r\n")
        response = http.client.HTTPResponse(sock)
        response.begin()
        self.assertEqual((response.status, response.read()), (200, b"ok"))

    def test_long_response_three_seconds(self):
        started = time.monotonic()
        response, data = self.request("GET", f"/{ACCESS_KEY}/bot{TOKEN}/slow")
        self.assertEqual((response.status, data), (401, REPLY))
        self.assertGreaterEqual(time.monotonic() - started, 3)

    def test_response_content_length_keep_alive(self):
        conn = self.connection()
        conn.request("GET", PATH)
        first = conn.getresponse()
        self.assertEqual(first.read(), REPLY)
        self.assertEqual(first.getheader("Content-Length"), str(len(REPLY)))
        self.assertIsNone(first.getheader("Transfer-Encoding"))
        original_socket = conn.sock
        self.assertIsNotNone(original_socket)
        conn.request("GET", PATH)
        second = conn.getresponse()
        self.assertEqual(second.read(), REPLY)
        self.assertIs(conn.sock, original_socket)

    def test_chunked_and_close_delimited_upstream_responses(self):
        for method in ("chunkresponse", "nolength"):
            with self.subTest(method=method):
                conn = self.connection()
                conn.request("GET", f"/{ACCESS_KEY}/bot{TOKEN}/{method}")
                response = conn.getresponse()
                self.assertEqual((response.status, response.read()), (401, REPLY))
                self.assertEqual(response.getheader("Transfer-Encoding"), "chunked")
                self.assertIsNone(response.getheader("Content-Length"))
                sock = conn.sock
                conn.request("GET", "/health")
                response = conn.getresponse()
                self.assertEqual(response.read(), b"ok")
                self.assertIs(conn.sock, sock)

    def test_content_length_limit(self):
        conn = self.connection()
        conn.putrequest("POST", PATH)
        conn.putheader("Content-Length", str(MAX_BODY + 1))
        conn.endheaders()
        response = conn.getresponse()
        self.assertEqual(response.status, 413)
        response.read()
        self.assertTrue(self.upstream.records.empty())

    def test_chunked_limit_is_cumulative(self):
        gateway = self.start_gateway(constants={"MAX_BODY": 65536})
        sock = self.raw_socket(gateway)
        sock.sendall(f"POST {PATH} HTTP/1.1\r\nHost: client\r\nTransfer-Encoding: chunked\r\n\r\n".encode())
        for _ in range(3):
            sock.sendall(b"5000\r\n" + b"x" * 20480 + b"\r\n")
        # Each chunk fits; their sum exceeds the limit before reading this data.
        sock.sendall(b"5000\r\n")
        response = http.client.HTTPResponse(sock)
        response.begin()
        self.assertEqual(response.status, 413)
        response.read()

    def test_bad_request_framing(self):
        for header, body in (
            ("Content-Length: 1\r\nTransfer-Encoding: chunked", b""),
            ("Content-Length: 0\r\nContent-Length: 1", b""),
            (f"Content-Length: {TOKEN}", b""),
            ("Transfer-Encoding: gzip, chunked", b""),
            ("Transfer-Encoding: chunked", TOKEN.encode() + b"\r\n"),
            ("Transfer-Encoding: chunked", b"1\r\nxZZ"),
        ):
            sock = self.raw_socket()
            sock.sendall(f"POST {PATH} HTTP/1.1\r\nHost: client\r\n{header}\r\n\r\n".encode() + body)
            response = http.client.HTTPResponse(sock)
            response.begin()
            self.assertEqual(response.status, 400)
            self.assertNotIn(TOKEN.encode(), response.read())

    def test_denied_ip_closed_before_tls(self):
        gateway = self.start_gateway(allow="192.0.2.1")
        with socket.create_connection(("127.0.0.1", gateway.port), timeout=2) as sock:
            self.assertEqual(sock.recv(1), b"")
        with socket.create_connection(("127.0.0.1", gateway.port), timeout=2) as sock:
            with self.assertRaises((ssl.SSLError, OSError)):
                self.context.wrap_socket(sock, server_hostname="127.0.0.1")

    def test_slow_tls_client_does_not_block_accept(self):
        with socket.create_connection(("127.0.0.1", self.gateway.port), timeout=2):
            started = time.monotonic()
            response, data = self.request("GET", "/health")
            self.assertEqual((response.status, data), (200, b"ok"))
            self.assertLess(time.monotonic() - started, 1.5)

    def test_connection_limit(self):
        gateway = self.start_gateway(constants={"MAX_CONNECTIONS": 4})
        time.sleep(0.1)  # Allow the readiness probe's worker to release its slot.
        sockets = []
        try:
            for _ in range(4):
                sockets.append(socket.create_connection(("127.0.0.1", gateway.port), timeout=2))
            with socket.create_connection(("127.0.0.1", gateway.port), timeout=2) as extra:
                self.assertEqual(extra.recv(1), b"")
        finally:
            for sock in sockets:
                sock.close()

    def test_per_ip_limit_and_release(self):
        gateway = self.start_gateway(overrides={"TG_GW_PER_IP": "2"},
                                     constants={"MAX_CONNECTIONS": 8})
        time.sleep(0.1)
        sockets = []
        try:
            for _ in range(2):
                sockets.append(socket.create_connection(("127.0.0.1", gateway.port), timeout=2))
            with socket.create_connection(("127.0.0.1", gateway.port), timeout=2) as extra:
                self.assertEqual(extra.recv(1), b"")
            sockets.pop().close()  # Failed TLS must release the IP counter too.
            deadline = time.monotonic() + 2
            while True:
                try:
                    response, data = self.request("GET", "/health", gateway=gateway)
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise
                    time.sleep(0.02)
            self.assertEqual((response.status, data), (200, b"ok"))
            # A normally completed connection releases the slot as well.
            time.sleep(0.05)
            self.assertEqual(self.request("GET", PATH, gateway=gateway)[0].status, 401)
        finally:
            for sock in sockets:
                sock.close()

    def key_command(self, *args, check=True):
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("TG_GW_")}
        self.keys.parent.mkdir(mode=0o700, exist_ok=True)
        (self.keys.parent / "settings.json").write_text(json.dumps({"port": 18444, "public_host": "gateway.example"}))
        env.update({"HOME": self.temp.name, "TG_GW_KEYS": str(self.keys), "TG_GW_CERT": str(self.cert),
                    "TG_GW_PORT": "18999", "TG_GW_PUBLIC_HOST": "ignored.example"})
        result = subprocess.run(["/usr/bin/python3", "-I", str(BASE / "tg_gateway_keys.py"),
                                 *args], env=env, capture_output=True, text=True, timeout=5)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_key_utility_add_list_revoke_and_reload(self):
        result = self.key_command("add", "server-2")
        match = re.search(r"Базовый адрес: https://gateway.example:18444/([A-Za-z0-9_-]{43})\n",
                          result.stdout)
        self.assertIsNotNone(match)
        key = match[1]
        self.extra_secrets.append(key)
        self.assertEqual(result.stdout.count("Данные подключения"), 1)
        self.assertIn(self.cert.read_text(), result.stdout)
        for example in ('--cacert gw.pem', f'base_url="https://gateway.example:18444/{key}/bot"',
                        f'base_file_url="https://gateway.example:18444/{key}/file/bot"',
                        'TelegramAPIServer.from_base', 'baseApiUrl',
                        f'apiRoot: "https://gateway.example:18444/{key}/"',
                        'SSL_CERT_FILE', 'REQUESTS_CA_BUNDLE', 'NODE_EXTRA_CA_CERTS'):
            self.assertIn(example, result.stdout)
        contents = self.keys.read_text()
        self.assertNotIn(key, contents)
        data = json.loads(contents)
        self.assertEqual(data["keys"]["server-2"]["sha256"], hashlib.sha256(key.encode()).hexdigest())
        self.assertEqual(self.keys.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.keys.parent.stat().st_mode & 0o777, 0o700)
        listing = self.key_command("list").stdout
        self.assertRegex(listing, r"server-2 \d{4}-\d\d-\d\dT")
        self.assertNotIn(key, listing)
        self.assertNotIn(data["keys"]["server-2"]["sha256"], listing)
        self.wait_status(f"/{key}/health", 200)
        duplicate = self.key_command("add", "server-2", check=False)
        self.assertNotEqual(duplicate.returncode, 0)
        self.assertEqual(duplicate.stdout, "")
        self.assertEqual(self.keys.read_text(), contents)
        self.key_command("revoke", "server-2")
        self.wait_status(f"/{key}/health", 404)
        self.assertNotIn("server-2", self.key_command("list").stdout)
        self.assertNotEqual(self.key_command("revoke", "server-2", check=False).returncode, 0)

    def test_key_utility_new_state_show_cert_and_bad_names(self):
        self.keys.unlink()
        self.keys.parent.rmdir()
        self.assertEqual(self.key_command("list").stdout, "")
        self.assertFalse(self.keys.exists())
        result = self.key_command("add", "a" + "x" * 39)
        self.assertEqual(self.keys.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.keys.parent.stat().st_mode & 0o777, 0o700)
        before = self.keys.read_bytes()
        for name in ("", "Upper", "-bad", "bad/name", "x" * 41, "имя", "bad\nname"):
            self.assertNotEqual(self.key_command("add", name, check=False).returncode, 0)
            self.assertEqual(self.keys.read_bytes(), before)
        cert = self.key_command("show-cert").stdout
        self.assertIn(self.cert.read_text(), cert)
        fingerprint = subprocess.run(["openssl", "x509", "-in", str(self.cert),
                                      "-noout", "-fingerprint", "-sha256"],
                                     capture_output=True, text=True, check=True).stdout.strip().split("=", 1)[1]
        self.assertIn(fingerprint, cert)
        self.assertIn(fingerprint, result.stdout)

    def test_key_utility_json(self):
        result = self.key_command("add", "json-client", "--json")
        data = json.loads(result.stdout)
        self.assertEqual(set(data), {"base_url", "ca_pem", "sha256"})
        self.assertTrue(data["base_url"].startswith("https://gateway.example:18444/"))
        self.assertEqual(data["ca_pem"], self.cert.read_text())
        fingerprint = hashlib.sha256(ssl.PEM_cert_to_DER_cert(data["ca_pem"])).hexdigest().upper()
        self.assertEqual(data["sha256"].replace(":", ""), fingerprint)
        key = data["base_url"].rsplit("/", 1)[1]
        self.extra_secrets.append(key)
        self.assertNotIn(key, self.keys.read_text())
        self.wait_status(f"/{key}/health", 200)

    def test_key_utility_refuses_corrupt_file(self):
        corrupt = f'{{"invalid": "{ACCESS_KEY} bot{TOKEN}"}}'
        self.keys.write_text(corrupt)
        for args in (("add", "client"), ("list",), ("revoke", "test-client")):
            result = self.key_command(*args, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertNotIn(ACCESS_KEY, result.stderr)
            self.assertEqual(self.keys.read_text(), corrupt)

    def test_upstream_disconnect_returns_502(self):
        response, data = self.request("GET", f"/{ACCESS_KEY}/bot{TOKEN}/breakupstream?secret={QUERY_SECRET}",
                                      headers={"X-Secret": HEADER_SECRET})
        self.assertEqual((response.status, data), (502, b"502\n"))

    def test_upstream_unavailable_returns_502(self):
        # Reserve without listening so the gateway cannot reuse the same port.
        with socket.socket() as unavailable:
            unavailable.bind(("127.0.0.1", free_port()))
            gateway = self.start_gateway(overrides={
                "TG_GW_UPSTREAM_PORT": str(unavailable.getsockname()[1])})
            response, data = self.request("POST", PATH + f"?secret={QUERY_SECRET}",
                                          BODY_SECRET.encode(), {"X-Secret": HEADER_SECRET}, gateway)
        self.assertEqual((response.status, data), (502, b"502\n"))

    def test_upstream_certificate_is_verified(self):
        gateway = self.start_gateway(overrides={"TG_GW_UPSTREAM_CAFILE": ""})
        response, data = self.request("GET", PATH, gateway=gateway)
        self.assertEqual((response.status, data), (502, b"502\n"))

    def test_upstream_timeout_returns_504(self):
        gateway = self.start_gateway(constants={"IO_TIMEOUT": 0.3})
        response, data = self.request("GET", f"/{ACCESS_KEY}/bot{TOKEN}/slow", gateway=gateway)
        self.assertEqual((response.status, data), (504, b"504\n"))

    def test_parser_errors_never_echo_secret(self):
        for request in (
            f"GET {PATH}?secret={QUERY_SECRET} HTTP/9.9\r\n\r\n".encode(),
            f"GET {PATH} HTTP/1.1\r\n".encode()
            + (f"X-Secret: {HEADER_SECRET}\r\n" * 110).encode() + b"\r\n",
            b"GET /bot" + TOKEN.encode() + b"/" + b"x" * 66000 + b" HTTP/1.1\r\n\r\n",
        ):
            sock = self.raw_socket()
            sock.sendall(request)
            response = http.client.HTTPResponse(sock)
            response.begin()
            self.assertIn(response.status, (414, 431, 505))
            body = response.read()
            self.assertNotIn(TOKEN.encode(), body)
            self.assertNotIn(HEADER_SECRET.encode(), body)

    def test_unhandled_exceptions_only_print_class_names(self):
        # Fault-inject serve_forever, after main installs both exception hooks.
        runner = """
import runpy, sys, threading
module = runpy.run_path(sys.argv[1])
def fail(self, **kwargs):
    def worker():
        raise ValueError(sys.argv[2])
    thread = threading.Thread(target=worker)
    thread.start()
    thread.join()
    raise RuntimeError(sys.argv[2])
module['GatewayServer'].serve_forever = fail
module['main']('127.0.0.1')
"""
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("TG_GW_")}
        env.update({"HOME": self.temp.name, "TG_GW_PORT": str(free_port()),
                    "TG_GW_CERT": str(self.cert), "TG_GW_KEY": str(self.key)})
        result = subprocess.run(
            ["/usr/bin/python3", "-I", "-u", "-c", runner,
             str(BASE / "gateway.py"), PATH + f"?secret={QUERY_SECRET}"],
            cwd=BASE, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"ValueError\nRuntimeError\n")


if __name__ == "__main__":
    unittest.main()
