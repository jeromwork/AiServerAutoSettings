#!/usr/bin/env python3
"""Production one-level inventory and helper upgrade, in isolated homes only."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
PWSH = Path.home() / '.cache/pwsh-test/pwsh'


def quote(p):
    return "'" + str(p).replace("'", "''") + "'"


class LazyTreeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='disk-tree-')
        cls.home = Path(cls.temp.name)
        cls.env = dict(os.environ, HOME=str(cls.home), LOCALAPPDATA=str(cls.home / 'local'))
        cls.project = cls.home / 'Disk/Project'
        for name in ('many', 'empty', 'hidden', "O'Brien", 'src/deep', 'vendor'):
            (cls.project / name).mkdir(parents=True, exist_ok=True)
        for i in range(21001):
            (cls.project / 'many' / f'{i:05}.txt').touch()
        (cls.project / 'src/deep/file.txt').touch()
        (cls.project / 'hidden/.env').touch()
        (cls.project / "O'Brien/a.txt").touch()
        (cls.project / '.env').touch()
        (cls.project / '.STIGNORE').touch()
        (cls.project / 'vendor/ignored.txt').touch()
        (cls.project / 'link').symlink_to(cls.project / 'src', target_is_directory=True)
        cls.times = []

    @classmethod
    def tearDownClass(cls):
        print('tree elapsed seconds:', ', '.join(f'{x:.3f}' for x in cls.times))
        cls.temp.cleanup()

    def tree(self, path=''):
        start = time.monotonic()
        args = ['bash', str(ROOT / 'disk/server-disk.sh'), 'tree']
        if path:
            args.append(path)
        result = subprocess.run(args, env=self.env, stdin=subprocess.DEVNULL,
                                capture_output=True, timeout=5)
        self.times.append(time.monotonic()-start)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return json.loads(result.stdout)

    def ps(self, command):
        result = subprocess.run([str(PWSH), '-NoProfile', '-NonInteractive', '-Command', command],
                                env=self.env, stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return json.loads(result.stdout.decode('utf-8-sig'))

    def test_root_is_one_project_despite_21001_descendants(self):
        result = self.tree()
        self.assertEqual([(x['path'], x['hasChildren']) for x in result['entries']], [('Project', True)])
        self.assertFalse(result['truncated'])

    def test_children_flags_protection_and_crlf_argument(self):
        result = self.tree('Project\r\n')
        entries = {x['path']: x for x in result['entries']}
        self.assertEqual(set(entries), {'Project/'+x for x in ('many', 'empty', 'hidden', "O'Brien", 'src')})
        self.assertTrue(entries['Project/src']['hasChildren'])
        self.assertFalse(entries['Project/empty']['hasChildren'])
        self.assertFalse(entries['Project/hidden']['hasChildren'])
        self.assertFalse(result['truncated'])

    def test_large_single_folder_is_capped_without_error(self):
        result = self.tree('Project/many')
        self.assertEqual(len(result['entries']), 2000)
        self.assertTrue(result['truncated'])
        self.assertTrue(all(not x['directory'] and not x['hasChildren'] for x in result['entries']))

    def test_protected_and_traversal_refused(self):
        for path in ('../outside', 'Project/../Project', 'Project/vendor', 'Project/link'):
            with self.subTest(path=path):
                result = subprocess.run(['bash', str(ROOT / 'disk/server-disk.sh'), 'tree', path], env=self.env,
                                        stdin=subprocess.DEVNULL, capture_output=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)

    def test_union_one_level_and_local_cap(self):
        command = ". " + quote(ROOT / 'disk/Disk.Common.ps1') + ';. ' + quote(ROOT / 'disk/Disk.Union.ps1')
        command += ";$server=('{\"entries\":[{\"path\":\"Project\",\"directory\":true,\"hasChildren\":true}],\"truncated\":false}'+\"`r`n\")|ConvertFrom-Json;"
        command += 'Get-DiskUnion $server ' + quote(self.home / 'Disk') + '|ConvertTo-Json -Depth 20 -Compress'
        union = self.ps(command)
        self.assertEqual(len(union['rows']), 1)
        self.assertEqual(union['rows'][0]['presence'], 'both')
        self.assertTrue(union['rows'][0]['hasChildren'])
        cap = self.ps('. ' + quote(ROOT / 'disk/Disk.Common.ps1') + ';. ' + quote(ROOT / 'disk/Disk.Union.ps1') +
                      ';Get-DiskUnion ([pscustomobject]@{entries=@()}) ' + quote(self.home / 'Disk') +
                      " 'Project/many' -Limit 3|ConvertTo-Json -Depth 20 -Compress")
        self.assertEqual(len(cap['rows']), 3)
        self.assertTrue(cap['truncated'])

    def test_dispatcher_updates_old_helper_before_tree_and_quotes_path(self):
        installed = self.home / '.local/share/remote-disk'
        installed.mkdir(parents=True, exist_ok=True)
        (installed / 'server-disk.sh').write_text('#!/bin/bash\nexit 77\n')
        command = '. ' + quote(ROOT / 'build/Wizard.Common.ps1') + ''';
function Invoke-WizardSsh($Root,$Command,$InputText='',$Timeout=60){
    Invoke-DiskProcess 'bash' @('-c',$Command) -InputText $InputText -TimeoutSeconds $Timeout
};'''
        command += 'Invoke-WizardStep ' + quote(self.home / 'launcher') + ' ' + quote(ROOT)
        command += " DiskTree ([pscustomobject]@{base=" + quote(self.home / 'Disk') + ';path=' + quote("Project/O'Brien") + '})|ConvertTo-Json -Depth 30 -Compress'
        result = self.ps(command)
        self.assertEqual(result['union']['parent'], "Project/O'Brien")
        self.assertEqual(result['union']['rows'][0]['path'], "Project/O'Brien/a.txt")
        self.assertEqual(result['union']['rows'][0]['presence'], 'both')
        self.assertEqual((installed / 'server-disk.sh').read_bytes(), (ROOT / 'disk/server-disk.sh').read_bytes().replace(b'\r', b''))
        # The saved device policy is unchanged when the browser only loads children.
        self.assertFalse((self.home / 'local/RemoteDisk/selection.json').exists())

    def test_whole_unopened_selection_uses_existing_policy_format(self):
        result = self.ps('. ' + quote(ROOT / 'disk/Disk.Common.ps1') +
                         ';$s=\'{"schema":1,"paths":["Project"]}\'|ConvertFrom-Json;' +
                         '@{paths=@(Get-ProjectSelection Project $s);rules=(New-SelectionIgnores @(Get-ProjectSelection Project $s))}|ConvertTo-Json -Compress')
        self.assertEqual(result['paths'], ['.'])
        expected = '#escape=\\\n' + (ROOT / 'disk/stignore.txt').read_text().replace('\r', '').rstrip('\n') + '\n// RemoteDisk selective v1\n'
        self.assertEqual(result['rules'], expected)


if __name__ == '__main__':
    unittest.main()
