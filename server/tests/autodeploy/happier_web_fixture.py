#!/usr/bin/env python3
"""INSIDE disposable systemd containers: export -> clean server -> production apply.

Daemon CLI/API is a synthetic fixture: no GitHub install or cloud authentication.
The web installer/signature verifier/server/user units are production code.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request

assert Path('/run/systemd/system').is_dir() and os.environ.get('container') == 'docker'
sys.path.insert(0, '/src/server')
import server_apply as app

home = Path('/home/worker')
base = home / '.local/share/remoteagents-happier-web'
assert not base.exists(), 'target must start without UI state'
# Explicit fixture for the independently tested vendor boundary. This never
# executes downloaded release contents and never reaches Happier's cloud API.
cli = '''#!/usr/bin/python3
import json,signal,sys
from pathlib import Path
if '--version' in sys.argv: print('0.2.17')
elif sys.argv[1:] == ['daemon','start-sync']:
    assert json.loads((Path.home()/'.happier/access.key').read_text())['token']=='HAPPY_FIXTURE_SENTINEL'
    signal.pause()
else: raise SystemExit(1)
'''
subprocess.run(['runuser','-u','worker','--','python3','-I','-c',
                'from pathlib import Path; import sys; p=Path.home()/".local/bin/happier"; p.parent.mkdir(parents=True,exist_ok=True);p.write_text(sys.stdin.read());p.chmod(0o700)'], input=cli,text=True,check=True)
if sys.argv[1] == 'source':
    config = dict(kind='remoteagents-config', schema=1, server=dict(login='worker'), serverComponents=dict(
        happier=dict(enabled=True,version='0.2.17',identity=dict(secret='fixture-happier')),
        happierWeb=dict(enabled=True,port=47831,keepChats=11,quotas=dict(enabled=False))))
    values = {'fixture-happier':json.dumps({'.happier/settings.json':json.dumps(dict(activeServerId='private',servers=dict(private=dict(serverUrl='https://happier.fixture.invalid',webappUrl='https://web.fixture.invalid')))),
                                        '.happier/access.key':'{"token":"HAPPY_FIXTURE_SENTINEL"}'})}
else:
    config = json.loads(Path('/root/import.json').read_text())
    values = config.pop('secrets')
    assert config['serverComponents']['happier']['enabled']
    assert config['serverComponents']['happierWeb']['enabled']
    assert config['happier']['localWeb'] == dict(enabled=True,port=47831,serverPort=47831)
app.validate(config)
first = app.Engine(config,values).run('apply')
assert first['ok'], first
assert first['actions'], first
print('PASS: '+sys.argv[1]+' full reconcile installs signed UI and real user service/timer (daemon fixture)', flush=True)
assert (base / 'current').is_symlink()
assert list((base / 'current').glob('*.tar.gz'))
request = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with request.open('http://127.0.0.1:47831/_remoteagents/health',timeout=5) as response:
    health = json.load(response)
assert health['ok'] and health['uiVersion'].startswith('ui-web-v'), health
with request.open('http://127.0.0.1:47831/',timeout=5) as response:
    assert response.headers['Cache-Control'] == 'no-store'
    assert response.read().count(b'/_remoteagents/addon.js') == 1
with request.open('http://127.0.0.1:47831/_remoteagents/addon.js',timeout=5) as response:
    assert b'https://happier.fixture.invalid' in response.read()
sockets = subprocess.check_output(['ss','-ltnH']).decode()
assert '127.0.0.1:47831' in sockets and '0.0.0.0:47831' not in sockets
second = app.Engine(config,values).run('apply')
assert second['ok'] and second['actions'] == [], second
print('PASS: '+sys.argv[1]+' loopback health/index and repeat apply actions: []', flush=True)
if sys.argv[1] == 'source':
    settings = dict(schema=1,version=1,serverAddress='127.0.0.1',serverPort=22,workerUser='worker',
                    hostKeyFiles=['/etc/ssh/ssh_host_ed25519_key.pub'],
                    serverConfig='/var/lib/remoteagents-status/server-config.json',
                    happier=dict(serverUrl='https://happier.fixture.invalid',webappUrl='https://web.fixture.invalid'))
    path=Path('/root/export-settings.json');path.write_text(json.dumps(settings));path.chmod(0o600)
    subprocess.run(['/usr/bin/python3','-I','/src/server/remoteagents_config.py','--config',str(path),'export',
                    '--name','Acceptance','--happier','new:Acceptance','--include-server-secrets','--output','/root/export.json'],
                   capture_output=True,check=True)
    exported=json.loads(Path('/root/export.json').read_text())
    assert exported['serverComponents']['happierWeb']['enabled'] and exported['serverComponents']['happier']['enabled']
    assert exported['happier']['localWeb']==dict(enabled=True,port=47831,serverPort=47831)
    print('PASS: real remoteagents config export includes both components, identity and matching localWeb ports',flush=True)
else:
    unit = home / '.config/systemd/user/remoteagents-happier-web.service'
    unit.unlink()
    repair = app.Engine(config,values).run('apply')
    assert repair['ok'] and unit.is_file(), repair
    assert app.Engine(config,values).run('apply')['actions'] == []
    print('PASS: missing user unit restored, next reconcile has zero changes', flush=True)
    config['serverComponents']['happierWeb']['enabled'] = False
    result = app.Engine(config,values).run('apply')
    assert result['ok'], result
    assert (base / 'current/web/index.html').is_file()
    e = app.Engine(config)
    for name in ('remoteagents-happier-web.service','remoteagents-happier-web-update.timer'):
        assert e.s.run(e.user_cmd('systemctl','--user','is-active','--quiet',name),check=False).returncode != 0
    print('PASS: enabled:false stops service/timer and preserves releases', flush=True)
