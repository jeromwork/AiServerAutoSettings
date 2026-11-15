#!/usr/bin/python3
"""A bounded, streaming HTTPS gateway for the Telegram Bot API (stdlib only)."""

import datetime
import hashlib
import http.client
import ipaddress
import json
import os
import re
import signal
import ssl
import sys
import threading
import time
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


MAX_BODY = 52 * 1024 * 1024
BUFFER_SIZE = 64 * 1024
MAX_CONNECTIONS = 256
HANDSHAKE_TIMEOUT = 10
IO_TIMEOUT = 90
KEY_PATTERN = r"[A-Za-z0-9_-]{43}"
BOT_PATH = re.compile(
    rf"/(?P<key>{KEY_PATTERN})"
    r"(?P<target>/bot\d+:[A-Za-z0-9_-]+/(?P<method>[A-Za-z]+))", re.ASCII,
)
FILE_PATH = re.compile(
    rf"/(?P<key>{KEY_PATTERN})"
    r"(?P<target>/file/bot\d+:[A-Za-z0-9_-]+/"
    r"(?P<fp>[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*))", re.ASCII,
)
HEALTH_PATH = re.compile(rf"/(?P<key>{KEY_PATTERN})/health", re.ASCII)
CLIENT_NAME = re.compile(r"[a-z0-9][a-z0-9._-]{0,39}", re.ASCII)
KEY_CHECK_INTERVAL = 2
HOP_HEADERS = {
    "connection", "keep-alive", "te", "trailer", "transfer-encoding", "upgrade",
}
LOG_LOCK = threading.Lock()


def exception_name(exc_type, exc=None, *_):
    """Never format an exception: its message/traceback may contain a token."""
    name = exc_type.__name__
    # OpenSSL reason codes are fixed identifiers (e.g. HTTP_REQUEST), never request data.
    reason = getattr(exc, "reason", None) if isinstance(exc, ssl.SSLError) else None
    if isinstance(reason, str) and re.fullmatch(r"[A-Z0-9_]{1,64}", reason):
        name = f"{name}:{reason}"
    with LOG_LOCK:
        print(name, file=sys.stderr, flush=True)


def request_log(client, method, status, started):
    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat(
        timespec="milliseconds"
    ).replace("+00:00", "Z")
    elapsed = int((time.monotonic() - started) * 1000)
    with LOG_LOCK:
        print(f"{timestamp} {client} {method} {status} {elapsed}ms", flush=True)


class KeyStore:
    """Atomically replace the hash index; never retain plaintext access keys."""

    def __init__(self, path):
        self.path = Path(path)
        self.lock = threading.Lock()
        self.next_check = 0
        self.signature = object()
        self.hashes = {}

    def lookup(self, key):
        digest = hashlib.sha256(key.encode("ascii")).hexdigest()
        with self.lock:
            now = time.monotonic()
            if now >= self.next_check:
                self.next_check = now + KEY_CHECK_INTERVAL
                self.reload()
            return self.hashes.get(digest)

    def reload(self):
        try:
            stat = self.path.stat()
            signature = (stat.st_mtime_ns, stat.st_ino, stat.st_size)
            if signature == self.signature:
                return
            self.signature = signature
            data = json.loads(self.path.read_text(encoding="utf-8"))
            if (not isinstance(data, dict) or type(data.get("version")) is not int
                    or data["version"] != 1 or not isinstance(data.get("keys"), dict)):
                raise ValueError()
            hashes = {}
            for name, record in data["keys"].items():
                if (not CLIENT_NAME.fullmatch(name) or not isinstance(record, dict)
                        or not isinstance(record.get("sha256"), str)
                        or not re.fullmatch(r"[a-fA-F0-9]{64}", record["sha256"])
                        or not isinstance(record.get("created"), str)):
                    raise ValueError()
                datetime.datetime.fromisoformat(record["created"])
                digest = record["sha256"].lower()
                if digest in hashes:
                    raise ValueError()
                hashes[digest] = name
            self.hashes = hashes
        except FileNotFoundError:
            self.signature = None
            self.hashes = {}
        except (OSError, ValueError, RecursionError):
            # Neither parser errors nor file contents may reach stderr.
            with LOG_LOCK:
                print("keys: invalid", file=sys.stderr, flush=True)


