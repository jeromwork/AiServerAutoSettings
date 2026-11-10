#!/usr/bin/env python3
"""Linux-only preflight shims: direct paths fail, only an imported detour can work."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PWSH = sys.argv[1] if len(sys.argv) > 1 else str(Path.home()/'.cache/pwsh-test/pwsh')


def exe(path, source):
    path.write_text('#!'+sys.executable+'\n'+source)
    path.chmod(0o700)


class MigrationTests(unittest.TestCase):
    def exercise(self, with_hop):
        with tempfile.TemporaryDirectory(prefix='migration-hop-') as tmp:
            local = Path(tmp); home = local/'RemoteAgents'; disk = local/'RemoteDisk'
            channel = disk/'channel'; channel.mkdir(parents=True); home.mkdir()
            ssh = local/'ssh'; sb = channel/'sing-box.exe'
            exe(ssh, r'''import json,os,sys,time
from pathlib import Path
home=Path(os.environ['LOCALAPPDATA'])/'RemoteAgents'/'state/migration-probe'
if '-N' in sys.argv:
    while True: time.sleep(.1)
port=int(sys.argv[sys.argv.index('-p')+1])
cfg=json.loads((home/'state/transport-sing-box.json').read_text())
inbound=next(i['tag'] for i in cfg['inbounds'] if i['listen_port']==port)
if inbound=='ssh':
    tag=(home/'selected').read_text() if (home/'selected').exists() else next(o['default'] for o in cfg['outbounds'] if o['tag']=='active')
else: tag=next(r['outbound'] for r in cfg['route']['rules'] if inbound in r['inbound'])
node=next(o for o in cfg['outbounds'] if o['tag']==tag)
if not node.get('detour'):
    os.write(2,b'connect: Connection refused password=pw\r\nsecond line must not be logged\n'); sys.exit(255)
if sys.argv[-1]=='true': sys.exit(0)
n=int(sys.argv[-1].split()[2]); os.write(1,b'x'*n)
''')
            exe(sb, r'''import http.server,json,os,sys
from pathlib import Path
if sys.argv[1]=='check': sys.exit(0)
cfg=json.loads(Path(sys.argv[-1]).read_text()); api=cfg['experimental']['clash_api']
home=Path(os.environ['LOCALAPPDATA'])/'RemoteAgents'/'state/migration-probe'
class API(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        assert self.headers['Authorization']=='Bearer '+api['secret']
        data=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        (home/'selected').write_text(data['name']); self.send_response(204); self.end_headers()
    def log_message(self,*args): pass
class Server(http.server.HTTPServer): allow_reuse_address=True
Server(('127.0.0.1',int(api['external_controller'].split(':')[-1])),API).serve_forever()
''')
            fixture = json.loads((ROOT/'transport/fixtures/legacy-hop.json').read_text())
            if not with_hop:
                fixture['outbounds'] = [fixture['outbounds'][0], dict(fixture['outbounds'][3], outbounds=['vless-direct'])]
            (channel/'config.json').write_bytes(json.dumps(fixture, indent=2).replace('\n','\r\n').encode())
            known = local/'known_hosts'
            known.write_text('server.example.invalid ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDKtkImHp4iQlyBtwBY4Vx3cBxfNF0Hdga/ucaszwI2r\n')
            profile = local/'profile.json'
            profile.write_text(json.dumps(dict(sshExecutable=str(ssh), serverAddress='server.example.invalid', login='tester', keyPath=str(local/'key'), knownHostsPath=str(known), arguments=[])))
            (disk/'profile.txt').write_text(str(profile)+'\r\n')
            # pw is intentionally short: generic long-token redaction alone cannot protect it.
            config = dict(transport=dict(bindPhysical=False, metered='true', topOnMetered=1, probeTimeoutSec=3, stallSeconds=1, rankConcurrency=1))
            (home/'config.json').write_text(json.dumps(config))
            wrapper = local/'run.ps1'
            wrapper.write_text("""param($Repo,$Root,$Disk)
. (Join-Path $Repo 'build/Migrate.Common.ps1')
function Wait-MigrationTransport([string]$Root,[int]$Timeout=18){
    $end=[DateTime]::UtcNow.AddSeconds($Timeout)
    do {if(Test-MigrationFresh $Root transport){return};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $end)
    throw 'fixture deadline'
}
$c=Import-MigrationConfig $Root $Disk
try{Invoke-MigrationPreflight $Root $Repo $c;exit 0}catch{exit 2}
""", encoding='utf-8-sig')
            result = subprocess.run([PWSH,'-NoProfile','-NonInteractive','-File',str(wrapper),'-Repo',str(ROOT),'-Root',str(home),'-Disk',str(disk)], env=dict(os.environ, LOCALAPPDATA=tmp), stdin=subprocess.DEVNULL, capture_output=True, timeout=50)
            self.assertEqual(result.returncode, 0 if with_hop else 2, result.stderr.decode())
            probe = home/'state/migration-probe'
            log = (probe/'logs/transport.log').read_text()
            self.assertIn('reason=connection-refused exit=255 stderr=connect: Connection refused password=<redacted>', log)
            self.assertNotIn('password=pw', log)
            self.assertNotIn('second line must not', log)
            if with_hop:
                self.assertIn('preflight.ok', (home/'logs/migration.log').read_text())
                status = json.loads((probe/'status/transport.json').read_text())
                imported = next(c for c in status['candidates'] if c['tag'].startswith('legacy-'))
                self.assertEqual(imported['state'], 'ok')
                self.assertEqual(imported['title'], 'VLESS через SSH-переход')
            else:
                migration_log = (home/'logs/migration.log').read_text()
                status = json.loads((probe/'status/transport.json').read_text())
                for candidate in status['candidates']:
                    self.assertIn('preflight.candidate candidate='+candidate['tag'], migration_log)
                error = json.loads((home/'state/migration-error.json').read_text())
                self.assertIn('Нет рабочего пути к серверу:', error['message'])
                self.assertIn('connection-refused', error['message'])
                self.assertNotIn('password=pw', migration_log)
            self.assertEqual(json.loads((channel/'config.json').read_text()), fixture)

    def test_only_legacy_hop_works_on_metered_network(self):
        self.exercise(True)

    def test_no_path_has_per_candidate_failure_report(self):
        self.exercise(False)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]], verbosity=2)
