#!/usr/bin/env python3
"""Real Ubuntu/systemd/sshd/sing-box/OpenVPN, synthetic credentials, mock Tailscale.

Requires Docker via sudo and network for signed Ubuntu/SagerNet packages. Only
container namespaces are modified. The repository mount is read-only. Every
container, test network, test image and private temporary file is cleaned up.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
PWSH = os.environ.get('PWSH', str(Path.home() / '.cache/pwsh-test/pwsh'))
PREFIX = 'ra-apply-' + uuid.uuid4().hex[:10]
containers = []


def redact(text):
    for secret in ('ROOT_FIXTURE_SENTINEL', 'PROXY_SENTINEL', 'LAN_SENTINEL', 'TS_SENTINEL',
                   'CLAUDE_FIXTURE_SENTINEL', 'CODEX_FIXTURE_SENTINEL', 'HAPPY_FIXTURE_SENTINEL'):
        text = text.replace(secret, '<redacted>')
    return text


def call(args, input=None, check=True, timeout=600, env=None):
    r = subprocess.run([str(a) for a in args], input=input, text=True, capture_output=True, timeout=timeout, env=env)
    if check and r.returncode:
        # Do not dump stdin, credentials, private key or subprocess traces.
        detail = redact(r.stderr[-2500:])
        raise AssertionError('Stand command failed: ' + str(args[0]) + ' (code ' + str(r.returncode) + '): ' + detail)
    return r


def docker(*args, **kw):
    return call(['sudo', '-n', 'docker', *args], **kw)


def inside(name, *args, **kw):
    return docker('exec', '-i', name, *args, **kw)


def put(name, path, data, mode='600'):
    # Paths/modes are fixture constants; data is always stdin.
    inside(name, 'bash', '-c', 'cat > ' + path + '; chmod ' + mode + ' ' + path, input=data)


def new_vps(label, temp, gateway):
    name = PREFIX + '-' + label
    docker('run', '-d', '--name', name, '--privileged', '--cgroupns=private', '--tmpfs', '/run',
           '--tmpfs', '/run/lock', '--network', PREFIX, '--mount', 'type=bind,src=' + str(REPO) + ',dst=/src,readonly', PREFIX)
    containers.append(name)
    for _ in range(100):
        if inside(name, 'systemctl', 'is-system-running', check=False).stdout.strip() in ('running', 'degraded'):
            break
        time.sleep(.2)
    inside(name, 'systemctl', 'start', 'ssh')
    inside(name, 'chpasswd', input='root:ROOT_FIXTURE_SENTINEL\n')
    put(name, '/etc/ssh/sshd_config.d/01-fixture.conf', 'PermitRootLogin yes\nPasswordAuthentication yes\n', '644')
    inside(name, 'systemctl', 'restart', 'ssh')
    inside(name, 'mkdir', '-p', '/root/.ssh')
    put(name, '/root/.ssh/authorized_keys', (temp / 'key.pub').read_text())
    inside(name, 'chmod', '700', '/root/.ssh')
    home = temp / label
    home.mkdir()
    address = inside(name, 'hostname', '-I').stdout.split()[0]
    known = home / 'known_hosts'
    known.write_text(address + ' ' + inside(name, 'cat', '/etc/ssh/ssh_host_ed25519_key.pub').stdout)
    sshconf = home / 'ssh.conf'; sshconf.write_text('Host *\n  BatchMode yes\n  StrictHostKeyChecking yes\n')
    askpass = home / 'askpass'
    askpass.write_text('#!/bin/sh\nprintf %s ROOT_FIXTURE_SENTINEL\n'); askpass.chmod(0o700)
    boot = call([PWSH, '-NoProfile', '-NonInteractive', '-File', HERE / 'bootstrap.ps1',
                 '-Address', address, '-Key', temp / 'key', '-Known', known, '-Config', sshconf,
                 '-Askpass', askpass, '-Bundle', REPO], input='http://fixture:PROXY_SENTINEL@' + inside(gateway, 'hostname', '-I').stdout.split()[0] + ':3128', timeout=900)
    assert boot.stdout.strip() == 'bootstrap-ready'
    assert 'HTTP bootstrap/package' in inside(gateway, 'cat', '/run/proxy-connections').stdout
    print('PASS: actual production root-password login, OS dependencies and worker-key bootstrap', flush=True)
    docker('cp', temp / 'origin.crt', name + ':/usr/local/share/ca-certificates/ra-fixture.crt')
    inside(name, 'update-ca-certificates')
    gateway_ip = inside(gateway, 'hostname', '-I').stdout.split()[0]
    # A late fixture route reaches the oracle only when TUN is stopped. Unlike
    # a host route in main it cannot accidentally bypass sing-box rule 9002.
    inside(name, 'ip', 'route', 'add', 'table', '500', '11.123.45.67/32', 'via', gateway_ip, 'dev', 'eth0')
    inside(name, 'ip', 'rule', 'add', 'pref', '32000', 'to', '11.123.45.67/32', 'lookup', '500')
    inside(name, 'ip', 'route', 'add', '11.123.45.68/32', 'via', gateway_ip, 'dev', 'eth0')
    put(name, '/etc/systemd/system/fixture-topology.service', '[Unit]\nAfter=network.target\nBefore=remoteagents-reconcile.service\n[Service]\nType=oneshot\nExecStart=/usr/sbin/ip route replace 11.123.45.68/32 via ' + gateway_ip + ' dev eth0\n[Install]\nWantedBy=multi-user.target\n', '644')
    inside(name, 'systemctl', 'daemon-reload')
    inside(name, 'systemctl', 'enable', 'fixture-topology.service')
    # Tailscale is the only mocked service/package; its CLI checks the auth-key
    # file and userspace flags, and refuses route/DNS acceptance.
    docker('cp', HERE / 'tailscale_mock.py', name + ':/usr/local/bin/tailscale')
    inside(name, 'chmod', '755', '/usr/local/bin/tailscale')
    inside(name, 'mkdir', '-p', '/run/ts/DEBIAN')
    put(name, '/run/ts/DEBIAN/control', 'Package: tailscale\nVersion: 0.0.0\nArchitecture: all\nMaintainer: Stand\nDescription: fixture\n')
    inside(name, 'dpkg-deb', '--build', '/run/ts', '/run/tailscale.deb')
    inside(name, 'dpkg', '-i', '/run/tailscale.deb')
    put(name, '/etc/systemd/system/tailscaled.service', '[Service]\nExecStart=/bin/sleep infinity\n[Install]\nWantedBy=multi-user.target\n', '644')
    inside(name, 'systemctl', 'daemon-reload')
    profile = home / 'profile.json'
    profile.write_text(json.dumps(dict(sshExecutable='/usr/bin/ssh', serverAddress=address, login='remoteagents',
                                      keyPath=str(temp / 'key'), knownHostsPath=str(known), configPath=str(sshconf),
                                      arguments=['-F', str(sshconf), '-l', 'remoteagents', '-i', str(temp / 'key'), '-o', 'IdentitiesOnly=yes',
                                                 '-o', 'UserKnownHostsFile=' + str(known), '-o', 'GlobalKnownHostsFile=none',
                                                 '-o', 'StrictHostKeyChecking=yes', '-o', 'BatchMode=yes', '-T', address])))
    (home / 'config.json').write_text(json.dumps(dict(schema=1, version=1, transport=dict(profilePath=str(profile)), components={})))
    # Deny direct oracle access: a successful IP probe must use CONNECT.
    inside(gateway, 'nft', 'add', 'rule', 'inet', 'fixture', 'input', 'ip', 'saddr', address, 'tcp', 'dport', '8443', 'reject')
    return name, home, address


def verify_managed_user(name):
    public = inside(name, 'cat', '/root/.ssh/authorized_keys').stdout.strip().splitlines()[0]
    command = 'IFS= read -r ra_user; IFS= read -r ra_key; export ra_user ra_key; exec bash /src/build/server-ssh-user.sh'
    payload = 'remoteagents\n' + public + '\n'
    inside(name, 'bash', '-c', command, input=payload)
    marker = '/var/lib/remote-agents/managed-user-v1'
    assert inside(name, 'cat', marker).stdout.strip() == 'remoteagents:/home/remoteagents:v1'
    assert inside(name, 'stat', '-c', '%u:%g:%a', marker).stdout.strip() == '0:0:644'
    before = inside(name, 'cat', '/home/remoteagents/.ssh/authorized_keys').stdout
    inside(name, 'bash', '-c', command, input=payload)
    assert inside(name, 'cat', '/home/remoteagents/.ssh/authorized_keys').stdout == before
    print('PASS: production canonical managed-user marker and repeated key bootstrap', flush=True)


def engine(home, config, values, status=False):
    payload = json.dumps(config) + '\r\n---remoteagents-stdin---\r\n' + json.dumps(values) + '\r\n'
    args = [PWSH, '-NoProfile', '-NonInteractive', '-File', REPO / 'build/ServerApply.ps1', '-HomePath', home, '-PasswordPipe', 'synthetic-fixture', '-AskpassExecutable', home / 'askpass']
    if status:
        args.append('-StatusOnly')
    result = call(args, input=payload, check=False, timeout=900)
    report = json.loads(result.stdout)
    assert all(s not in result.stdout + result.stderr for s in ('PROXY_SENTINEL', 'LAN_SENTINEL', 'TS_SENTINEL', 'CLAUDE_FIXTURE_SENTINEL', 'CODEX_FIXTURE_SENTINEL', 'HAPPY_FIXTURE_SENTINEL', 'BEGIN PRIVATE KEY'))
    return report


def happier_fixture(name):
    inside(name, 'runuser', '-u', 'remoteagents', '--', 'mkdir', '-p', '/home/remoteagents/.local/bin')
    inside(name, 'runuser', '-u', 'remoteagents', '--', 'rm', '-f', '/home/remoteagents/.local/bin/happier')
    inside(name, 'runuser', '-u', 'remoteagents', '--', 'python3', '-c',
           'from pathlib import Path; import sys; p=Path.home()/".local/bin/happier"; p.write_text(sys.stdin.read()); p.chmod(0o700)',
           input=(HERE / 'happier_daemon_fixture.py').read_text())


def device_id(name):
    return json.loads(inside(name, 'runuser', '-u', 'remoteagents', '--', 'bash',
                      '/home/remoteagents/.local/share/remote-disk/server-disk.sh', 'bootstrap').stdout)['deviceId']


def main(temp):
    docker('build', '--target', 'vps', '-t', PREFIX, HERE)
    docker('build', '--target', 'fixture', '-t', PREFIX + '-fixture', HERE)
    docker('network', 'create', PREFIX)
    gateway = PREFIX + '-gateway'
    docker('run', '-d', '--name', gateway, '--network', PREFIX, '--cap-add', 'NET_ADMIN', '--device', '/dev/net/tun',
           '--mount', 'type=bind,src=' + str(HERE) + ',dst=/fixture,readonly', PREFIX + '-fixture', '/bin/sleep', 'infinity')
    containers.append(gateway)
    for ip in ('11.123.45.67', '11.123.45.68'):
        inside(gateway, 'ip', 'addr', 'add', ip + '/32', 'dev', 'eth0')
    for label, extra in [('origin', ['-addext', 'subjectAltName=IP:11.123.45.67']), ('gateway', [])]:
        call(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-subj', '/CN=ra-fixture-' + label,
              '-keyout', temp / (label + '.key'), '-out', temp / (label + '.crt'), *extra])
        for ext in ('key', 'crt'):
            docker('cp', temp / (label + '.' + ext), gateway + ':/run/' + label + '.' + ext)
    cert_info = call(['openssl', 'x509', '-in', temp / 'gateway.crt', '-noout', '-ext', 'keyUsage']).stdout
    assert 'X509v3 Key Usage' not in cert_info
    pin = call(['openssl', 'x509', '-in', temp / 'gateway.crt', '-noout', '-fingerprint', '-sha256']).stdout.strip().split('=')[1]
    inside(gateway, 'nft', 'add', 'table', 'inet', 'fixture')
    inside(gateway, 'nft', 'add', 'chain', 'inet', 'fixture', 'input', '{ type filter hook input priority 0; policy accept; }')
    put(gateway, '/run/check-auth', '#!/bin/sh\n[ "$username" = fixture ] && [ "$password" = LAN_SENTINEL ]\n', '700')
    put(gateway, '/run/openvpn.conf', '''port 1194
proto tcp-server
dev tun0
server 10.123.0.0 255.255.255.0
topology subnet
ca /run/gateway.crt
cert /run/gateway.crt
key /run/gateway.key
dh none
verify-client-cert none
username-as-common-name
script-security 3
auth-user-pass-verify /run/check-auth via-env
push "route 10.123.0.0 255.255.255.0"
push "route 8.8.4.0 255.255.255.0"
push "redirect-gateway def1"
keepalive 10 60
verb 3
''')
    inside(gateway, 'openvpn', '--config', '/run/openvpn.conf', '--daemon', '--log', '/run/openvpn.log')
    docker('exec', '-d', gateway, 'python3', '/fixture/fixture.py')
    call(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', temp / 'key'])
    target, home, address = new_vps('vps', temp, gateway)
    # A real, disposable server-side bridge SSH identity must survive repair
    # and migration too. No Windows bridge or external computer is contacted.
    inside(target, 'runuser', '-u', 'remoteagents', '--', 'ssh-keygen', '-q', '-t', 'ed25519',
           '-N', '', '-f', '/home/remoteagents/.ssh/id_ed25519')
    gateway_ip = inside(gateway, 'hostname', '-I').stdout.split()[0]
    profile = 'client\nremote 11.123.45.68 1194 tcp-client\nnobind\nauth-user-pass\n<ca>\n' + (temp / 'gateway.crt').read_text() + '</ca>\n'
    config = dict(kind='remoteagents-config', schema=1, server=dict(address=address, login='remoteagents'),
                  serverNetwork=dict(enabled=True, tunAddress='172.30.250.1/30', inboundPorts=[22, 443, 37091], inbounds={'secret': 'server-inbounds'}),
                  proxyOut=dict(type='http', server=gateway_ip, port=3128, login='fixture', password={'secret': 'proxy-pass'},
                                exitIp='8.8.8.8', checkUrl='https://11.123.45.67:8443', ipv6='block'),
                  lan=[dict(name='clinic', kind='openvpn', ovpn={'secret': 'clinic-ovpn'}, auth={'secret': 'clinic-auth'},
                            serverFingerprint=pin, subnets=['10.123.0.0/24'], directEndpoint=True, testHost='10.123.0.1', testPort=1194)],
                  tailscale=dict(enabled=True, userspace=True, authKey={'secret': 'ts-auth'}, hostname='fixture'),
                  telegramGateway=dict(enabled=True, port=8444), agent=dict(sudo='full'),
                  serverComponents=dict(disk=dict(enabled=True, discoveryIntervalSec=2), bridge=dict(enabled=True)),
                  ssh=dict(keepaliveIntervalSec=30, keepaliveCountMax=3),
                  sessions=dict(cleanupEnabled=True, idleHours=2, intervalMinutes=15),
                  agents=dict(codex=dict(enabled=True, version='0.166.0', auth={'secret': 'codex-auth'}),
                              claude=dict(enabled=True, channel='stable', token={'secret': 'claude-token'})))
    values = {'proxy-pass': 'PROXY_SENTINEL', 'clinic-ovpn': profile, 'clinic-auth': json.dumps(dict(username='fixture', password='LAN_SENTINEL')),
              'ts-auth': 'TS_SENTINEL', 'server-inbounds': json.dumps([dict(type='mixed', tag='probe443', listen='0.0.0.0', listen_port=443),
                                                                   dict(type='mixed', tag='channel-probe', listen='0.0.0.0', listen_port=37091)])}
    values.update({'codex-auth': json.dumps({'OPENAI_API_KEY': 'CODEX_FIXTURE_SENTINEL'}), 'claude-token': 'CLAUDE_FIXTURE_SENTINEL'})
    print('Applying one CRLF config through the production PowerShell engine...', flush=True)
    first = engine(home, config, values)
    if not first['ok']:
        # Installer output is public in this synthetic stand. Never print auth
        # files, request stdin or real host credentials; redact fixture tokens.
        for kind, script in (('codex', '/src/server-codex-v1.sh'), ('claude', '/src/server-claude-code.sh')):
            if any(r['part'] == 'agents:' + kind and r['state'] == 'error' for r in first['parts']):
                diagnostic = inside(target, 'bash', script, check=False, timeout=900)
                detail = (diagnostic.stdout + diagnostic.stderr)[-2500:]
                for secret in values.values():
                    detail = detail.replace(secret, '<redacted>')
                print('INSTALLER DIAGNOSTIC ' + kind + ' rc=' + str(diagnostic.returncode) + ': ' + detail, flush=True)
    assert first['ok'], first
    print('PASS: clean VPS, real TUN/OpenVPN/new SSH/Telegram, mock Tailscale; actions=' + str(len(first['actions'])), flush=True)
    config['serverComponents']['happier'] = dict(enabled=True, version='0.2.17', channel='stable')
    waiting = engine(home, config, values)
    assert not waiting['ok'] and any(r['part'] == 'happier' and r['state'] == 'waiting' and 'нужен вход' in r['summary'] for r in waiting['parts']), waiting
    print('PASS: actual Codex/Claude/Happier CLI installation; Happier without credentials waits for login', flush=True)
    happier_fixture(target)
    values['happier-identity'] = json.dumps({'.happier/settings.json': '{"machineId":"fixture"}', '.happier/access.key': '{"token":"HAPPY_FIXTURE_SENTINEL"}'})
    config['serverComponents']['happier']['identity'] = {'secret': 'happier-identity'}
    assert engine(home, config, values)['ok']
    # Generate a real client credential and let the reconciler capture it.
    telegram_client = json.loads(inside(target, 'runuser', '-u', 'remoteagents', '--', '/home/remoteagents/.local/bin/tg-gateway-keys', 'add', 'fixture', '--json').stdout)
    assert engine(home, config, values)['ok']
    expected_id = device_id(target)
    expected_cert = inside(target, 'sha256sum', '/home/remoteagents/.local/opt/tg-gateway/tls/cert.pem').stdout.split()[0]
    expected_keys = inside(target, 'sha256sum', '/home/remoteagents/.local/opt/tg-gateway/state/keys.json').stdout.split()[0]
    identity_paths = ('.ssh/id_ed25519', '.ssh/id_ed25519.pub', '.happier/settings.json', '.happier/access.key')
    expected_identities = {p: inside(target, 'sha256sum', '/home/remoteagents/' + p).stdout.split()[0] for p in identity_paths}
    second = engine(home, config, values)
    assert second['ok'] and second['actions'] == [], second
    assert inside(target, 'cat', '/etc/remoteagents/lan/clinic/subnets').stdout.strip() == '10.123.0.0/24'
    routes = json.loads(inside(target, 'ip', '-j', '-4', 'route', 'show', 'table', 'all').stdout)
    assert not any(r.get('dst') in ('default', '8.8.4.0/24', '0.0.0.0/1', '128.0.0.0/1') and r.get('dev') == 'tun-lan-clinic' for r in routes)
    assert inside(target, 'sysctl', '-n', 'net.ipv6.conf.tun-lan-clinic.disable_ipv6').stdout.strip() == '1'
    assert 'CONNECT ip-oracle' in inside(gateway, 'cat', '/run/proxy-connections').stdout
    status = engine(home, config, values, status=True)
    assert status['command'] == 'status' and status['actions'] == [] and status['ok'], status
    print('PASS: second apply actions=[]; public push/default dropped; IPv6 LAN off; status read-only', flush=True)
    # No EXE/manual apply after reboot or breakage: only installed boot units/timer.
    docker('restart', target)
    def wait_ready(label):
        deadline = time.monotonic() + 120
        last = {}
        while time.monotonic() < deadline:
            try:
                last = engine(home, config, values, status=True)
                if last.get('ok'):
                    print('PASS: ' + label + ' ready in ' + str(round(120 - (deadline-time.monotonic()), 1)) + 's', flush=True)
                    return
            except Exception:
                pass
            time.sleep(2)
        # Only synthetic fixture credentials exist here. Preserve timer failures
        # before finally removes the containers; production status stays redacted.
        diagnostics = inside(target, 'journalctl', '-u', 'remoteagents-reconcile.service',
                             '--no-pager', '-n', '200', check=False).stdout
        for secret in values.values():
            if secret:
                diagnostics = diagnostics.replace(secret, '<redacted>')
        diagnostics = '\n'.join(line for line in diagnostics.splitlines() if 'pam_unix' not in line)
        raise AssertionError(label + ' did not recover: ' + json.dumps(last) + '\nReconcile journal:\n' + redact(diagnostics))
    wait_ready('real container restart')
    inside(target, 'ip', '-4', 'rule', 'del', 'pref', '8990')
    inside(target, 'ip', '-4', 'rule', 'del', 'pref', '9001')
    inside(target, 'systemctl', 'stop', 'sing-box')
    wait_ready('deleted ip rules and stopped sing-box, timer only')
    put(target, '/etc/sing-box/config.json', '{corrupted')
    inside(target, 'systemctl', 'stop', 'sing-box')
    wait_ready('corrupted sing-box config, timer only')
    inside(target, 'systemctl', 'stop', 'remoteagents-lan@clinic.service')
    put(target, '/etc/remoteagents/lan/clinic/client.conf', '# corrupted')
    put(target, '/etc/remoteagents/lan/clinic/config.json', '{corrupted')
    wait_ready('corrupted OpenVPN profile/settings and stopped LAN, timer only')
    # All user services are repaired ONLY by the production reconcile timer.
    uid = inside(target, 'id', '-u', 'remoteagents').stdout.strip()
    user_systemctl = ['runuser', '-u', 'remoteagents', '--', 'env', 'XDG_RUNTIME_DIR=/run/user/' + uid,
                      'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/' + uid + '/bus', 'systemctl', '--user']
    inside(target, *user_systemctl, 'stop', 'remote-disk-folders.timer', 'remoteagents-syncthing.service', 'tg-gateway.service', 'remoteagents-happier.service')
    for path in ('.local/share/remote-disk/config.xml', '.local/share/remote-disk/key.pem', '.local/share/remote-disk/cert.pem',
                 '.local/opt/tg-gateway/tls/key.pem', '.local/opt/tg-gateway/state/settings.json',
                 '.local/opt/tg-gateway/state/keys.json', '.happier/access.key',
                 '.happier/settings.json', '.ssh/id_ed25519', '.ssh/id_ed25519.pub',
                 '.local/share/codex-remote/codex-windows-bridge.py', '.codex/config.toml', '.claude.json',
                 '.config/remoteagents/claude.env'):
        put(target, '/home/remoteagents/' + path, '{corrupted')
        inside(target, 'chown', 'remoteagents:remoteagents', '/home/remoteagents/' + path)
    put(target, '/home/remoteagents/.local/opt/tg-gateway/state/keys.json', json.dumps({'version': 1, 'keys': {'fixture': {'sha256': 'broken', 'created': '2026-11-15'}}}))
    inside(target, 'rm', '-f', '/home/remoteagents/.config/systemd/user/remoteagents-happier.service',
           '/home/remoteagents/.config/systemd/user/tg-gateway.service',
           '/home/remoteagents/.config/systemd/user/remote-disk-folders.timer.d/interval.conf',
           '/home/remoteagents/.config/remoteagents/claude.env')
    wait_ready('corrupted user configs/TLS, stopped Disk/Telegram/Happier, deleted units/drop-in/token, timer only')
    assert device_id(target) == expected_id
    assert inside(target, 'sha256sum', '/home/remoteagents/.local/opt/tg-gateway/tls/cert.pem').stdout.split()[0] == expected_cert
    assert inside(target, 'sha256sum', '/home/remoteagents/.local/opt/tg-gateway/state/keys.json').stdout.split()[0] == expected_keys
    assert {p: inside(target, 'sha256sum', '/home/remoteagents/' + p).stdout.split()[0] for p in identity_paths} == expected_identities
    # Actual package removal and standalone Syncthing binary deletion.
    inside(target, 'apt-get', 'remove', '-y', 'openvpn', 'sing-box', timeout=180)
    inside(target, 'rm', '-f', '/home/remoteagents/.local/share/remote-disk/bin/syncthing')
    wait_ready('removed sing-box/OpenVPN packages and Syncthing binary, timer only')
    assert engine(home, config, values)['actions'] == []
    put(target, '/run/export.json', json.dumps(dict(schema=1, version=1, serverAddress=address, serverPort=22, workerUser='remoteagents',
         hostKeys=[' '.join(inside(target, 'cat', '/etc/ssh/ssh_host_ed25519_key.pub').stdout.split()[:2])], stateDir='/run/export-state')), '644')
    exported = json.loads(inside(target, 'python3', '-I', '/src/server/remoteagents_config.py', '--config', '/run/export.json',
                                 'export', '--name', 'Clone', '--happier', 'new:Fixture').stdout)
    for key in ('serverNetwork', 'proxyOut', 'lan', 'tailscale', 'telegramGateway'):
        assert {k: v for k, v in exported[key].items() if k != 'identity'} == config[key] if isinstance(config[key], dict) else exported[key] == config[key]
    assert exported['secrets']['clinic-ovpn'] == ''
    print('PASS: config export includes all server sections and separate named secret slots', flush=True)
    full = inside(target, 'python3', '-I', '/src/server/remoteagents_config.py', '--config', '/run/export.json',
                  'export', '--name', 'Restore', '--happier', 'new:Fixture', '--include-server-secrets',
                  '--master-password-stdin', '--output', '/run/full-config.json', input='MASTER_FIXTURE\n')
    assert 'SENTINEL' not in full.stdout + full.stderr
    assert inside(target, 'stat', '-c', '%a', '/run/full-config.json').stdout.strip() == '600'
    denied = inside(target, 'runuser', '-u', 'remoteagents', '--', 'python3', '-I', '/src/server/remoteagents_config.py',
                    '--config', '/run/export.json', 'export', '--name', 'Denied', '--happier', 'new:Fixture',
                    '--include-server-secrets', '--output', '/tmp/denied-export.json', check=False)
    assert denied.returncode != 0 and 'root' in denied.stderr
    assert 'SENTINEL' not in denied.stdout + denied.stderr
    inside(target, 'chmod', '644', '/etc/remoteagents/server-apply/recovery.json')
    unsafe = inside(target, 'python3', '-I', '/src/server/remoteagents_config.py', '--config', '/run/export.json',
                    'export', '--name', 'Unsafe', '--happier', 'new:Fixture', '--include-server-secrets',
                    '--output', '/run/unsafe-export.json', check=False)
    assert unsafe.returncode != 0 and 'SENTINEL' not in unsafe.stdout + unsafe.stderr
    inside(target, 'chmod', '600', '/etc/remoteagents/server-apply/recovery.json')
    assert inside(target, 'test', '-e', '/run/unsafe-export.json', check=False).returncode != 0
    encrypted = temp / 'full-config.json'
    encrypted.write_text(inside(target, 'cat', '/run/full-config.json').stdout); encrypted.chmod(0o600)
    dotnet = Path.home() / '.dotnet/dotnet'
    env = dict(os.environ, DOTNET_PROCESSOR_COUNT='2', RA_E2E_MASTER='MASTER_FIXTURE')
    call([dotnet, 'build', REPO / 'app/launcher/tests/PortableTests.csproj', '-c', 'Release',
          '-p:ConfigE2E=true', '--nologo'], env=env, timeout=120)
    pasted = json.loads(call([dotnet, REPO / 'app/launcher/tests/bin/Release/config-e2e/net10.0/PortableTests.dll',
                             '--apply', temp / 'pasted', encrypted], env=env, timeout=120).stdout)
    assert pasted['missing'] == [] and pasted['keyMaterialized'] and pasted['wrongMasterRefused'] and pasted['fullExportRoundtrip'] and pasted['aiHasNoKey']
    call(['ssh', '-F', home / 'ssh.conf', '-o', 'UserKnownHostsFile=' + str(home / 'known_hosts'),
          '-o', 'IdentitiesOnly=yes', '-i', pasted['serverKeyFile'], 'remoteagents@' + address, 'true'])
    print('PASS: root full export + master password -> actual C# Parse/Unlock/vault/materialize/export -> real SSH with exported key', flush=True)
    verify_managed_user(target)
    inside(target, 'python3', '-I', '/src/server/remoteagents_config.py', '--config', '/run/export.json',
           'export', '--name', 'Clone', '--happier', 'new:Fixture', '--include-server-secrets', '--output', '/run/clone-config.json')
    clone_config = json.loads(inside(target, 'cat', '/run/clone-config.json').stdout)
    clone_values = clone_config.pop('secrets')
    expected_codex_hash = inside(target, 'sha256sum', '/home/remoteagents/.codex/auth.json').stdout.split()[0]
    # A replacement with the SAME identities must not compete with the source
    # for one VPN login / Syncthing device / Happier machine identity.
    docker('stop', target)
    clone, clone_home, clone_address = new_vps('clone', temp, gateway)
    happier_fixture(clone)  # Only the offline Happier API/daemon boundary is mocked.
    clone_config['server']['address'] = clone_address
    clone_config['server']['hostKeys'] = [' '.join(inside(clone, 'cat', '/etc/ssh/ssh_host_ed25519_key.pub').stdout.split()[:2])]
    restored = engine(clone_home, clone_config, clone_values)
    assert restored['ok'], restored
    clone_key = temp / 'clone-export-key'
    clone_key.write_text(clone_values['server-key']); clone_key.chmod(0o600)
    call(['ssh', '-F', clone_home / 'ssh.conf', '-o', 'UserKnownHostsFile=' + str(clone_home / 'known_hosts'),
          '-o', 'IdentitiesOnly=yes', '-i', clone_key, 'remoteagents@' + clone_address, 'true'])
    assert device_id(clone) == expected_id
    assert inside(clone, 'sha256sum', '/home/remoteagents/.local/opt/tg-gateway/tls/cert.pem').stdout.split()[0] == expected_cert
    assert inside(clone, 'sha256sum', '/home/remoteagents/.local/opt/tg-gateway/state/keys.json').stdout.split()[0] == expected_keys
    assert inside(clone, 'sha256sum', '/home/remoteagents/.codex/auth.json').stdout.split()[0] == expected_codex_hash
    assert {p: inside(clone, 'sha256sum', '/home/remoteagents/' + p).stdout.split()[0] for p in identity_paths} == expected_identities
    health_script = """import json,ssl,sys,urllib.request