def excluded_headers(headers):
    excluded = set(HOP_HEADERS)
    for value in headers.get_all("Connection", []):
        excluded.update(part.strip().lower() for part in value.split(","))
    return excluded


def is_hop_header(name, excluded):
    return name.lower() in excluded or name.lower().startswith("proxy-")


@dataclass(frozen=True)
class Config:
    port: int
    cert: str
    key: str
    allowed: frozenset
    keys: str
    per_ip: int
    upstream_host: str
    upstream_port: int
    upstream_cafile: str | None

    @classmethod
    def from_env(cls):
        base = Path(__file__).resolve().parent
        config = cls(
            port=int(os.environ.get("TG_GW_PORT", "8444")),
            cert=os.environ.get("TG_GW_CERT", str(base / "tls/cert.pem")),
            key=os.environ.get("TG_GW_KEY", str(base / "tls/key.pem")),
            allowed=frozenset(
                ipaddress.ip_address(item.strip())
                for item in os.environ.get(
                    "TG_GW_ALLOW", ""
                ).split(",") if item.strip()
            ),
            keys=os.environ.get("TG_GW_KEYS", str(base / "state/keys.json")),
            per_ip=int(os.environ.get("TG_GW_PER_IP", "16")),
            upstream_host=os.environ.get("TG_GW_UPSTREAM_HOST", "api.telegram.org"),
            upstream_port=int(os.environ.get("TG_GW_UPSTREAM_PORT", "443")),
            upstream_cafile=os.environ.get("TG_GW_UPSTREAM_CAFILE") or None,
        )
        if not (1 <= config.port <= 65535 and 1 <= config.upstream_port <= 65535
                and config.per_ip > 0):
            raise ValueError()
        return config


class ClientError(Exception):
    def __init__(self, status):
        self.status = status


class GatewayServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128
    allow_reuse_address = True

    def __init__(self, config, bind_host="0.0.0.0"):
        self.config = config
        self.slots = threading.BoundedSemaphore(MAX_CONNECTIONS)
        self.ip_lock = threading.Lock()
        self.ip_connections = {}
        self.keys = KeyStore(config.keys)
        self.tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.tls.minimum_version = ssl.TLSVersion.TLSv1_2
        self.tls.load_cert_chain(config.cert, config.key)
        self.upstream_tls = ssl.create_default_context(cafile=config.upstream_cafile)
        super().__init__((bind_host, config.port), GatewayHandler)

    def verify_request(self, request, client_address):
        # The accepted socket is still raw here: denied clients never receive TLS.
        return (not self.config.allowed or
                ipaddress.ip_address(client_address[0]) in self.config.allowed)

    def process_request(self, request, client_address):
        ip = client_address[0]
        with self.ip_lock:
            admitted = (self.ip_connections.get(ip, 0) < self.config.per_ip
                        and self.slots.acquire(blocking=False))
            if admitted:
                self.ip_connections[ip] = self.ip_connections.get(ip, 0) + 1
        if not admitted:
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.release_connection(ip)
            raise

    def release_connection(self, ip):
        with self.ip_lock:
            self.ip_connections[ip] -= 1
            if not self.ip_connections[ip]:
                del self.ip_connections[ip]
            self.slots.release()

    def process_request_thread(self, request, client_address):
        connection = request
        try:
            request.settimeout(HANDSHAKE_TIMEOUT)
            # Even the SSL wrapping happens in the worker, never in accept().
            connection = self.tls.wrap_socket(
                request, server_side=True, do_handshake_on_connect=False
            )
            connection.do_handshake()
            connection.settimeout(IO_TIMEOUT)
            self.finish_request(connection, client_address)
        except Exception:
            self.handle_error(connection, client_address)
        finally:
            self.shutdown_request(connection)
            self.release_connection(client_address[0])

    def handle_error(self, request, client_address):
        exception_name(*sys.exc_info()[:2])


class GatewayHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def log_error(self, *args):
        pass

    def log_request(self, *args):
        pass

    def send_response_only(self, code, message=None):
        if code >= 200:
            self._status = code
            self._response_started = True
        super().send_response_only(code, message)

    def send_error(self, code, message=None, explain=None):
        # BaseHTTPRequestHandler's default errors can echo untrusted input.
        # Its parser initially assumes HTTP/0.9, even for malformed HTTP/1.x.
        if self.request_version == "HTTP/0.9":
            self.request_version = "HTTP/1.1"
        self.short_response(code)

    def short_response(self, code, body=None, close=True):
        if self._response_started:
            self.close_connection = True
            return
        body = body if body is not None else f"{code}\n".encode("ascii")
        self.send_response_only(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        if code == 405:
            self.send_header("Allow", self._allowed_methods)
        if close:
            self.close_connection = True
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def handle_one_request(self):
        started = time.monotonic()
        self._status = 400
        self._response_started = False
        self._api_method = "-"
        self._client = "-"
        self._allowed_methods = "GET, POST"
        self.raw_requestline = b""
        try:
            self.raw_requestline = self.rfile.readline(65537)
            if not self.raw_requestline:
                self.close_connection = True
                return
            if len(self.raw_requestline) > 65536:
                self.requestline = ""
                self.request_version = "HTTP/1.1"
                self.short_response(414)
                return
            if not self.parse_request():
                return
            if self.request_version == "HTTP/0.9":
                self.request_version = "HTTP/1.1"
                self.short_response(400)
                return
            # Preserve the original target; BaseHTTPRequestHandler normalizes //.
            self.path = self.requestline.split()[1]
            path, separator, query = self.path.partition("?")
            bot = BOT_PATH.fullmatch(path)
            file = FILE_PATH.fullmatch(path)
            health = HEALTH_PATH.fullmatch(path)
            match = bot or file or health
            local_health = (path == "/health" and self.command == "GET"
                            and self.client_address[0] == "127.0.0.1")
            if match and not (file and any(
                    part in (".", "..") for part in file["fp"].split("/"))):
                self._client = self.server.keys.lookup(match["key"]) or "-"
            if not local_health and (not match or self._client == "-"):
                self.short_response(404)
            elif local_health or health:
                self._api_method = "health"
                self._allowed_methods = "GET"
                if self.command != "GET":
                    self.short_response(405)
                    return
                # Close if there is an unconsumed request body.
                close = bool(self.headers.get("Content-Length") or
                             self.headers.get("Transfer-Encoding"))
                self.short_response(200, b"ok", close=close)
            else:
                self._api_method = bot["method"] if bot else "file"
                self._allowed_methods = "GET, POST" if bot else "GET"
                if self.command not in self._allowed_methods.split(", "):
                    self.short_response(405)
                else:
                    target = match["target"] + (separator + query if separator else "")
                    self.proxy_request(target)
            self.wfile.flush()
        except ClientError as exc:
            self.short_response(exc.status)
        except TimeoutError:
            self.short_response(408)
            self.close_connection = True
        except (OSError, ValueError, http.client.HTTPException):
            self.close_connection = True
        finally:
            if self.raw_requestline:
                request_log(self._client, self._api_method, self._status, started)

    def body_framing(self):
        lengths = self.headers.get_all("Content-Length", [])
        transfers = self.headers.get_all("Transfer-Encoding", [])
        if transfers:
            if lengths or len(transfers) != 1 or transfers[0].strip().lower() != "chunked":
                raise ClientError(400)
            return "chunked", None
        if lengths:
            if len(lengths) != 1 or not re.fullmatch(r"[0-9]{1,20}", lengths[0]):
                raise ClientError(400)
            length = int(lengths[0])
            if length > MAX_BODY:
                raise ClientError(413)
            return "length", length
        return "none", 0

    def client_read(self, size):
        try:
            data = self.rfile.read(size)
        except TimeoutError:
            raise ClientError(408) from None
        if len(data) != size:
            raise ClientError(400)
        return data

    def client_line(self):
        try:
            line = self.rfile.readline(8193)
        except TimeoutError:
            raise ClientError(408) from None
        if len(line) > 8192 or not line.endswith(b"\r\n"):
            raise ClientError(400)
        return line

    def forward_body(self, upstream, framing, length):
        if framing != "chunked":
            remaining = length
            while remaining:
                data = self.client_read(min(BUFFER_SIZE, remaining))
                upstream.send(data)
                remaining -= len(data)
            return
        total = 0
        while True:
            size_text = self.client_line()[:-2].split(b";", 1)[0]
            if not re.fullmatch(rb"[0-9a-fA-F]{1,16}", size_text):
                raise ClientError(400)
            size = int(size_text, 16)
            total += size
            if total > MAX_BODY:
                raise ClientError(413)
            if size == 0:
                # Consume bounded trailers, but do not forward their headers.
                trailer_bytes = 0
                while True:
                    line = self.client_line()
                    trailer_bytes += len(line)
                    if trailer_bytes > 65536:
                        raise ClientError(400)
                    if line == b"\r\n":
                        break
                    if b":" not in line:
                        raise ClientError(400)
                upstream.send(b"0\r\n\r\n")
                return
            upstream.send(f"{size:x}\r\n".encode("ascii"))
            remaining = size
            while remaining:
                data = self.client_read(min(BUFFER_SIZE, remaining))
                upstream.send(data)
                remaining -= len(data)
            if self.client_read(2) != b"\r\n":
                raise ClientError(400)
            upstream.send(b"\r\n")

    def proxy_request(self, target):
        framing, length = self.body_framing()
        config = self.server.config
        upstream = http.client.HTTPSConnection(
            config.upstream_host, config.upstream_port,
            timeout=IO_TIMEOUT, context=self.server.upstream_tls,
        )
        try:
            upstream.putrequest(self.command, target,
                                skip_host=True, skip_accept_encoding=True)
            upstream.putheader("Host", config.upstream_host)
            excluded = excluded_headers(self.headers) | {"host", "content-length"}
            for name, value in self.headers.items():
                if not is_hop_header(name, excluded):
                    upstream.putheader(name, value)
            if framing == "chunked":
                upstream.putheader("Transfer-Encoding", "chunked")
            elif framing == "length":
                upstream.putheader("Content-Length", str(length))
            upstream.endheaders()
            self.forward_body(upstream, framing, length)
            response = upstream.getresponse()
            self.forward_response(response)
        except TimeoutError:
            self.short_response(504)
        except (OSError, http.client.HTTPException):
            self.short_response(502)
        finally:
            upstream.close()

    def forward_response(self, response):
        headers = response.headers
        excluded = excluded_headers(headers)
        no_body = response.status in (204, 304) or 100 <= response.status < 200
        # http.client removes upstream chunk framing; apply our own framing.
        length_headers = headers.get_all("Content-Length", [])
        length = None
        if not response.chunked and length_headers:
            if len(length_headers) != 1 or not re.fullmatch(r"[0-9]{1,20}", length_headers[0]):
                raise http.client.HTTPException()
            length = int(length_headers[0])
        self.send_response_only(response.status, response.reason)
        for name, value in response.getheaders():
            if name.lower() != "content-length" and not is_hop_header(name, excluded):
                self.send_header(name, value)
        if length is not None:
            self.send_header("Content-Length", str(length))
        elif not no_body:
            self.send_header("Transfer-Encoding", "chunked")
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        if no_body:
            return
        remaining = length
        while remaining is None or remaining:
            data = response.read(BUFFER_SIZE if remaining is None else min(BUFFER_SIZE, remaining))
            if not data:
                if remaining:
                    self.close_connection = True
                break
            if length is None:
                self.wfile.write(f"{len(data):x}\r\n".encode("ascii"))
                self.wfile.write(data)
                self.wfile.write(b"\r\n")
            else:
                self.wfile.write(data)
                remaining -= len(data)
        if length is None:
            self.wfile.write(b"0\r\n\r\n")


def main(bind_host="0.0.0.0"):
    sys.excepthook = exception_name
    threading.excepthook = lambda args: exception_name(args.exc_type, args.exc_value)
    server = GatewayServer(Config.from_env(), bind_host)

    def stop(signum, frame):
        # shutdown() must run outside serve_forever's thread.
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    with server:
        server.serve_forever(poll_interval=0.2)


if __name__ == "__main__":
    main()
