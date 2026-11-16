"""Inert signed fixtures, loopback providers and Chrome. No live home/service/API."""
import base64
import contextlib
import gzip
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request

SOURCE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOURCE))
import happier_web as web
import happier_web_release as release
import happier_web_quotas as quotas
from happier_web_common import ADDON, atomic, resolve_server_url

FIXTURE = Path(__file__).parent / 'fixtures/happier-web'
PIN = 'RWQ85PZ7FyiukYbL3qv/bKnwgbT68wLVzotapeMFIb8n+c7pBQ7U8W2t'
# Independent fixture contract: deleting a production guard marker must fail a test.
LOGIN_CONTRACT = ('./(app)/restore/manual.tsx', 'restore-manual-secret-input', 'restore-manual-submit',
                  'auth_credentials', '__srv_', 'scopedStorageId', 'normalizeSecretKey', 'authGetToken')


def node(script, *args):
    return subprocess.run(['node', '-e', script, *map(str, args)], capture_output=True, text=True, timeout=10)


def sign(data, algorithm='ED'):
    script = '''const c=require('node:crypto'); const {privateKey,publicKey}=c.generateKeyPairSync('ed25519');
const message=Buffer.from(process.argv[1],'base64'), alg=process.argv[2], id=Buffer.from('0102030405060708','hex');
const sig=c.sign(null,alg==='ED'?c.createHash('blake2b512').update(message).digest():message,privateKey);
const comment='timestamp:123 fixture';
console.log(JSON.stringify({pub:Buffer.concat([Buffer.from('Ed'),id,publicKey.export({type:'spki',format:'der'}).subarray(-32)]).toString('base64'),
sig:['untrusted comment: fixture',Buffer.concat([Buffer.from(alg),id,sig]).toString('base64'),'trusted comment: '+comment,c.sign(null,Buffer.concat([sig,Buffer.from(comment)]),privateKey).toString('base64')].join('\\n')+'\\n'}));'''
    result = node(script, base64.b64encode(data).decode(), algorithm)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def verify(data, signature, pub=PIN):
    result = node("const v=require(process.argv[1]);process.exit(v.verifyMinisign(Buffer.from(process.argv[2],'base64'),process.argv[3],process.argv[4])?0:1)",
                  SOURCE / 'happier_web_verify.cjs', base64.b64encode(data).decode(), signature, pub)
    return result.returncode == 0


def archive(path, files=None, members=None, contract=True):
    files = files or {'index.html': b'<html><head></head><body><div id="root"></div><script src="/app-abcdef123456.js"></script></body></html>',
                      'app-abcdef123456.js': b'window.fixture=true;'}
    files = dict(files)
    if contract:
        files['fixture-contract.js'] = b'/* ' + ' '.join(LOGIN_CONTRACT).encode() + b' */'
    with tarfile.open(path, 'w:gz') as tar:
        for name, data in files.items():
            entry = tarfile.TarInfo('ui/' + name); entry.size = len(data)
            tar.addfile(entry, io.BytesIO(data))
        for entry in members or []:
            tar.addfile(entry, io.BytesIO(b'') if entry.isfile() else None)


def fixture(directory, version='1.0.0', files=None, contract=True):
    directory.mkdir(parents=True, exist_ok=True)
    a = directory / ('happier-ui-web-v' + version + '-web-any.tar.gz')
    archive(a, files, contract=contract)
    checks = directory / ('checksums-happier-ui-web-v' + version + '.txt')
    checks.write_text(hashlib.sha256(a.read_bytes()).hexdigest() + '  ' + a.name + '\n')
    signed = sign(checks.read_bytes())
    sig = Path(str(checks) + '.minisig'); sig.write_text(signed['sig'])
    return a, checks, sig, signed['pub']


@contextlib.contextmanager
def running(server):
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    try:
        yield 'http://127.0.0.1:' + str(server.server_port)
    finally:
        server.shutdown(); server.server_close(); thread.join()


