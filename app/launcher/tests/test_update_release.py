#!/usr/bin/env python3
"""Real packaging + SSH publisher against disposable files and fake ssh/git/gh. Never a live release."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[3]
def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / file)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result); return result
bundle = module('bundle', 'build/bundle.py')
release = module('release_dist', 'build/release-dist.py')

class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='remoteagents-ota-release-')
        self.root = Path(self.tmp.name); self.stage = self.root/'stage'; self.out = self.root/'out'; self.out.mkdir()
        self.bin = self.root/'bin'; self.bin.mkdir(); self.assets = self.root/'assets'; self.assets.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin)+':'+os.environ['PATH'], ASSETS=str(self.assets), FAKE_LOG=str(self.root/'calls'))
        self.script('ssh', '''import subprocess,sys
assert sys.argv[-2] == 'fixture.invalid'
sys.exit(subprocess.run(['bash','-c',sys.argv[-1]],stdin=sys.stdin.buffer).returncode)
''')
        self.script('gh', '''import os,pathlib,shutil,sys
args=sys.argv[1:]; assets=pathlib.Path(os.environ['ASSETS'])
with open(os.environ['FAKE_LOG'],'a') as f:f.write('gh '+repr(args)+'\\n')
if args[:2]==['release','download']:
    dest=pathlib.Path(args[args.index('-D')+1]);dest.mkdir(exist_ok=True)
    for i,v in enumerate(args):
        if v=='-p':
            name=args[i+1];shutil.copyfile(assets/name,dest/name)
            if os.environ.get('CORRUPT')==name:(dest/name).write_bytes(b'corrupted')
elif args[:2] in (['release','upload'],['release','create']):
    for name in args[3:]:
        if pathlib.Path(name).is_file():shutil.copyfile(name,assets/pathlib.Path(name).name)
''')
        for folder, product in [('agents','RemoteAgents')]:
            exe = self.out/(product+'.exe')
            exe.write_bytes(b'MZ fixture'+product.encode()+'FileVersion\0'.encode('utf-16le')+'1.4.0.0\0'.encode('utf-16le'))
            path = self.root/(folder+'.zip')
            with zipfile.ZipFile(path,'w') as z:
                z.writestr('bundle-version.txt','20261116.120000-fixture\r\n')
                z.writestr('components.json','[{"name":"test","exe":"unused"}]')
                z.writestr(product+'.exe',exe.read_bytes())
            bundle.publish(path,self.stage/folder,launcher=exe)
            (self.out/'bundle.zip').write_bytes(path.read_bytes())
        release.metadata(self.stage,self.out/'release-info.json','fixture-head')
    def tearDown(self): self.tmp.cleanup()
    def script(self,name,body):
        p=self.bin/name;p.write_text('#!'+sys.executable+'\n'+body);p.chmod(0o755)
    def tar(self):
        stream=io.BytesIO()
        with tarfile.open(fileobj=stream,mode='w') as tar:
            for folder in ('agents',):tar.add(self.stage/folder,arcname=folder)
        return stream.getvalue()
    def publish(self):
        command=subprocess.check_output([sys.executable,str(ROOT/'build/release-dist.py'),'command',str(self.root/'remote dist')],text=True).strip()
        return subprocess.run(['ssh','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','--','fixture.invalid',command],input=self.tar(),env=self.env,capture_output=True)
    def fake_git(self,branch='main'):
        self.script('git',f'''import os,sys
args=sys.argv[1:]
with open(os.environ['FAKE_LOG'],'a') as f:f.write('git '+repr(args)+'\\n')
if 'branch' in args:print({branch!r})
elif 'rev-parse' in args:print('fixture-head')
elif 'status' in args:pass
''')
    def test_ssh_both_products_version_hashes_idempotence(self):
        for _ in range(2):
            result=self.publish();self.assertEqual(result.returncode,0,result.stderr.decode())
        remote=self.root/'remote dist'
        for folder,dest in [('agents',remote)]:
            manifest=json.loads((dest/'manifest.json').read_text())
            self.assertEqual(manifest['configSchema'],1)
            self.assertEqual(manifest['version'],'20261116.120000-fixture')
            self.assertEqual(bundle.digest(dest/manifest['file']),manifest['sha256'])
            self.assertEqual((dest/(manifest['product']+'.exe')).read_bytes(),(self.out/(manifest['product']+'.exe')).read_bytes())
        self.assertFalse(list(remote.glob('.incoming-*')))
    def test_github_both_exes_metadata_and_readback(self):
        self.fake_git()
        result=subprocess.run([str(ROOT/'build/release-github.sh'),str(self.out)],env=self.env,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr.decode())
        for name in ('RemoteAgents.exe','release-info.json'):
            self.assertEqual((self.assets/name).read_bytes(),(self.out/name).read_bytes())
        self.env['CORRUPT']='RemoteAgents.exe'
        result=subprocess.run([str(ROOT/'build/release-github.sh'),str(self.out)],env=self.env,capture_output=True)
        self.assertNotEqual(result.returncode,0)
    def test_branch_guard_before_any_publication_or_build(self):
        self.fake_git('app/update')
        for script,args in [('release.sh',['fixture.invalid']),('release-github.sh',[str(self.out)]),('publish.sh',[str(self.root/'agents.zip'),str(self.root/'not-used')])]:
            # publish.sh allows only /tmp output as explicitly documented offline mode.
            if script=='publish.sh':args[-1]='/var/remoteagents-never-write-fixture'
            result=subprocess.run([str(ROOT/'build'/script),*args],env=self.env,capture_output=True)
            self.assertNotEqual(result.returncode,0)
        self.assertNotIn('gh ',(self.root/'calls').read_text())
    def test_whole_command_prepared_build_uses_same_release(self):
        self.fake_git()
        result=subprocess.run([str(ROOT/'build/release.sh'),'fixture.invalid',str(self.root/'remote dist'),'--prepared',str(self.out)],env=self.env,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr.decode())
        remote=self.root/'remote dist'
        info=json.loads((self.assets/'release-info.json').read_text())
        self.assertEqual(json.loads((remote/'manifest.json').read_text())['version'], info['version'])
        for folder,product in [(remote,'RemoteAgents')]:
            self.assertEqual((folder/(product+'.exe')).read_bytes(),(self.assets/(product+'.exe')).read_bytes())
        old=(self.out/'release-info.json').read_text()
        (self.out/'release-info.json').write_text(old.replace('fixture-head','stale-commit'))
        result=subprocess.run([str(ROOT/'build/release.sh'),'fixture.invalid',str(self.root/'remote dist'),'--prepared',str(self.out)],env=self.env,capture_output=True)
        self.assertNotEqual(result.returncode,0)

    def test_metadata_has_exact_product_hashes(self):
        m=json.loads((self.out/'release-info.json').read_text())
        for name,digest in m['sha256'].items():self.assertEqual(bundle.digest(self.out/name),digest)

if __name__=='__main__': unittest.main()