try:
 d=json.load(sys.stdin)
 ctx=ssl.create_default_context(cadata=d['ca'])
 opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPSHandler(context=ctx))
 with opener.open('https://127.0.0.1:8444/'+d['key']+'/health',timeout=5) as response:
  assert response.read()==b'ok'
except Exception:
 raise SystemExit('Original Telegram client rejected') from None
"""
    inside(clone, 'python3', '-c', health_script,
           input=json.dumps(dict(key=telegram_client['base_url'].rsplit('/', 1)[1], ca=telegram_client['ca_pem'])))
    print('PASS: full root export -> second clean VPS -> same Syncthing device ID, Telegram TLS/client keys, bridge SSH keypair, Happier identity and agent auth', flush=True)
    # Confirm a real inbound replacement and removal first.
    inbounds = json.loads(clone_values['server-inbounds'])
    inbounds[-1]['listen_port'] = 37092
    clone_values['server-inbounds'] = json.dumps(inbounds)
    clone_config['serverNetwork']['inboundPorts'] = [22, 443, 37092]
    assert engine(clone_home, clone_config, clone_values)['ok']
    inbounds.pop()
    clone_values['server-inbounds'] = json.dumps(inbounds)
    clone_config['serverNetwork']['inboundPorts'] = [22, 443]
    assert engine(clone_home, clone_config, clone_values)['ok']
    old = inside(clone, 'sha256sum', '/etc/sing-box/config.json').stdout.split()[0]
    inbounds.append(dict(type='mixed', tag='replacement', listen='0.0.0.0', listen_port=37093))
    clone_values['server-inbounds'] = json.dumps(inbounds)
    clone_config['serverNetwork']['inboundPorts'] = [22, 443, 37093]
    errors = []
    def revoke_new_ssh():
        try:
            for _ in range(1800):
                if inside(clone, 'test', '-f', '/var/lib/remoteagents/base-network/pending/state.json', check=False).returncode == 0:
                    inside(clone, 'passwd', '-l', 'root')
                    put(clone, '/home/remoteagents/.ssh/authorized_keys', '')
                    return
                time.sleep(.2)
            errors.append('pending not reached')
        except Exception:
            errors.append('watcher failed')
    watcher = threading.Thread(target=revoke_new_ssh, daemon=True); watcher.start()
    print('Breaking NEW SSH after managed inbound update; waiting for real five-minute rollback...', flush=True)
    failed = engine(clone_home, clone_config, clone_values)
    watcher.join(timeout=5)
    assert not failed['ok'] and not errors, failed
    assert inside(clone, 'systemctl', 'is-active', '--quiet', 'remoteagents-base-network-rollback.timer', check=False).returncode == 0
    deadline = time.monotonic() + 325
    while inside(clone, 'test', '-f', '/var/lib/remoteagents/base-network/pending/state.json', check=False).returncode == 0 and time.monotonic() < deadline:
        time.sleep(1)
    assert inside(clone, 'test', '-f', '/var/lib/remoteagents/base-network/pending/state.json', check=False).returncode != 0
    assert inside(clone, 'sha256sum', '/etc/sing-box/config.json').stdout.split()[0] == old
    assert inside(clone, 'systemctl', 'is-active', '--quiet', 'sing-box', check=False).returncode == 0
    print('PASS: failed NEW SSH preserved timer; real rollback restored previous managed inbound set', flush=True)


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix=PREFIX + '-') as directory:
        try:
            main(Path(directory))
        finally:
            for container in reversed(containers):
                docker('rm', '-f', container, check=False)
            docker('network', 'rm', PREFIX, check=False)
            docker('image', 'rm', PREFIX, PREFIX + '-fixture', check=False)