class Temp(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.base = self.root / 'state'
        self.base.mkdir()

    def install(self, version='1.0.0', files=None, keep=2, contract=True):
        a, c, s, pub = fixture(self.root / version, version, files, contract=contract)
        def verifier(checks, signature):
            if not verify(Path(checks).read_bytes(), Path(signature).read_text(), pub):
                raise ValueError('signature rejected')
        with patch.object(release, 'verify_signature', verifier):
            return release.install(self.base, 'ui-web-v' + version, a, c, s, keep)


class ReleaseTests(Temp):
    def test_login_contract_rejects_update_and_preserves_current(self):
        self.install()
        old = (self.base / 'current').readlink()
        for marker in LOGIN_CONTRACT:
            with self.subTest(marker=marker):
                files = {'index.html': b'<html><head></head><script src="/upstream.js"></script></html>',
                         'upstream.js': ' '.join(m for m in LOGIN_CONTRACT if m != marker).encode()}
                with self.assertRaisesRegex(ValueError, 'auto-login contract missing'):
                    self.install('2.0.0', files=files, contract=False)
                self.assertEqual((self.base / 'current').readlink(), old)
                self.assertFalse((self.base / 'releases/ui-web-v2.0.0').exists())

    def test_official_pinned_signature_and_crlf(self):
        c = FIXTURE / 'checksums-happier-ui-web-v0.2.21.txt'
        s = Path(str(c) + '.minisig')
        release.verify_signature(c, s)
        self.assertTrue(verify(c.read_bytes(), s.read_text().replace('\n', '\r\n')))
        self.assertFalse(verify(c.read_bytes() + b'changed', s.read_text()))

    def test_signatures_prehashed_plain_tampering_and_foreign_key(self):
        for alg in ('ED', 'Ed'):
            signed = sign(b'checksums fixture\r\n', alg)
            self.assertTrue(verify(b'checksums fixture\r\n', signed['sig'], signed['pub']))
            self.assertFalse(verify(b'altered', signed['sig'], signed['pub']))
            self.assertFalse(verify(b'checksums fixture\r\n', signed['sig'].replace('timestamp:123', 'timestamp:124'), signed['pub']))
            self.assertFalse(verify(b'checksums fixture\r\n', signed['sig'], PIN))
            other = sign(b'anything')['pub']
            self.assertFalse(verify(b'checksums fixture\r\n', signed['sig'], other))
            lines = signed['sig'].splitlines(); lines[3] = base64.b64encode(bytes(64)).decode()
            self.assertFalse(verify(b'checksums fixture\r\n', '\n'.join(lines), signed['pub']))

    def test_sha_mismatch_and_exact_filename(self):
        a, c, s, pub = fixture(self.root / 'download')
        release.verify_sha(a, c)
        a.write_bytes(a.read_bytes() + b'changed')
        with self.assertRaises(ValueError):
            release.verify_sha(a, c)

    def test_archive_traversal_symlink_hardlink_and_absolute_rejected_before_writes(self):
        for name, kind in [('../escape', tarfile.REGTYPE), ('/absolute', tarfile.REGTYPE),
                           ('ui/link', tarfile.SYMTYPE), ('ui/hard', tarfile.LNKTYPE),
                           ('ui/../escape', tarfile.REGTYPE), ('ui\\escape', tarfile.REGTYPE)]:
            a = self.root / 'bad.tar.gz'; m = tarfile.TarInfo(name); m.type = kind; m.linkname = '../outside'
            archive(a, members=[m])
            dest = self.root / 'extract'; dest.mkdir(exist_ok=True)
            with self.subTest(name=name), self.assertRaises(ValueError):
                release.extract(a, dest)
            self.assertEqual(list(dest.iterdir()), [])

    def test_atomic_interruption_and_rollback_retention(self):
        self.install()
        before = os.readlink(self.base / 'current')
        original = release.switch
        def interrupted(base, link, target):
            if link == 'current':
                raise RuntimeError('simulated interruption')
            original(base, link, target)
        with patch.object(release, 'switch', interrupted), self.assertRaises(RuntimeError):
            self.install('1.0.1')
        self.assertEqual(os.readlink(self.base / 'current'), before)
        self.install('1.0.2')
        release.rollback(self.base)
        self.assertEqual(os.readlink(self.base / 'current'), before)
        # Returning to a retained verified release after rollback is allowed.
        self.install('1.0.2')
        release.rollback(self.base)
        self.install('1.0.3')
        self.assertEqual(len(list((self.base / 'releases').iterdir())), 2)
        self.assertTrue((release.release_path(self.base) / 'happier-ui-web-v1.0.3-web-any.tar.gz').is_file())

    def test_injection_idempotent_before_first_script_and_index_sidecars_removed(self):
        html = '<html>\r\n<HEAD><script src="bundle.js"></script></HEAD></html>'
        patched = release.inject(html)
        self.assertEqual(release.inject(patched), patched)
        self.assertEqual(patched.count(ADDON), 1)
        self.assertLess(patched.index(ADDON), patched.index('bundle.js'))
        self.install(files={'index.html':html.encode(), 'index.html.gz':gzip.compress(html.encode())})
        self.assertFalse((release.release_path(self.base) / 'web/index.html.gz').exists())

    def test_stable_channel_download_is_mocked_and_signature_checked_before_archive(self):
        calls = []
        listing = [dict(tag_name='ui-web-v9.0.0', prerelease=True),
                   dict(tag_name='cli-v9.0.0', prerelease=False),
                   dict(tag_name='ui-web-v1.0.0', prerelease=False, assets=[
                       dict(name=n, browser_download_url='https://fixture.invalid/' + n) for n in
                       ['checksums-happier-ui-web-v1.0.0.txt', 'checksums-happier-ui-web-v1.0.0.txt.minisig', 'happier-ui-web-v1.0.0-web-any.tar.gz']])]
        def download(url, dest, limit):
            calls.append(url)
            dest.write_text(json.dumps(listing) if 'api.github' in url else 'tampered')
        with patch.object(release, 'download', download), self.assertRaises(ValueError):
            release.update(self.base)
        self.assertEqual(len(calls), 3)
        self.assertFalse((self.base / 'current').exists())


class ServerUrlTests(Temp):
    def test_explicit_native_active_and_fallback_without_vendor_import(self):
        home = self.root / 'home'
        native = home / '.happier/settings.json'
        atomic(native, json.dumps(dict(activeServerId='private',servers=dict(
            cloud=dict(serverUrl='https://cloud.fixture.invalid'),
            private=dict(serverUrl='http://127.0.0.1:3005/')))))
        before = native.read_bytes()
        self.assertEqual(resolve_server_url(home), 'http://127.0.0.1:3005')
        self.assertEqual(resolve_server_url(home,'https://explicit.fixture.invalid/'), 'https://explicit.fixture.invalid')
        self.assertEqual(native.read_bytes(), before)
        for invalid in ('{broken', '{"activeServerId":{},"servers":{}}', '{"servers":[]}'):
            atomic(native, invalid)
            self.assertEqual(resolve_server_url(home), 'https://api.happier.dev')
        for url in ('file:///tmp/x','https://user:SECRET@example.invalid','https://example.invalid/path','https://example.invalid?token=SECRET'):
            with self.assertRaises(ValueError):
                resolve_server_url(home,url)
        atomic(native,json.dumps(dict(activeServerId='private',servers=dict(private=dict(serverUrl='https://native.fixture.invalid')))))
        with running(web.make_server(self.base,0,server_url=None,home=home)) as url:
            with urllib.request.urlopen(url+ADDON,timeout=3) as response:
                data=response.read()
            self.assertIn(b'https://native.fixture.invalid',data)
            self.assertNotIn(b'__REMOTEAGENTS_SERVER_URL__',data)
        with running(web.make_server(self.base,0,server_url='https://explicit.fixture.invalid',home=home)) as url:
            with urllib.request.urlopen(url+ADDON,timeout=3) as response:
                self.assertIn(b'https://explicit.fixture.invalid',response.read())


class ServingTests(Temp):
    def get(self, url, encoding=None, method='GET'):
        req = urllib.request.Request(url, headers={'Accept-Encoding': encoding} if encoding else {}, method=method)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            response = opener.open(req, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, response.headers, response.read()

    def test_spa_mime_404_cache_compression_and_old_chunks(self):
        old = {'index.html':b'<head></head><script src="bundle.js"></script>', 'old-abcdef123456.js':b'old', 'not-hashed.js':b'old'}
        self.install(files=old)
        files = {'index.html':old['index.html'], 'main-123456789abc.js':b'javascript',
                 'main-123456789abc.js.gz':gzip.compress(b'javascript'), 'main-123456789abc.js.br':b'brotli-fixture',
                 'a.wasm':b'wasm', 'a.json':b'{}', 'a.css':b'css', 'a.svg':b'svg', 'a.woff2':b'font'}
        self.install('1.0.1', files)
        with running(web.make_server(self.base, 0, 17)) as url:
            for path in ('/', '/chat/abc', '/index.html', ADDON):
                code, h, data = self.get(url + path)
                self.assertEqual(code, 200); self.assertEqual(h['Cache-Control'], 'no-store')
            for ext, mime in [('js','text/javascript'), ('wasm','application/wasm'), ('json','application/json'), ('css','text/css'), ('svg','image/svg+xml'), ('woff2','font/woff2')]:
                path = '/main-123456789abc.js' if ext == 'js' else '/a.' + ext
                self.assertEqual(self.get(url + path)[1]['Content-Type'], mime)
            code, h, data = self.get(url + '/old-abcdef123456.js')
            self.assertEqual(data, b'old'); self.assertIn('immutable', h['Cache-Control'])
            for path in ('/missing.js', '/not-hashed.js', '/assets/missing', '/_remoteagents/missing', '/%2e%2e/outside', '/_remoteagents/../health', '/api/unknown'):
                self.assertEqual(self.get(url + path)[0], 404, path)
            for accepted, selected in [('gzip', 'gzip'), ('br,gzip;q=0.5','br'), ('br;q=0,gzip;q=0.1','gzip'), ('br;q=0,gzip;q=0',None)]:
                code, h, data = self.get(url + '/main-123456789abc.js', accepted)
                self.assertEqual(h.get('Content-Encoding'), selected); self.assertEqual(h['Vary'], 'Accept-Encoding')
            self.assertEqual(self.get(url + '/old-abcdef123456.js', method='HEAD')[2], b'')
            health = json.loads(self.get(url + '/_remoteagents/health')[2])
            self.assertEqual(health, dict(ok=True, uiVersion='ui-web-v1.0.1'))
            self.assertIn(b'RecentKeepCount: 17', self.get(url + ADDON)[2])
            self.assertEqual(json.loads(self.get(url + '/_remoteagents/quotas')[2]), dict(schema=1, accounts=[]))

    def test_symlink_files_and_parent_are_not_served(self):
        self.install()
        root = release.release_path(self.base) / 'web'
        (self.root / 'secret.js').write_text('PRIVATE_SENTINEL')
        (root / 'leak.js').symlink_to(self.root / 'secret.js')
        (root / 'linked').symlink_to(self.root, target_is_directory=True)
        with running(web.make_server(self.base, 0)) as url:
            for path in ('/leak.js','/linked/secret.js'):
                self.assertEqual(self.get(url + path)[0], 404)

    def test_chrome_addon_visibility_runtime_banner_and_modal(self):
        from resource_guard import wait_for_memory
        if not wait_for_memory():
            self.skipTest('available memory below 2000 MiB after 20 waits')
        bundle = b'''let got=0, page=0;
for(const e of ['visibilitychange','webkitvisibilitychange','freeze']) document.addEventListener(e,()=>got++);
window.addEventListener('visibilitychange',()=>got++);
window.addEventListener('pagehide',()=>page++);
for(const e of ['visibilitychange','webkitvisibilitychange','freeze']) document.dispatchEvent(new Event(e,{bubbles:true}));
window.dispatchEvent(new Event('pagehide'));
const check=()=>{const bar=document.getElementById('remoteagents-quotas');
if(!bar || !bar.textContent.includes('95%')) return setTimeout(check,20);
const modal=document.createElement('div'); modal.id='modal'; modal.style='position:fixed;inset:0;z-index:100;background:white';document.body.append(modal);
const tuning=JSON.parse(localStorage.HAPPIER_SYNC_TUNING_JSON);
const valid=got===0 && page===1 && !document.hidden && document.visibilityState==='visible' && window.__HAPPIER_WEB_RUNTIME_CONFIG__.serverUrl==='https://api.happier.dev' && tuning.sessionTranscriptRetentionRecentKeepCount===13 && tuning.custom===42 && tuning.sessionRealtimeProjectionMode==='disabled' && document.getElementById('root').getBoundingClientRect().top>=bar.getBoundingClientRect().bottom && document.elementFromPoint(10,10)===modal && bar.querySelector('span span').style.color==='rgb(255, 119, 119)';
document.body.setAttribute('data-result',valid?'PASS':'FAIL');document.body.setAttribute('data-banner',bar.textContent);};check();'''
        html = b'<html><head><style>html,body,#root{height:100%;margin:0}</style></head><body><div id="root"></div><script src="/app-abcdef123456.js"></script></body></html>'
        self.install(files={'index.html':html, 'app-abcdef123456.js':bundle, 'seed.html':b'<script>localStorage.HAPPIER_SYNC_TUNING_JSON=JSON.stringify({custom:42});location.replace("/")</script>'})
        atomic(self.base / 'state/quotas.json', json.dumps(dict(schema=1, accounts=[dict(id='fixture',provider='claude',label='Claude acc1',status='ok',fetchedAt=quotas.iso(__import__('time').time()),windows=[dict(id='five_hour',label='5 ч',usedPercent=95,resetsAt='2026-12-01T00:00:00Z')])],)))
        with running(web.make_server(self.base, 0, 13)) as url:
            process = subprocess.Popen(['nice','-n','10','/usr/bin/google-chrome','--headless','--no-sandbox','--disable-gpu',
                '--disable-dev-shm-usage','--disable-background-networking','--disable-sync','--disable-extensions',
                '--no-first-run','--no-default-browser-check','--no-proxy-server',
                '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1',
                '--user-data-dir=' + str(self.root / 'chrome'),'--virtual-time-budget=5000','--dump-dom',url+'/seed.html'],
                stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
            try:
                stdout, stderr = process.communicate(timeout=40)
                result = subprocess.CompletedProcess(process.args,process.returncode,stdout,stderr)
            finally:
                # Kill only this test's process group, including Chrome helpers on timeout.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
        self.assertEqual(result.returncode, 0)
        self.assertIn('data-result="PASS"', result.stdout, result.stdout[-5000:])
        self.assertIn('Claude acc1: 5 ч 95%', result.stdout)


class ProviderHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def respond(self):
        auth = self.headers.get('Authorization')
        self.server.requests.append((self.path, self.command, {k.lower():v for k,v in self.headers.items()}, self.rfile.read(int(self.headers.get('Content-Length', 0)))))
        status = self.server.status
        self.send_response(status)
        if status == 429:
            self.send_header('Retry-After', self.server.retry_after)
        if self.path == '/messages':
            for key, value in {'5h-utilization':'0.32','7d-utilization':'0.6', '5h-reset':'1800000000', '7d-reset':'1800100000'}.items():
                self.send_header('anthropic-ratelimit-unified-' + key, value)
            self.send_header('anthropic-ratelimit-unified-status', 'allowed')
        self.end_headers()
        if self.path == '/oauth/usage':
            payload = dict(five_hour=dict(utilization=32,resets_at='2026-12-01T00:00:00Z'),seven_day=dict(utilization=60,resets_at=None))
        elif getattr(self.server, 'codex_rate', None) is not None:
            payload = dict(rate_limit=self.server.codex_rate)
        else:
            payload = dict(rate_limit=dict(primary_window=dict(used_percent=10,reset_at=1800000000,limit_window_seconds=18000), secondary_window=dict(used_percent=40,reset_after_seconds=100,limit_window_seconds=604800)))
        payload['unsafe_provider_echo'] = auth
        self.wfile.write(json.dumps(payload).encode())


class QuotaTests(Temp):
    def credentials(self):
        def write(name, data):
            path = self.root / 'home' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(data) if not isinstance(data, str) else data)
        self.home = self.root / 'home'
        prefix = '.happier/servers/cloud/daemon/connected-services/homes/claude-subscription/'
        write(prefix + 'acc1/claude/claude-config/.credentials.json', dict(claudeAiOauth=dict(accessToken='OAUTH_TOKEN_SENTINEL', scopes=['user:profile','user:inference'])))
        write('.claude/.credentials.json', dict(claudeAiOauth=dict(accessToken='OAUTH_TOKEN_SENTINEL', scopes=['user:profile'])))
        write('.config/remoteagents/claude.env', 'CLAUDE_CODE_OAUTH_TOKEN="SETUP_TOKEN_SENTINEL"\r\n')
        write('.codex/auth.json', dict(tokens=dict(access_token='CODEX_TOKEN_SENTINEL', account_id='ACCOUNT_FIXTURE')))
        return write

    def server(self):
        s = ThreadingHTTPServer(('127.0.0.1',0), ProviderHandler)
        s.status = 200; s.requests = []; s.retry_after = '4000'
        return s

    def test_discovery_dedup_oauth_usage_probe_headers_and_private_cache(self):
        self.credentials()
        accounts = quotas.discover(self.home)
        self.assertEqual(len(accounts), 3)
        self.assertEqual(accounts[0]['label'], 'Claude acc1')
        server = self.server()
        with running(server) as url:
            poller = quotas.Poller(self.home, self.base / 'private/quotas.json', urls=dict(claude=url+'/oauth/usage',probe=url+'/messages',codex=url+'/wham/usage'), now=lambda:1700000000)
            poller.tick(); poller.tick()
        self.assertEqual(len(server.requests), 3)
        rows = list(poller.accounts.values())
        self.assertEqual(rows[0]['windows'][0]['usedPercent'], 32)
        self.assertEqual(rows[1]['windows'][0]['usedPercent'], 32)
        self.assertEqual(rows[2]['windows'][1]['usedPercent'], 40)
        for path, method, headers, body in server.requests:
            if path == '/messages':
                self.assertEqual(method, 'POST'); self.assertEqual(json.loads(body)['max_tokens'], 1)
                self.assertEqual(headers['anthropic-beta'], 'oauth-2025-04-20')
            if path == '/wham/usage':
                self.assertEqual(headers['chatgpt-account-id'], 'ACCOUNT_FIXTURE')
        raw = poller.cache.read_text()
        for secret in ('OAUTH_TOKEN_SENTINEL', 'SETUP_TOKEN_SENTINEL', 'CODEX_TOKEN_SENTINEL', 'unsafe_provider_echo', 'ACCOUNT_FIXTURE'):
            self.assertNotIn(secret, raw)
        self.assertEqual(poller.cache.stat().st_mode & 0o777, 0o600)
        self.assertEqual(poller.cache.parent.stat().st_mode & 0o777, 0o700)

    def test_codex_window_label_follows_length_not_slot(self):
        # Real plans may report only a weekly primary window.
        self.credentials(); server = self.server()
        server.codex_rate = dict(primary_window=dict(used_percent=72,reset_at=1800000000,limit_window_seconds=604800), secondary_window=None)
        with running(server) as url:
            poller = quotas.Poller(self.home, self.base/'cache/quotas.json', urls=dict(claude=url+'/oauth/usage',probe=url+'/messages',codex=url+'/wham/usage'))
            poller.tick()
        codex = [row for row in poller.accounts.values() if row['provider'] == 'codex'][0]
        self.assertEqual([(w['label'], w['usedPercent']) for w in codex['windows']], [('неделя', 72)])

    def test_401_403_need_login_429_pause_and_restart_honors_retry(self):
        self.credentials(); server = self.server(); now = [1700000000]
        with running(server) as url:
            urls = dict(claude=url+'/oauth/usage',probe=url+'/messages',codex=url+'/wham/usage')
            poller = quotas.Poller(self.home, self.base/'cache/quotas.json', urls=urls, now=lambda:now[0]); poller.tick()
            for code in (401,403,429):
                server.status = code; now[0] += 5000
                poller.tick()
                self.assertTrue(all(row['status'] == ('paused' if code == 429 else 'auth_required') for row in poller.accounts.values()))
                self.assertTrue(all(row['windows'] for row in poller.accounts.values()))
            count = len(server.requests)
            restarted = quotas.Poller(self.home, poller.cache, urls=urls, now=lambda:now[0]+3999)
            restarted.tick()
            self.assertEqual(len(server.requests),count)
            self.assertGreaterEqual(min(restarted.next.values()),now[0]+4000)
            server.retry_after = email_date = __import__('email.utils',fromlist=['formatdate']).formatdate(now[0]+20000, usegmt=True)
            now[0] += 5000; poller.tick()
            self.assertTrue(all(quotas.epoch(row['retryAt']) >= now[0]+15000 for row in poller.accounts.values()))

    def test_probe_disabled_unknown_data_and_no_provider_error_leaks(self):
        self.credentials(); server = self.server()
        with running(server) as url:
            poller = quotas.Poller(self.home, self.base/'cache/quotas.json', options=dict(claudeProbe=False), urls=dict(claude=url+'/oauth/usage',probe=url+'/messages',codex=url+'/wham/usage'))
            server.status=500; poller.tick()
            self.assertEqual(len(server.requests),2)
            rows=list(poller.accounts.values())
            self.assertEqual(rows[1]['status'],'disabled'); self.assertEqual(rows[0]['status'],'error')
            self.assertEqual(rows[0]['windows'],[])
            self.assertNotIn('TOKEN_SENTINEL',poller.cache.read_text())
            self.assertIsNone(quotas.percent(None)); self.assertIsNone(quotas.percent(float('nan')))


if __name__ == '__main__':
    unittest.main()
