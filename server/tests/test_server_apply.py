#!/usr/bin/env python3
"""Reconcile a disposable Linux root. No service, package or network command is real."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('server_apply', SOURCE / 'server_apply.py')
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)
PIN = ':'.join(['AB'] * 32)
PROFILE = '''client
remote 8.8.4.4 1194 tcp-client
route 10.123.0.0 255.255.0.0
<ca>
TEST_CA_NO_SECRET
</ca>
<key>
PROFILE_PRIVATE_SENTINEL
</key>
auth-user-pass
'''
AUTH_USER, AUTH_PASS, PRIVATE_MARKER, PROXY_PASS = 'LAN_LOGIN_SENTINEL', 'LAN_PASSWORD_SENTINEL', 'PRIVATE_OUTPUT_SENTINEL', 'PROXY_PASSWORD_SENTINEL'
VALUES = {'lan-office-ovpn': PROFILE, 'lan-office-auth': json.dumps({'username': AUTH_USER, 'password': AUTH_PASS}),
          'proxy-out-password': PROXY_PASS}


def config():
    return {'kind': 'remoteagents-config', 'schema': 1, 'server': {'login': 'worker'},
            'proxyOut': {'type': 'socks', 'server': '8.8.8.8', 'port': 1080, 'exitIp': '8.8.8.8',
                         'login': 'proxy-user', 'password': {'secret': 'proxy-out-password'}, 'checkUrl': 'https://ip.example.invalid/'},
            'lan': [{'name': 'office', 'kind': 'openvpn', 'ovpn': {'secret': 'lan-office-ovpn'},
                     'auth': {'secret': 'lan-office-auth'}, 'host': '10.123.0.1', 'port': 443,
                     'subnets': ['192.168.87.0/24'], 'directEndpoint': True, 'serverFingerprint': PIN}],
            'telegramGateway': {'enabled': True, 'port': 8444}, 'agent': {'sudo': 'apply'}}


class Fake:
    def __init__(self, root):
        self.root = Path(root)
        self.calls = []
        self.active = {'sing-box', 'ssh.service'}
        self.rules = True
        self.v6 = False
        self.reply_rules = {'-4': [], '-6': []}
        self.nft = {}
        self.tun_default = True
        self.iface = 'enp1s0'
        self.repair = True
        self.exit = '8.8.8.8'
        self.prefs = {}
        self.tg = False
        self.fail = None
        self.write('/etc/os-release', 'ID=debian\nVERSION_CODENAME=bookworm\n')
        self.write('/etc/passwd', 'worker:x:1000:1000::/home/worker:/bin/bash\n')
        self.sb = {'route': {'final': 'proxy-out'}, 'inbounds': [{'type': 'tun', 'auto_route': True, 'interface_name': 'tun0'}],
                   'outbounds': [{'tag': 'proxy-out', 'type': 'socks', 'server': '8.8.8.8', 'server_port': 1080,
                                  'username': 'proxy-user', 'password': PROXY_PASS}]}
        self.write('/etc/sing-box/config.json', json.dumps(self.sb))
        self.system = app.System(root, self.run)

    def path(self, path):
        return self.root / path.lstrip('/')

    def write(self, path, text):
        p = self.path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def read(self, path, default=None):
        p = self.path(path)
        return json.loads(p.read_text()) if p.exists() else default

    def run(self, args, **kw):
        self.calls.append(args)
        out, code = '', 0
        if self.fail and self.fail in args:
            return subprocess.CompletedProcess(args, 1, AUTH_PASS, PRIVATE_MARKER)
        if args[0] == 'jq':
            out = json.dumps({'final': self.sb.get('route', {}).get('final'), 'tun': self.sb.get('inbounds', []),
                              'proxy': [{k: v for k, v in o.items() if k in ('type', 'server', 'server_port')} for o in self.sb['outbounds'] if o.get('tag') == 'proxy-out']})
        elif args[0] == 'python3' and '-c' in args:
            data = json.loads(kw['input'])
            o = self.sb['outbounds'][0]
            code = int(o.get('username', '') != data['username'] or data['check_password'] and o.get('password', '') != data['password'])
        elif args[:2] in (['systemctl', 'is-active'], ['systemctl', 'is-enabled']):
            code = 0 if args[-1] in self.active else 3
        elif args[0] == 'systemctl':
            if args[1] in ('restart', 'start', 'enable'):
                self.active.add(args[-1])
                if args[-1] == 'sing-box' and self.repair:
                    self.rules = True
            elif args[1] in ('disable', 'stop'):
                self.active.discard(args[-1])
        elif args[0] == 'nft':
            if 'list' in args:
                out = self.nft.get(args[-1], '')
                code = 0 if out else 1
            elif '-c' not in args:
                batch = kw['input']
                for name in ('remoteagents_inbound', 'remoteagents_ipv6'):
                    if 'delete table inet ' + name in batch:
                        self.nft.pop(name, None)
                    prefix = 'table inet ' + name + ' {'
                    if prefix in batch:
                        self.nft[name] = batch[batch.index(prefix):]
        elif args[0] == 'ip':
            if 'rule' in args and 'add' in args:
                self.reply_rules[args[1]].append({'priority': 8990, 'table': 'main', 'fwmark': '0x5241'})
            elif 'rule' in args:
                rules = [{'priority': 9000, 'table': 2022}, {'priority': 9001, 'table': 2022, 'suppress_prefixlen': 0},
                         {'priority': 9002, 'table': 'main', 'dport': 53}, {'priority': 9002, 'goto': 9010, 'iif': 'tun0'},
                         {'priority': 9003, 'table': 2022, 'not': None, 'iif': 'lo'},
                         {'priority': 9003, 'table': 2022, 'src': '0.0.0.0'}, {'priority': 9010, 'nop': None}]
                out = json.dumps((rules if self.rules and '-4' in args else []) + self.reply_rules['-6' if '-6' in args else '-4'])
            elif args[-1] == '2022':
                out = json.dumps([{'dst': 'default', 'dev': 'tun0'}] if self.tun_default else [{'dst': '0.0.0.0/1', 'dev': 'tun0'}])
            elif '-6' in args:
                out = json.dumps([{'dst': 'default', 'dev': 'eth0'}] if self.v6 else [])
            else:
                out = json.dumps([{'dev': self.iface, 'table': 254}])
        elif args[0] == '/usr/sbin/sshd' and '-T' in args:
            out = 'logingracetime 30\nmaxstartups 30:30:150\n' if self.path('/etc/ssh/sshd_config.d/10-remoteagents-startups.conf').exists() else 'logingracetime 120\nmaxstartups 10:30:100\n'
        elif args[0] == 'ss':
            out = '0 0 1.1.1.1:22 9.9.9.9:12345\n'
        elif args[0] == 'curl':
            if '--output' in args:
                Path(args[args.index('--output') + 1]).write_bytes(b'OFFICIAL_REPOSITORY_FIXTURE')
            else:
                out = self.exit + '\r\n'
        elif args[0] == 'dpkg-query':
            out = 'install ok installed'
        elif args[0] == 'runuser':
            if any(str(a).endswith('component_files.py') for a in args):
                import subprocess as sp
                if not Path(args[-1]).is_file():
                    return sp.CompletedProcess(args, 127, '', '')
                env = dict(os.environ, HOME=str(self.path('/home/worker')))
                return sp.run(['python3', '-I', str(SOURCE / 'component_files.py')], input=kw['input'], text=True, capture_output=True, env=env)
            if any(str(a).endswith('install.sh') for a in args):
                if '--check' in args:
                    code = 0 if self.tg else 1
                else:
                    self.tg = True
                    self.write('/home/worker/.local/opt/tg-gateway/state/settings.json', json.dumps({'port': 8444}))
                    self.write('/home/worker/.local/opt/tg-gateway/install.sh', '#!/bin/bash\n')
                    self.write('/home/worker/.local/opt/tg-gateway/tls/cert.pem', 'FIXTURE CERT')
                    self.write('/home/worker/.local/opt/tg-gateway/tls/key.pem', 'FIXTURE KEY')
                    self.write('/home/worker/.local/opt/tg-gateway/state/keys.json', '{"version":1,"keys":{}}')
                    out = AUTH_PASS
        elif args[0] == 'bash' and str(args[1]).endswith('lan-vpn.sh'):
            command, name = args[2:4]
            if command == 'add':
                value = Path(args[4]).read_text()
                self.assert_private(args[4])
                auth = json.loads(kw['input'].split(app.MARKER + '\n')[1])
                pin = args[args.index('--server-fingerprint') + 1] if '--server-fingerprint' in args else None
                extra = [args[i+1] for i, a in enumerate(args) if a == '--subnet']
                client, static, gateways = app.lan.import_client(name, None, extra, (auth['username'], auth['password']),
                                    '--direct-endpoint' in args, pin, text=value)
                self.write('/etc/remoteagents/lan/' + name + '/client.conf', client)
                self.write('/etc/remoteagents/lan/' + name + '/config.json', json.dumps({'static': static, 'dns': None,
                    'endpoints': gateways, 'server_fingerprint': pin, 'enabled': True, 'ready': True}))
                self.write('/var/lib/remoteagents/lan/pending/meta.json', json.dumps({'name': name}))
                self.write('/var/lib/remoteagents-status/lan.json', json.dumps([{'name': name, 'enabled': True, 'ready': True, 'ok': False}]))
                self.active.add('remoteagents-lan@' + name + '.service')
            elif command == 'confirm':
                path = '/etc/remoteagents/lan/' + name + '/config.json'
                data = self.read(path)
                data['confirmed_at'] = '2026-11-15'
                self.write(path, json.dumps(data))
                shutil.rmtree(self.path('/var/lib/remoteagents/lan/pending'))
                self.write('/var/lib/remoteagents-status/lan.json', json.dumps([{'name': name, 'enabled': True, 'ready': True, 'ok': True}]))
        elif args[0] == 'bash' and str(args[1]).endswith('proxy-out.sh'):
            if args[2] == 'apply':
                p = self.sb['outbounds'][0]
                p['server'] = args[args.index('--server') + 1]
                p['server_port'] = int(args[args.index('--port') + 1])
                creds = json.loads(kw['input'].split(app.MARKER + '\n')[1])
                p.update(creds)
                self.exit = p['server']
                self.path('/var/lib/remoteagents/proxy-out/pending').mkdir(parents=True)
            elif args[2] in ('confirm', 'rollback'):
                shutil.rmtree(self.path('/var/lib/remoteagents/proxy-out/pending'))
        return subprocess.CompletedProcess(args, code, out, '')

    def assert_private(self, file):
        assert Path(file).stat().st_mode & 0o777 == 0o600

    def engine(self, cfg=None, values=None, **kw):
        self.system.actions.clear()
        return app.Engine(cfg or config(), VALUES if values is None else values, self.system, **kw)

    def complete(self, cfg=None, values=None):
        # The caller establishes a new SSH between apply and confirmation.
        actions = []
        for attempt in range(4):
            result = self.engine(cfg, values, ssh_checked=attempt > 0).run('apply')
            actions.extend(result['actions'])
            if not any(row['state'] == 'pending' for row in result['parts']):
                result['actions'] = actions
                return result
        raise AssertionError('network transaction never completed')


class ApplyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.fake = Fake(self.tmp.name)

    def isolated_components(self, failure, failing_part='happierWeb', command='plan'):
        cfg = {'kind': 'remoteagents-config', 'schema': 1, 'server': {'login': 'worker'},
               'serverComponents': {'happierWeb': {'enabled': True}, 'bridge': {'enabled': True}}}
        engine = self.fake.engine(cfg, {})
        with contextlib.ExitStack() as stack:
            for method, name in (('egress', 'internet'), ('sudo', 'agent'), ('sshd', 'sshd'), ('recovery', 'recovery')):
                stack.enter_context(patch.object(engine, method, side_effect=lambda apply, name=name: engine.row(name, 'ready', 'готово')))
            for method in ('bridge_state', 'bridge', 'happierWeb', 'extras'):
                name = 'bridgeState' if method == 'bridge_state' else method
                def component(e, apply, name=name):
                    if name == failing_part:
                        raise failure
                    return e.row(name, 'ready', 'готово')
                stack.enter_context(patch.object(app.components, method, side_effect=component))
            return engine.run(command)

    def test_happier_web_failures_degrade_without_blocking_critical_parts(self):
        for command in ('plan', 'status', 'apply'):
            for failure in (app.components.Error('web unavailable'), RuntimeError('web exploded')):
                with self.subTest(command=command, failure=type(failure).__name__):
                    result = self.isolated_components(failure, command=command)
                    self.assertTrue(result['ok'], result)
                    self.assertEqual(result['degraded'], ['happierWeb'])
                    web = next(row for row in result['parts'] if row['part'] == 'happierWeb')
                    self.assertTrue(web['optional'])
                    self.assertEqual(web['state'], 'error')
                    self.assertIn('работает частично: happierWeb — ' + web['summary'], result['summary'])
                    for row in result['parts']:
                        if row['part'] != 'happierWeb':
                            self.assertEqual(row['state'], 'ready')
                            self.assertNotIn('optional', row)

    def test_critical_failure_still_fails_server(self):
        result = self.isolated_components(app.components.Error('bridge unavailable'), 'bridge')
        self.assertFalse(result['ok'])
        self.assertEqual(result['degraded'], [])

    def test_optional_change_pending_and_waiting_states(self):
        for state in ('ready', 'change', 'pending', 'waiting', 'blocked', 'error'):
            with self.subTest(state=state):
                engine = self.fake.engine()
                engine.row('internet', 'ready', 'готово')
                engine.row('happierWeb', state, 'web state')
                result = engine.result('plan')
                self.assertTrue(result['ok'])
                self.assertEqual(result['degraded'], [] if state in ('ready', 'change', 'pending') else ['happierWeb'])

    def diagnostic_record(self):
        path = self.fake.path('/var/log/remoteagents/server-apply-errors.log')
        lines = path.read_text().splitlines()
        self.assertEqual(len(lines), 1)
        return path, json.loads(lines[0])

    def test_unknown_exception_is_private_and_identified(self):
        engine = self.fake.engine()
        engine.command = 'status'
        def fail():
            raise RuntimeError('boom token=abcd1234SECRET')
        self.assertFalse(engine.part('probe', fail))
        path, record = self.diagnostic_record()
        self.assertEqual(record['type'], 'RuntimeError')
        self.assertEqual(record['message'], 'boom token=***')
        self.assertEqual((record['mode'], record['part']), ('status', 'probe'))
        self.assertRegex(record['id'], r'^[0-9a-f]{8}$')
        self.assertTrue(record['where'][-1].endswith(':fail'))
        summary = engine.rows[-1]['summary']
        self.assertIn('запись ' + record['id'], summary)
        self.assertNotIn('boom', summary)
        self.assertNotIn('abcd1234SECRET', path.read_text())
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        if os.geteuid() == 0:
            self.assertEqual((path.stat().st_uid, path.stat().st_gid), (0, 0))
            self.assertEqual((path.parent.stat().st_uid, path.parent.stat().st_gid), (0, 0))
        self.assertEqual(self.fake.system.actions, [])

    def test_unknown_exception_survives_unavailable_journal(self):
        self.fake.write('/var/log/remoteagents', 'not a directory')
        engine = self.fake.engine()
        def fail():
            raise RuntimeError('boom')
        self.assertFalse(engine.part('probe', fail))
        self.assertEqual(engine.rows[-1]['state'], 'error')
        self.assertIn('запись ' + engine.rows[-1]['diag']['id'], engine.rows[-1]['summary'])

    def test_part_exception_diag_in_json(self):
        engine = self.fake.engine()
        def fail():
            raise KeyError('x')
        engine.part('probe', fail)
        raw_stdout = json.dumps(engine.result('plan'), ensure_ascii=False)
        row = json.loads(raw_stdout)['parts'][-1]
        self.assertEqual(row['state'], 'error')
        diag = row['diag']
        self.assertEqual(diag['type'], 'KeyError')
        self.assertTrue(diag['where'])
        self.assertRegex(diag['id'], r'^[0-9a-f]{8}$')
        self.assertIn('запись ' + diag['id'], row['summary'])
        _, journal = self.diagnostic_record()
        self.assertEqual({k: journal[k] for k in diag}, diag)
        self.assertTrue(all('/' not in frame for frame in diag['where']))

    def test_part_exception_diag_masks_input_secret(self):
        secret, key = 'S3cr3t-Value-For-Test-123', 'A' * 40
        cfg = config()
        cfg['secrets'] = {'test': secret}
        engine = self.fake.engine(cfg)
        def fail():
            try:
                raise ValueError(secret + ' ' + key)
            except ValueError as cause:
                raise RuntimeError(secret + ' ' + key) from cause
        engine.part('probe', fail)
        raw_stdout = json.dumps(engine.result('plan'), ensure_ascii=False)
        self.assertNotIn(secret, raw_stdout)
        self.assertNotIn(key, raw_stdout)
        self.assertIn('***', raw_stdout)
        self.assertIn('***', engine.rows[-1]['diag']['cause'])

    def test_main_exception_diag_in_json(self):
        cfg = config()
        secret = 'main-test-secret'
        cfg['secrets'] = {'test': secret}
        with patch.object(app.sys, 'stdin', io.StringIO(json.dumps(cfg))), patch.object(app, 'Engine', side_effect=RuntimeError(secret)):
            try:
                app.main(['plan', '--json'], system=self.fake.system)
            except RuntimeError as exc:
                result = app.failure_result(self.fake.system, exc, 'plan')
        out = io.StringIO()
        print(json.dumps(result), file=out)
        self.assertNotIn(secret, out.getvalue())
        result = json.loads(out.getvalue())
        self.assertFalse(result['ok'])
        self.assertIn('error', result)
        self.assertEqual(result['diag']['type'], 'RuntimeError')
        self.assertRegex(result['code']['sha'], r'^[0-9a-f]{12}$')

    def test_sanitized_diag_preserves_actionable_details(self):
        path = '/usr/local/lib/remoteagents/lan_pc_access.py'
        long_message = 'The server could not finish applying the requested configuration because a required helper file is missing. ' * 2
        details = [path, path.lstrip('/'), 'path=' + path, 'server_apply.py:1061:part', 'sha=012345abcdef', long_message]
        try:
            raise RuntimeError('\n'.join(details)) from KeyError('lan_pc_access.py')
        except RuntimeError as exc:
            diag = app.sanitized_diag(exc, 'probe', 'plan')
        self.assertEqual(diag['cause'], "KeyError: 'lan_pc_access.py'")
        for detail in details:
            self.assertIn(detail, diag['message'])
        self.assertTrue(diag['where'])
        self.assertEqual(app.sanitized_diag(RuntimeError('monkey: banana'), 'probe', 'plan')['message'],
                         'monkey: banana')

    def test_sanitized_diag_masks_credentials_and_long_path_segments(self):
        token, password, root_password, short = 'T' * 37, 'fixture-password', 'root-json-password', 'q7Z!'
        export = json.dumps({'root': {'password': root_password}})
        base64 = 'A' * 16 + '/' + 'B' * 16 + '=='
        message = '\n'.join([token, 'password=' + password, export, short, base64,
                             '/usr/' + token + '/lan_pc_access.py'])
        diag = app.sanitized_diag(RuntimeError(message), 'probe', 'plan', [export, short])
        for value in (token, password, root_password, short, base64):
            self.assertNotIn(value, diag['message'])
        self.assertIn('/usr/***/lan_pc_access.py', diag['message'])
        self.assertEqual(app.sanitized_diag(RuntimeError('A' * 31 + '/' + 'B' * 31), 'probe', 'plan')['message'],
                         'A' * 31 + '/' + 'B' * 31)
        self.assertEqual(app.sanitized_diag(RuntimeError('/usr/' + 'A' * 32 + '/file'), 'probe', 'plan')['message'],
                         '/usr/***/file')

    def test_unprintable_exception_keeps_run_result_and_minimal_diag(self):
        class UnprintableError(Exception):
            def __str__(self):
                raise RuntimeError('must not escape diagnostics')
        engine = self.fake.engine()
        with patch.object(engine, 'egress', side_effect=UnprintableError()):
            result = engine.run('plan')
        self.assertFalse(result['ok'])
        row = next(row for row in result['parts'] if row['part'] == 'internet')
        diag = row['diag']
        self.assertEqual(set(diag), {'id', 'part', 'type'})
        self.assertEqual((diag['part'], diag['type']), ('internet', 'UnprintableError'))
        self.assertRegex(diag['id'], r'^[0-9a-f]{8}$')
        self.assertIn('запись ' + diag['id'], row['summary'])
        _, record = self.diagnostic_record()
        self.assertEqual({key: record[key] for key in diag}, diag)
        result = app.failure_result(self.fake.system, UnprintableError(), 'plan')
        self.assertFalse(result['ok'])
        self.assertEqual(set(result['diag']), {'id', 'part', 'type'})
        self.assertEqual(result['diag']['part'], 'main')

    def test_code_version_present(self):
        result = self.fake.engine().result('plan')
        self.assertEqual(result['schema'], 1)
        self.assertRegex(result['code']['sha'], r'^[0-9a-f]{12}$')
        self.assertTrue(result['code']['python'])
        import hashlib
        self.assertEqual(result['code']['sha'], hashlib.sha256((SOURCE / 'server_apply.py').read_bytes()).hexdigest()[:12])

    def test_diag_without_journal(self):
        engine = self.fake.engine()
        def fail():
            raise KeyError('x')
        with patch.object(self.fake.system, 'diag', side_effect=OSError('unavailable')):
            engine.part('probe', fail)
        diag = json.loads(json.dumps(engine.result('plan')))['parts'][-1]['diag']
        self.assertFalse(diag['journal'])
        self.assertRegex(diag['id'], r'^[0-9a-f]{8}$')
        self.assertIn('запись ' + diag['id'], engine.rows[-1]['summary'])

    def test_secrets_from_input_and_cause_are_redacted(self):
        cfg = config()
        cfg['secrets'] = {'config-secret': 'short-secret'}
        relay = {'masterPassword': 'master-value', 'secrets': {'relay-secret': 'relay-value',
                 'json-secret': json.dumps({'password': 'nested-value'})}}
        source = json.dumps(cfg) + '\n' + app.MARKER + '\n' + json.dumps(relay)
        cfg, values = app.read_input('-', io.StringIO(source), diagnostic=self.fake.system)
        engine = self.fake.engine(cfg, values)
        def fail():
            try:
                raise ValueError('short-secret relay-value master-value nested-value')
            except ValueError as exc:
                raise RuntimeError('short-secret relay-value master-value nested-value ' + 'A' * 40 + ' ' + 'x ' * 400) from exc
        engine.part('probe', fail)
        path, record = self.diagnostic_record()
        for value in ('short-secret', 'relay-value', 'master-value', 'nested-value', 'A' * 40):
            self.assertNotIn(value, path.read_text())
        self.assertLessEqual(len(record['message']), 500)
        self.assertIn('ValueError: ***', record['cause'])
        self.assertLessEqual(len(record['where']), 5)

    def test_main_failure_keeps_input_secrets_for_diagnostics(self):
        cfg = config()
        cfg['secrets'] = {'secret': 'main-sentinel'}
        with patch.object(app.sys, 'stdin', io.StringIO(json.dumps(cfg))), patch.object(app, 'Engine', side_effect=RuntimeError('main-sentinel')):
            try:
                app.main(['plan', '--json'], system=self.fake.system)
            except RuntimeError as exc:
                summary = app.hidden_exception(self.fake.system, exc, 'plan', 'main')
        path, record = self.diagnostic_record()
        self.assertEqual((record['part'], record['message']), ('main', '***'))
        self.assertIn('запись ' + record['id'], summary)
        self.assertNotIn('main-sentinel', path.read_text())

    def test_diag_rotation_and_symlink_refusal(self):
        path = self.fake.path('/var/log/remoteagents/server-apply-errors.log')
        self.fake.write('/var/log/remoteagents/server-apply-errors.log', 'x' * (1024 * 1024 + 1))
        self.assertIsNotNone(self.fake.system.diag({'message': 'new'}))
        archive = path.with_name(path.name + '.1')
        self.assertGreater(archive.stat().st_size, 1024 * 1024)
        self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
        path.unlink()
        path.symlink_to(archive)
        self.assertIsNone(self.fake.system.diag({'message': 'refused'}))
        self.assertGreater(archive.stat().st_size, 1024 * 1024)

    def test_real_diag_is_disabled_without_root(self):
        with patch.object(app.os, 'geteuid', return_value=1001), patch.object(app.System, '_journal') as write:
            self.assertIsNone(app.System().diag({'message': 'refused'}))
            write.assert_not_called()

    def test_missing_payload_file_is_a_known_plan_error(self):
        source = Path(self.tmp.name) / 'payload'
        shutil.copytree(SOURCE, source)
        missing = 'lan_pc_access.py'
        (source / missing).unlink()
        self.fake.system.source = source
        result = self.fake.engine().run('plan')
        rows = [row for row in result['parts'] if missing in row['summary']]
        self.assertTrue(rows, result)
        self.assertTrue(all(row['state'] == 'error' for row in rows))
        self.assertNotIn('детали скрыты', json.dumps(result, ensure_ascii=False))

    def test_second_apply_has_zero_actions_and_secret_free_output(self):
        f = self.fake
        with contextlib.redirect_stdout(io.StringIO()) as stdout, contextlib.redirect_stderr(io.StringIO()) as stderr:
            first = f.complete()
            self.assertTrue(first['ok'], first)
            self.assertTrue(first['actions'])
            f.calls.clear()
            second = f.engine(ssh_checked=True).run('apply')
        self.assertTrue(second['ok'], second)
        self.assertEqual(second['actions'], [])
        self.assertFalse(any(c[0] == 'apt-get' or c[:2] == ['systemctl', 'restart'] or c[0] == 'bash' and 'add' in c for c in f.calls))
        captured = json.dumps([first, second, f.calls]) + stdout.getvalue() + stderr.getvalue()
        for p in f.root.rglob('*'):
            if p.is_file() and ('log' in str(p) or 'remoteagents-status' in str(p)):
                captured += p.read_text()
        for secret in (AUTH_USER, AUTH_PASS, PRIVATE_MARKER, PROXY_PASS, PROFILE, 'PROFILE_PRIVATE_SENTINEL'):
            self.assertNotIn(secret, captured)
        self.assertFalse(list(f.path('/run/remoteagents-server-apply').glob('*')))
        for p in f.path('/usr/local/lib/remoteagents/server').rglob('*'):
            self.assertEqual(p.stat().st_mode & 0o022, 0)

    def test_plan_and_status_make_no_changes_even_with_crlf_secrets(self):
        f = self.fake
        before = {str(p): p.read_bytes() for p in f.root.rglob('*') if p.is_file()}
        for command in ('plan', 'status'):
            result = f.engine().run(command)
            self.assertEqual(result['actions'], [])
        after = {str(p): p.read_bytes() for p in f.root.rglob('*') if p.is_file()}
        self.assertEqual(before, after)
        self.assertFalse(any(c[0] in ('apt-get', 'loginctl') or c[:2] in (['systemctl', 'restart'], ['systemctl', 'enable']) for c in f.calls))

    def test_absent_lan_keeps_share_manifest_and_rules(self):
        f = self.fake
        owned = {'/etc/sing-box/config.json': {'rules': [{'inbound': ['channel'], 'ip_cidr': ['192.168.87.0/24'],
                 'action': 'route', 'outbound': 'direct-out'}], 'dns': None, 'createdDns': False}}
        f.write('/etc/remoteagents/server-apply/lan-share.json', json.dumps(owned))
        cfg = config(); cfg.pop('lan')
        before = {str(p): p.read_bytes() for p in f.root.rglob('*') if p.is_file()}
        for command in ('plan', 'status'):
            result = f.engine(cfg).run(command)
            self.assertFalse(any(r['part'] == 'lanShare' for r in result['parts']), result)
            self.assertEqual(result['actions'], [])
        self.assertEqual(before, {str(p): p.read_bytes() for p in f.root.rglob('*') if p.is_file()})
        # An explicit 'lan' still reconciles the share policy.
        explicit = config(); explicit['lan'] = []
        result = f.engine(explicit).run('plan')
        self.assertTrue(any(r['part'] == 'lanShare' for r in result['parts']), result)

    def test_lan_status_explains_corrupt_state_without_contents_or_mutations(self):
        f = self.fake
        self.assertTrue(f.complete()['ok'])
        path = '/etc/remoteagents/lan/office/config.json'
        for value, reason in (('{PRIVATE_SENTINEL', 'неверный JSON/UTF-8'),
                              ('["PRIVATE_SENTINEL"]', 'неверную структуру JSON')):
            with self.subTest(value=value):
                f.write(path, value)
                before = {str(p): p.read_bytes() for p in f.root.rglob('*') if p.is_file()}
                result = f.engine().run('status')
                row = next(r for r in result['parts'] if r['part'] == 'lan:office')
                self.assertEqual(row['state'], 'error')
                self.assertIn(path, row['summary'])
                self.assertIn(reason, row['summary'])
                self.assertNotIn('PRIVATE_SENTINEL', json.dumps(result))
                self.assertEqual(result['actions'], [])
                self.assertEqual(before, {str(p): p.read_bytes() for p in f.root.rglob('*') if p.is_file()})

    def test_no_user_installers_while_lan_waits_for_new_ssh(self):
        f = Fake(self.tmp.name)
        result = f.engine(config()).run('apply')
        self.assertTrue(any(r['state'] == 'pending' and r['part'] == 'lan:office' for r in result['parts']), result)
        self.assertFalse(any(a[0] == 'runuser' for a in f.calls))
        self.assertFalse(f.path('/etc/remoteagents/server-apply/recovery.json').exists())

    def test_disappeared_rules_restart_then_recheck_before_other_parts(self):
        f = self.fake
        f.rules = False
        result = f.complete()
        self.assertTrue(result['ok'], result)
        restart = f.calls.index(['systemctl', 'restart', 'sing-box'])
        lan = next(i for i, c in enumerate(f.calls) if c[0] == 'bash' and 'add' in c)
        self.assertLess(restart, lan)
        self.assertLess(next(i for i, c in enumerate(f.calls) if c[:4] == ['ip', '-4', 'rule', 'add']), restart)
        self.assertTrue(any(c[0] == 'curl' for c in f.calls[restart+1:lan]))

    def test_wrong_exit_blocks_every_other_part(self):
        f = self.fake
        f.exit = '1.1.1.1'
        result = f.engine(ssh_checked=True).run('apply')
        self.assertFalse(result['ok'])
        self.assertEqual(result['actions'], ['nft -f', 'ip -4', 'nft -f', 'systemctl restart'])
        self.assertTrue(all(r['state'] == 'blocked' for r in result['parts']))
        self.assertFalse(f.path('/etc/sudoers.d').exists())

    def test_ipv6_unspecified_defaults_to_block(self):
        f = self.fake
        f.v6 = True
        result = f.complete()
        self.assertTrue(result['ok'], result)
        row = next(r for r in result['parts'] if r['part'] == 'ipv6')
        self.assertEqual(row['state'], 'ready')
        self.assertIn('remoteagents_ipv6', f.nft)
        self.assertNotIn(['systemctl', 'restart', 'sing-box'], f.calls)

    def test_ipv6_block_allow_and_unset_preserves_existing_policy(self):
        f = self.fake
        cfg = config(); cfg['proxyOut']['ipv6'] = 'block'
        self.assertTrue(f.complete(cfg)['ok'])
        rules = f.nft['remoteagents_ipv6']
        self.assertIn('ct direction reply ct state established,related accept', rules)
        self.assertNotIn('echo-request', rules)
        for value in ('packet-too-big', 'nd-neighbor-solicit', 'nd-neighbor-advert', 'meta nfproto ipv6 drop'):
            self.assertIn(value, rules)
        self.assertEqual(f.engine(cfg, ssh_checked=True).run('apply')['actions'], [])
        self.assertTrue(f.engine(ssh_checked=True).run('apply')['ok'])
        self.assertIn('remoteagents_ipv6', f.nft)
        cfg['proxyOut']['ipv6'] = 'allow'
        self.assertTrue(f.engine(cfg, ssh_checked=True).run('apply')['ok'])
        self.assertNotIn('remoteagents_ipv6', f.nft)
        self.assertEqual(f.engine(cfg, ssh_checked=True).run('apply')['actions'], [])
        cfg['proxyOut']['ipv6'] = 'invalid'
        with self.assertRaises(app.Error):
            app.validate(cfg)

    def test_split_table_plan_status_watch_report_without_singbox_restart(self):
        f = self.fake
        self.assertTrue(f.complete()['ok'])
        f.tun_default = False
        for cmd in ('plan', 'status'):
            result = f.engine().run(cmd)
            self.assertIn(app.INBOUND_WARNING, json.dumps(result, ensure_ascii=False))
            self.assertEqual(result['actions'], [])
        self.assertTrue(app.egress_watch(f.engine()))
        state = f.read('/var/lib/remoteagents-status/egress.json')
        self.assertIn('без default', state['summary'])
        self.assertTrue(any(app.INBOUND_WARNING in ' '.join(c) for c in f.calls if c[0] == 'logger'))
        self.assertNotIn(['systemctl', 'restart', 'sing-box'], f.calls)

    def test_manual_patch_is_adopted_and_watch_repairs_only_own_guard(self):
        f = self.fake
        manual = app.inbound_nft(f.iface).replace('0x5241', '0x00005241')
        f.nft['remoteagents_ipv6'] = app.ipv6_nft()
        f.nft['remoteagents_inbound'] = manual
        f.reply_rules['-4'] = [{'priority': 8990, 'table': 254, 'src': 'all', 'fwmark': '0x5241'}]
        self.assertTrue(f.complete()['ok'])
        self.assertEqual(f.nft['remoteagents_inbound'], manual)
        self.assertFalse(any(c[0] == 'nft' and '-f' in c for c in f.calls))
        self.assertEqual(len(f.reply_rules['-4']), 1)
        self.assertEqual(f.engine(ssh_checked=True).run('apply')['actions'], [])
        f.nft.clear(); f.reply_rules['-4'].clear(); f.tun_default = False
        result = f.engine().run('plan')
        self.assertIn(app.INBOUND_WARNING, json.dumps(result, ensure_ascii=False))
        f.calls.clear()
        self.assertTrue(app.egress_watch(f.engine()))
        self.assertIn(f.iface, f.nft['remoteagents_inbound'])
        self.assertNotIn(['systemctl', 'restart', 'sing-box'], f.calls)
        self.assertEqual(len(f.reply_rules['-4']), 1)
        unit = f.path('/etc/systemd/system/remoteagents-network-guard.service').read_text()
        self.assertIn('Before=sing-box.service', unit)
        self.assertIn('_network-guard --config', unit)

    def test_ipv6_kernel_pretty_print_does_not_trigger_another_apply(self):
        f = self.fake
        cfg = config(); cfg['proxyOut']['ipv6'] = 'block'
        self.assertTrue(f.complete(cfg)['ok'])
        rendered = f.nft['remoteagents_ipv6'].replace('ct state established,related', 'ct state { related, established }')
        original = 'destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert'
        rendered = rendered.replace(original, ', '.join(reversed(original.split(', '))))
        f.nft['remoteagents_ipv6'] = rendered
        self.assertEqual(f.engine(cfg, ssh_checked=True).run('apply')['actions'], [])

    def test_watch_restores_ipv6_block_and_tracks_changed_default_interface(self):
        f = self.fake
        cfg = config(); cfg['proxyOut']['ipv6'] = 'block'
        self.assertTrue(f.complete(cfg)['ok'])
        del f.nft['remoteagents_ipv6']
        f.iface = 'ens9'
        f.calls.clear()
        self.assertTrue(app.egress_watch(f.engine(cfg)))
        self.assertIn('ens9', f.nft['remoteagents_inbound'])
        self.assertIn('remoteagents_ipv6', f.nft)
        self.assertNotIn(['systemctl', 'restart', 'sing-box'], f.calls)

    def test_conflicting_reply_priority_stops_apply_without_deleting_foreign_rule(self):
        f = self.fake
        f.reply_rules['-4'] = [{'priority': 8990, 'fwmark': '0x1234', 'table': 'main'}]
        result = f.engine().run('apply')
        self.assertFalse(result['ok'])
        self.assertIn('8990', result['parts'][0]['summary'])
        self.assertFalse(any(c[0] in ('bash', 'apt-get') or 'del' in c for c in f.calls))

    def test_partial_rule_loss_is_detected_even_if_all_priorities_exist(self):
        f = self.fake
        runner = f.system.runner
        def missing_one_rule(args, **kw):
            result = runner(args, **kw)
            if args[0] == 'ip' and 'rule' in args and 'show' in args:
                result.stdout = json.dumps([r for r in json.loads(result.stdout) if not r.get('goto')])
            return result
        f.system.runner = missing_one_rule
        result = f.engine(ssh_checked=True).run('apply')
        self.assertFalse(result['ok'])
        self.assertEqual(result['actions'], ['nft -f', 'ip -4', 'nft -f', 'systemctl restart'])

    def test_failed_repair_stays_blocked(self):
        f = self.fake
        f.rules, f.repair = False, False
        result = f.engine(ssh_checked=True).run('apply')
        self.assertEqual(result['actions'], ['nft -f', 'ip -4', 'nft -f', 'systemctl restart'])
        self.assertFalse(result['ok'])

    def test_proxy_change_uses_existing_manager_and_waits_for_new_ssh(self):
        f = self.fake
        cfg = config()
        cfg['proxyOut'].update(server='1.1.1.1', exitIp='1.1.1.1')
        first = f.engine(cfg, ssh_checked=True).run('apply')
        self.assertEqual(first['parts'][0]['state'], 'pending')
        self.assertTrue(all(r['state'] == 'blocked' for r in first['parts'][1:]))
        self.assertFalse(any(c[0] == 'bash' and 'confirm' in c for c in f.calls))
        self.assertTrue(f.complete(cfg)['ok'])
        proxy_calls = [c for c in f.calls if c[0] == 'bash' and str(c[1]).endswith('proxy-out.sh')]
        self.assertEqual([c[2] for c in proxy_calls], ['apply', 'confirm'])
        final = f.engine(cfg, ssh_checked=True).run('apply')
        self.assertTrue(final['ok'], final)
        self.assertEqual(final['actions'], [])

    def test_proxy_exit_different_from_master_expectation_rolls_back(self):
        f = self.fake
        cfg = config(); cfg['proxyOut'].update(server='1.1.1.1', exitIp='9.9.9.9')
        result = f.engine(cfg).run('apply')
        self.assertFalse(result['ok'])
        self.assertTrue(any(c[0] == 'bash' and 'rollback' in c for c in f.calls))
        self.assertFalse(any(c[0] == 'apt-get' for c in f.calls))

    def test_new_fingerprint_replaces_profile(self):
        f = self.fake
        self.assertTrue(f.complete()['ok'])
        cfg = config()
        cfg['lan'][0]['serverFingerprint'] = ':'.join(['CD'] * 32)
        f.calls.clear()
        result = f.complete(cfg)
        self.assertTrue(result['ok'], result)
        additions = [c for c in f.calls if c[0] == 'bash' and 'add' in c]
        self.assertEqual(len(additions), 1)
        self.assertIn('--replace', additions[0])
        self.assertIn(cfg['lan'][0]['serverFingerprint'], additions[0])

    def test_changed_credentials_are_not_hidden_by_receipt(self):
        f = self.fake
        self.assertTrue(f.complete()['ok'])
        values = dict(VALUES)
        values['lan-office-auth'] = json.dumps({'username': AUTH_USER, 'password': 'NEW_PRIVATE_PASSWORD'})
        result = f.engine(values=values).run('plan')
        self.assertEqual(next(r for r in result['parts'] if r['part'] == 'lan:office')['state'], 'change')
        self.assertNotIn('NEW_PRIVATE_PASSWORD', json.dumps(result))

    def test_missing_lan_secret_does_not_block_sudo(self):
        f = self.fake
        values = dict(VALUES)
        del values['lan-office-ovpn']
        result = f.engine(values=values, ssh_checked=True).run('apply')
        row = next(r for r in result['parts'] if r['part'] == 'lan:office')
        self.assertEqual(row['missing'], ['lan-office-ovpn'])
        self.assertTrue(f.path('/etc/sudoers.d/91-remoteagents-apply').exists())

    def test_public_export_does_not_claim_private_profile_hash_was_checked(self):
        f = self.fake
        self.assertTrue(f.complete()['ok'])
        result = f.engine(values={}).run('apply')
        row = next(r for r in result['parts'] if r['part'] == 'lan:office')
        self.assertEqual(row['state'], 'waiting')
        self.assertEqual(row['missing'], ['lan-office-ovpn'])
        self.assertEqual(result['actions'], [])

    def test_part_failure_does_not_block_sudo(self):
        f = self.fake
        f.fail = 'loginctl'
        result = f.complete()
        self.assertEqual(next(r for r in result['parts'] if r['part'] == 'telegramGateway')['state'], 'error')
        self.assertTrue(f.path('/etc/sudoers.d/91-remoteagents-apply').exists())
        for secret in (AUTH_PASS, PRIVATE_MARKER):
            self.assertNotIn(secret, json.dumps(result))

    def test_no_ssh_ack_keeps_rollback_then_confirm_on_next_call(self):
        f = self.fake
        result = f.engine().run('apply')
        self.assertFalse(result['ok'])
        self.assertTrue(f.path('/var/lib/remoteagents/lan/pending').exists())
        f.calls.clear()
        result = f.engine(ssh_checked=True).run('apply')
        self.assertTrue(result['ok'], result)
        self.assertFalse(f.path('/var/lib/remoteagents/lan/pending').exists())
        self.assertFalse(any('add' in c for c in f.calls))

    def test_ssh_flag_on_initial_apply_does_not_confirm_future_network_change(self):
        f = self.fake
        result = f.engine(ssh_checked=True).run('apply')
        self.assertTrue(any(r['state'] == 'pending' for r in result['parts']))
        self.assertTrue(f.path('/var/lib/remoteagents/lan/pending').exists())
        self.assertFalse(any(c[0] == 'bash' and 'confirm' in c for c in f.calls))

    def test_ssh_route_into_lan_never_confirms(self):
        original = self.fake.system.runner
        def bad_route(args, **kw):
            if args[0] == 'ip' and 'get' in args:
                return subprocess.CompletedProcess(args, 0, '[{"dev":"tun-lan-office","table":42000}]', '')
            return original(args, **kw)
        self.fake.system.runner = bad_route
        result = self.fake.engine(ssh_checked=True).run('apply')
        self.assertTrue(self.fake.path('/var/lib/remoteagents/lan/pending').exists())
        self.assertEqual(next(r for r in result['parts'] if r['part'] == 'lan:office')['state'], 'error')

    def test_ssh_route_checks_both_families_and_accepts_named_main(self):
        f = self.fake
        original = f.system.runner
        def replies(args, **kw):
            if args[0] == 'ss':
                return subprocess.CompletedProcess(args, 0, '0 0 1.1.1.1:22 9.9.9.9:1234\n0 0 [::1]:22 [2001:db8::1]:1234\n', '')
            if args[0] == 'ip' and 'get' in args:
                f.calls.append(args)
                return subprocess.CompletedProcess(args, 0, '[{"dev":"eth0","table":"main"}]', '')
            return original(args, **kw)
        f.system.runner = replies
        f.engine().check_ssh('office')
        self.assertTrue(any('-4' in c and 'get' in c for c in f.calls))
        self.assertTrue(any('-6' in c and 'get' in c for c in f.calls))



    def test_watch_repair_and_loud_persistent_failure(self):
        f = self.fake
        f.rules = False
        self.assertTrue(app.egress_watch(f.engine()))
        self.assertTrue(f.read('/var/lib/remoteagents-status/egress.json')['repaired'])
        f.rules, f.repair = False, False
        self.assertFalse(app.egress_watch(f.engine()))
        self.assertFalse(f.read('/var/lib/remoteagents-status/egress.json')['ok'])
        self.assertTrue(any('daemon.crit' in c for c in f.calls))
        result = f.engine().run('status')
        self.assertIn('ВНИМАНИЕ', next(r for r in result['parts'] if r['part'] == 'egressWatch')['summary'])

    def test_sudo_default_never_removes_existing_full_rights(self):
        f = self.fake
        f.write('/etc/sudoers.d/90-remoteagents', 'worker ALL=(ALL) NOPASSWD: ALL\n')
        cfg = config(); del cfg['agent']
        result = f.engine(cfg, ssh_checked=True).run('apply')
        self.assertEqual(next(r for r in result['parts'] if r['part'] == 'agent')['state'], 'blocked')
        self.assertTrue(f.path('/etc/sudoers.d/90-remoteagents').exists())
        cfg['agent'] = {'sudo': 'none'}
        f.engine(cfg, ssh_checked=True).run('apply')
        self.assertFalse(f.path('/etc/sudoers.d/90-remoteagents').exists())

    def test_generated_sudoers_passes_real_visudo(self):
        binary = shutil.which('visudo') or ('/usr/sbin/visudo' if Path('/usr/sbin/visudo').exists() else None)
        if not binary:
            self.skipTest('visudo не установлен; проверка синтаксиса пропущена')
        f = self.fake
        self.assertTrue(f.complete()['ok'])
        result = subprocess.run([binary, '-cf', str(f.path('/etc/sudoers.d/91-remoteagents-apply'))], capture_output=True)
        self.assertEqual(result.returncode, 0)

    def test_clean_vps_is_explicitly_blocked_without_mutations(self):
        f = self.fake
        f.sb['inbounds'] = []
        result = f.engine().run('apply')
        self.assertFalse(result['ok'])
        self.assertEqual(result['actions'], [])
        self.assertIn('нужен базовый', result['parts'][0]['summary'])

    def test_public_audit_never_opens_lan_private_files(self):
        f = self.fake
        f.write('/var/lib/remoteagents-status/lan.json', '[{"name":"office","enabled":true,"ready":true}]')
        f.active.add('remoteagents-lan@office.service')
        result = f.engine(values={}, public_only=True).run('plan')
        row = next(r for r in result['parts'] if r['part'] == 'lan:office')
        self.assertEqual(row['state'], 'ready')
        self.assertIn('не сравнены', row['summary'])
        self.assertEqual(result['actions'], [])



class InputTests(unittest.TestCase):
    def test_legacy_tailscale_is_ignored(self):
        cfg = config()
        cfg['tailscale'] = {'enabled': True, 'userspace': False, 'authKey': {'secret': 'old-key'}}
        parsed, values = app.read_input('-', io.StringIO(json.dumps(cfg)))
        self.assertNotIn('tailscale', parsed)
        self.assertEqual(values, {})
        with tempfile.TemporaryDirectory() as root:
            self.assertNotIn('tailscale', app.Engine(cfg, system=Fake(root).system).config)

    def test_full_export_crlf_and_marker_relay(self):
        cfg = config(); cfg['secrets'] = VALUES
        text = json.dumps(cfg, ensure_ascii=False, indent=2).replace('\n', '\r\n')
        parsed, values = app.read_input('-', io.StringIO('\ufeff' + text))
        self.assertEqual(values, VALUES)
        # A leftover sudo-password line is allowed only with a separate file.
        with tempfile.TemporaryDirectory() as root:
            file = Path(root) / 'public.json'; file.write_text(json.dumps(config()))
            parsed, values = app.read_input(str(file), io.StringIO('UNUSED_SUDO_LINE\r\n' + app.MARKER + '\r\n' + json.dumps(VALUES)), True)
            self.assertEqual(values, VALUES)

    def test_enc1_uses_existing_crypto_and_master_relay(self):
        cfg = config(); cfg['secrets'] = app.config_crypto.protect(VALUES, 'MASTER_SENTINEL')
        data = json.dumps(cfg) + '\r\n' + app.MARKER + '\r\n' + json.dumps({'masterPassword': 'MASTER_SENTINEL'})
        parsed, values = app.read_input('-', io.StringIO(data))
        self.assertEqual(values, VALUES)
        with self.assertRaises(app.Error) as error:
            app.read_input('-', io.StringIO(data.replace('MASTER_SENTINEL', 'WRONG_MASTER_SENTINEL')))
        self.assertNotIn('MASTER_SENTINEL', str(error.exception))

    def test_invalid_inputs_are_rejected_without_secret_context(self):
        for text in ('{"kind":"remoteagents-config","schema":1,"schema":1}',
                     '{"kind":"remoteagents-config","schema":1,"agent":{"sudo":"bad"}}',
                     '{"kind":"remoteagents-config","schema":1,"unknown":true}'):
            with self.subTest(text=text), self.assertRaises(app.Error):
                app.read_input('-', io.StringIO(text))
        app.validate(config())

    def test_allowed_wrapper_resolves_symlinks_to_trusted_code(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root)
            (path / 'server-apply.sh').symlink_to(SOURCE / 'server-apply.sh')
            (path / 'server_apply.py').write_text('print("UNTRUSTED_CODE_SENTINEL")')
            result = subprocess.run(['bash', str(path / 'server-apply.sh'), '--help'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            self.assertNotIn('UNTRUSTED_CODE_SENTINEL', result.stdout + result.stderr)

    def test_limited_sudo_cannot_grant_full_rights(self):
        cfg = config(); cfg['agent']['sudo'] = 'full'
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'config.json'; path.write_text(json.dumps(cfg))
            with patch.object(app, 'delegated', return_value=True), patch.object(app.os, 'geteuid', return_value=0), \
                 patch.dict(os.environ, {'SUDO_USER': 'worker'}):
                with self.assertRaises(app.Error):
                    app.main(['apply', '--config', str(path)])

    def test_ca_pin_is_proposed_but_never_accepted(self):
        with tempfile.TemporaryDirectory() as root:
            f = Fake(root)
            cfg = config(); cfg['lan'][0].pop('serverFingerprint')
            original = f.system.runner
            def openssl(args, **kw):
                if args[0] == 'openssl':
                    return subprocess.CompletedProcess(args, 0, 'sha256 Fingerprint=' + PIN, '')
                return original(args, **kw)
            f.system.runner = openssl
            values = dict(VALUES)
            values['lan-office-ovpn'] = PROFILE.replace('TEST_CA_NO_SECRET', '-----BEGIN CERTIFICATE-----\nSYNTHETIC\n-----END CERTIFICATE-----')
            for command in ('plan', 'apply'):
                result = f.engine(cfg, values, ssh_checked=True).run(command)
                row = next(r for r in result['parts'] if r['part'] == 'lan:office')
                self.assertEqual(row['state'], 'blocked')
                self.assertEqual(row['serverFingerprint'], PIN)
            self.assertFalse(any(c[0] == 'bash' and 'add' in c for c in f.calls))


if __name__ == '__main__':
    unittest.main()
