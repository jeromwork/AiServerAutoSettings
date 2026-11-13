#!/usr/bin/env python3
"""Real PS upload -> bash/Python and ignore checks; isolated homes, no live SSH."""
import ast
import concurrent.futures
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PWSH = Path(os.environ.get('PWSH', Path.home()/'.cache/pwsh-test/pwsh'))


def quote(value):
    return "'"+str(value).replace("'", "''")+"'"


def digest(text):
    return hashlib.sha256((text.replace('\r', '').rstrip('\n')+'\n').encode()).hexdigest()


class IgnoreHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ignore-history-')
        self.home = Path(self.temp.name)
        self.env = dict(os.environ, HOME=str(self.home), LOCALAPPDATA=str(self.home/'local'))
        self.remote = self.home/'.local/share/remote-disk'
        self.remote.mkdir(parents=True)
        self.folder = self.home/'Disk/AddTest'
        self.folder.mkdir(parents=True)

    def tearDown(self):
        self.temp.cleanup()

    def ps(self, code):
        result = subprocess.run([str(PWSH), '-NoProfile', '-NonInteractive', '-Command', code],
                                env=self.env, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return result.stdout.decode('utf-8-sig')

    def bundle(self, name, rules, hashes):
        bundle = self.home/name
        (bundle/'disk').mkdir(parents=True)
        shutil.copyfile(ROOT/'disk/Disk.Common.ps1', bundle/'disk/Disk.Common.ps1')
        (bundle/'disk/stignore.txt').write_bytes(rules.replace('\n', '\r\n').encode())
        (bundle/'disk/stignore-previous.sha256').write_bytes(('\r\n'.join(hashes)+'\r\n').encode())
        return bundle

    def upload(self, bundle):
        command = '. '+quote(bundle/'disk/Disk.Common.ps1')+';Get-DiskIgnoreUpload'
        code = self.ps(command)
        self.assertNotIn('\r', code)
        result = subprocess.run(['bash', '-s'], input=code, text=True, env=self.env,
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def ignores(self, rules, success=True):
        # Execute the production Python functions, without starting/bootstraping a real engine.
        source = (ROOT/'disk/server-disk.sh').read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
        tree = ast.parse(source)
        functions = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in ('safe', 'ignores')]
        scope = dict(Path=Path, here=self.remote, hashlib=hashlib, tempfile=tempfile, os=os)
        exec(compile(ast.Module(body=functions, type_ignores=[]), 'server-disk.sh', 'exec'), scope)
        (self.folder/'.stignore').write_bytes(rules.replace('\n', '\r\n').encode())
        if success:
            scope['ignores'](self.folder, True)
            self.assertEqual((self.folder/'.stignore').read_text(), (self.remote/'stignore.txt').read_text())
        else:
            with self.assertRaisesRegex(ValueError, 'AddTest: Чужой .stignore'):
                scope['ignores'](self.folder, True)
            self.assertEqual((self.folder/'.stignore').read_text(), rules)

    def test_versions_survive_upgrade_downgrade_and_concurrent_installs(self):
        old, new, older = '// old\n(?i)/vendor\n', '// new\n(?i)/node_modules\n', '// older\n(?i)/build\n'
        self.remote.joinpath('stignore.txt').write_text(older)
        self.remote.joinpath('stignore-previous.sha256').write_text('a'*64+'\r\n')
        first = self.bundle('v1', old, [digest(old)])
        second = self.bundle('v2', new, [digest(new)])
        self.upload(first)
        self.upload(second)
        self.ignores(old)
        self.upload(first)
        self.ignores(new)
        self.ignores(older)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(self.upload, (first, second)))
        versions = self.remote.joinpath('stignore-previous.sha256').read_text().splitlines()
        self.assertEqual(set(versions), {digest(old), digest(new), digest(older), 'a'*64})
        self.assertEqual(len(versions), len(set(versions)))
        self.ignores('foreign policy\n', False)

    def test_windows_history_survives_bundle_changes(self):
        old, new = '// old\n', '// new\n'
        first = self.bundle('v1', old, [digest(old)])
        second = self.bundle('v2', new, [digest(new)])
        for bundle, previous in ((first, old), (second, old), (first, new)):
            code = '. '+quote(bundle/'disk/Disk.Common.ps1')+';'
            code += '[IO.File]::WriteAllText('+quote(self.folder/'.stignore')+','+quote(previous.replace('\n', '\r\n'))+');'
            code += 'Test-DiskIgnores '+quote(self.folder)
            self.ps(code)
        versions = (self.home/'local/RemoteDisk/stignore-previous.sha256').read_text().splitlines()
        self.assertEqual(set(versions), {digest(old), digest(new)})

    def test_wizard_upload_preserves_remote_history(self):
        self.remote.joinpath('stignore-previous.sha256').write_text('b'*64+'\r\n')
        code = '. '+quote(ROOT/'build/Wizard.Common.ps1')+''';
function Invoke-WizardSsh($Root,$Command,$InputText='',$Timeout=60){
 Invoke-DiskProcess 'bash' @('-c',$Command) -InputText $InputText -TimeoutSeconds $Timeout
};'''
        code += 'Send-WizardHelpers '+quote(self.home/'launcher')+' '+quote(ROOT)
        for _ in range(2):
            self.ps(code)
        versions = self.remote.joinpath('stignore-previous.sha256').read_text().splitlines()
        self.assertIn('b'*64, versions)
        self.assertIn(digest((ROOT/'disk/stignore.txt').read_text()), versions)
        self.assertEqual(len(versions), len(set(versions)))

    def test_repository_history_has_all_released_hashes_and_current(self):
        versions = (ROOT/'disk/stignore-previous.sha256').read_text().splitlines()
        self.assertTrue({
            '9c1b2c9568492b513199bd44ee9963a1915e5d89c5cf79031cd9e3067ffc3409',
            '53ec8f57dcd8d6e778ecb1b1fea26ed071f82820ff8d42198bc33d553773bbb5',
            '9a486952e5510eaf30e6d95dfe3400fb48a71e1d7d68a0cbccfb539562f6b80c',
            digest((ROOT/'disk/stignore.txt').read_text()),
        } <= set(versions))
        self.assertEqual(len(versions), len(set(versions)))
        self.assertTrue((ROOT/'disk/stignore.txt').read_text().endswith('(?i)/storage/app\n(?i)/storage/framework\n'))


if __name__ == '__main__':
    unittest.main()
