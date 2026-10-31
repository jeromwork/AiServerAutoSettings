"""Synthetic Git-scope regressions. Never reads an existing project or auth."""
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
import unittest.mock
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path
from types import SimpleNamespace

spec=importlib.util.spec_from_file_location('public_sync',Path(__file__).with_name('server-sync.py'))
sync=importlib.util.module_from_spec(spec);spec.loader.exec_module(sync)

class GitScopeTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(prefix='public-git-scope-')
        self.addCleanup(self.temporary.cleanup)
        self.base=Path(self.temporary.name)
        self.root=self.base/'p-fixture';self.root.mkdir()
        self.manifest=self.base/'seed.json'
        self.paths=['.gitignore','src/index.js','COPYING']
        self.write('.gitignore','ignored/\n*.generated.ts\n!src/keep.generated.ts\n')
        self.write('src/index.js','public fixture')
        self.write('COPYING','public fixture')
        self.document={'projectId':'p-fixture','hostId':'h-fixture','scopeMode':'git','allowedRoots':['.'],'gitPaths':self.paths,'files':[{'path':p} for p in self.paths]}
        self.manifest.write_text(json.dumps(self.document),'utf-8')
        self.args=SimpleNamespace(base=str(self.base),project='p-fixture',host='h-fixture',manifest=str(self.manifest),output=str(self.base/'snapshot.json'),refresh_ignores=True)

    def write(self,path,text='public fixture'):
        target=self.root/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_text(text,'utf-8')

    def snapshot(self):
        with contextlib.redirect_stdout(io.StringIO()):sync.snapshot(self.args)
        return {f['path'] for f in json.loads(Path(self.args.output).read_text('utf-8'))['files']}

    def test_live_git_rules_new_sources_and_tracked_file_names(self):
        for path in ['src/new.ts','src/drop.generated.ts','src/keep.generated.ts','ignored/source.js','node_modules/a.js','vendor/a.php','build/a.js','src/archive.zip','new.unknown']:
            self.write(path)
        self.write('src/.gitignore','nested/\n')
        self.write('src/nested/drop.ts')
        expected=set(self.paths)|{'src/new.ts','src/keep.generated.ts','src/.gitignore'}
        self.assertEqual(expected,self.snapshot())
        self.assertFalse((self.root/'.git').exists())
        self.assertTrue((self.base/'.git-scope-p-fixture-h-fixture'/'index').is_file())
        # Ignoring a previously announced new file must stop its future transfer.
        self.write('.gitignore','src/new.ts\nignored/\n*.generated.ts\n!src/keep.generated.ts\n')
        self.assertEqual(expected-{'src/new.ts'},self.snapshot())
        self.assertNotIn('!/src/new.ts',(self.root/'.stignore').read_text('utf-8').splitlines())

    def test_tracked_ignores_and_deletion_tombstones(self):
        self.write('.gitignore','src/\n')
        self.assertIn('src/index.js',self.snapshot())
        (self.root/'src/index.js').unlink()
        self.assertNotIn('src/index.js',self.snapshot())
        self.assertIn('!/src/index.js',(self.root/'.stignore').read_text('utf-8').splitlines())

    def test_denied_tracked_paths_and_noncanonical_scope_rejected(self):
        for value in ['node_modules/a.js','build/a.ts','src/auth.json','src/key.pem','./src/a.js','src//a.js','src/../a.js','src/a\n.js']:
            with self.subTest(value=value),self.assertRaises(ValueError):sync.safe_relative(value,['.'])
        altered=dict(self.document,gitPaths=self.paths+['extra.js'])
        with self.assertRaises(ValueError):sync.policy(altered)
        with self.assertRaises(ValueError):sync.policy(dict(self.document,scopeMode='other'))

    def test_nested_repository_is_excluded(self):
        self.write('nested/source.js')
        (self.root/'nested/.git').mkdir()
        self.assertNotIn('nested/source.js',self.snapshot())
        (self.root/'src/.git').mkdir()
        self.assertNotIn('src/index.js',self.snapshot())

    def test_symlink_fails_before_hashing(self):
        target=self.base/'outside.js';target.write_text('public fixture','utf-8')
        try:os.symlink(target,self.root/'src/link.js')
        except OSError as error:self.skipTest('Platform cannot create a test symlink: '+str(error.errno))
        with self.assertRaises(ValueError):self.snapshot()

    def test_metadata_cannot_be_inside_workspace(self):
        with self.assertRaises(ValueError):sync.git_scope(self.document,self.root/'manifest.json',self.root)

    def test_seed_and_runtime_configuration(self):
        records=[{'path':p,'size':(self.root/p).stat().st_size,'sha256':sync.digest(self.root/p)} for p in self.paths]
        self.document['files']=records
        self.manifest.write_text(json.dumps(self.document),'utf-8')
        archive=self.base/'seed.zip'
        with zipfile.ZipFile(archive,'w') as output:
            for path in self.paths:output.write(self.root/path,path)
        seed_base=self.base/'seeded'
        args=SimpleNamespace(base=str(seed_base),project='p-fixture',host='h-fixture',manifest=str(self.manifest),archive=str(archive))
        with contextlib.redirect_stdout(io.StringIO()):sync.seed(args)
        workspace=seed_base/'p-fixture'
        self.assertTrue((workspace/'src/index.js').is_file())
        self.assertFalse((workspace/'.git').exists())
        state=self.base/'state';state.mkdir()
        (state/'config.xml').write_text('<configuration><device id="fixture"/><options/><gui/></configuration>','utf-8')
        runtime_spec=importlib.util.spec_from_file_location('public_runtime',Path(__file__).with_name('server-sync-runtime.py'))
        runtime=importlib.util.module_from_spec(runtime_spec);runtime_spec.loader.exec_module(runtime)
        argv=['server-sync-runtime.py','configure','--state',str(state),'--binary','unused','--project','p-fixture','--host','h-fixture','--workspace',str(workspace),'--manifest',str(self.manifest),'--peer','A'*63,'--listen','31001','--tunnel','31002','--gui','31003']
        with unittest.mock.patch.object(sys,'argv',argv),unittest.mock.patch.object(os,'getuid',lambda:1000,create=True),contextlib.redirect_stdout(io.StringIO()):runtime.main()
        folder=ET.parse(state/'config.xml').getroot().find('folder')
        self.assertEqual('sendonly',folder.attrib['type'])
        self.assertEqual('true',folder.attrib['paused'])
        self.assertIn('!/src/index.js',(workspace/'.stignore').read_text('utf-8').splitlines())

class FolderScopeTests(unittest.TestCase):
    write=GitScopeTests.write
    snapshot=GitScopeTests.snapshot

    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(prefix='public-folder-scope-')
        self.addCleanup(self.temporary.cleanup)
        self.base=Path(self.temporary.name)
        self.root=self.base/'p-fixture';self.root.mkdir()
        self.manifest=self.base/'seed.json'
        self.paths=['.gitignore','src/index.js']
        self.write('.gitignore','ignored/\n')
        self.write('src/index.js')
        self.document={'projectId':'p-fixture','hostId':'h-fixture','scopeMode':'folder','allowedRoots':['.'],'files':[{'path':p} for p in self.paths]}
        self.manifest.write_text(json.dumps(self.document),'utf-8')
        self.args=SimpleNamespace(base=str(self.base),project='p-fixture',host='h-fixture',manifest=str(self.manifest),output=str(self.base/'snapshot.json'),refresh_ignores=True)

    def test_folder_new_deleted_denied_and_no_git_dependency(self):
        for path in ['src/new.py','ignored/public.ts','node_modules/a.js','vendor/a.php','build/a.js','src/archive.zip','new.unknown']:
            self.write(path)
        with unittest.mock.patch.object(sync.shutil,'which',return_value=None),unittest.mock.patch.object(sync,'git_command',side_effect=AssertionError('Folder scope invoked Git')):
            self.assertEqual(set(self.paths)|{'src/new.py','ignored/public.ts'},self.snapshot())
            (self.root/'src/new.py').unlink()
            self.assertNotIn('src/new.py',self.snapshot())
        self.assertIn('!/src/new.py',(self.root/'.stignore').read_text('utf-8').splitlines())
        self.assertEqual('folder',json.loads(Path(self.args.output).read_text('utf-8'))['scopeMode'])
        self.assertFalse((self.root/'.git').exists())
        self.assertFalse((self.base/'.git-scope-p-fixture-h-fixture').exists())

    def test_folder_large_allowed_file_is_never_silently_hidden(self):
        target=self.root/'src/large.txt'
        with target.open('wb') as output:output.truncate(21*1024*1024)
        self.assertIn('src/large.txt',self.snapshot())
        records={f['path']:f for f in json.loads(Path(self.args.output).read_text('utf-8'))['files']}
        self.assertEqual(21*1024*1024,records['src/large.txt']['size'])

    def test_folder_nested_repository_skipped_and_root_git_denied(self):
        self.write('nested/source.py')
        (self.root/'nested/.git').mkdir()
        self.assertNotIn('nested/source.py',self.snapshot())
        (self.root/'.git').mkdir()
        with self.assertRaises(ValueError):self.snapshot()

    def test_folder_policy_requires_whole_root_and_safe_seed_files(self):
        with self.assertRaises(ValueError):sync.policy(dict(self.document,allowedRoots=['src']))
        with self.assertRaises(ValueError):sync.policy(dict(self.document,files=[{'path':'source.unknown'}]))
        with self.assertRaises(ValueError):sync.policy(dict(self.document,files=[{'path':'node_modules/a.js'}]))

    def test_folder_seed_and_runtime_without_git(self):
        with unittest.mock.patch.object(sync.shutil,'which',return_value=None):GitScopeTests.test_seed_and_runtime_configuration(self)
        self.assertFalse((self.base/'.git-scope-p-fixture-h-fixture').exists())

    test_folder_symlink_fails_before_hashing=GitScopeTests.test_symlink_fails_before_hashing

if __name__=='__main__':unittest.main()
