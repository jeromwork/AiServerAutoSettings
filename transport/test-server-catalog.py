#!/usr/bin/env python3
"""Real catalog helper in a disposable HOME; never contacts a server."""
import importlib.util,json,os,subprocess,tempfile,unittest
from pathlib import Path
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('catalog',HERE/'server-transport-catalog.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.home=Path(self.temp.name)
        self.empty={'schema':1,'entries':[],'hops':[],'relays':[],'cdn':[]}
    def tearDown(self):self.temp.cleanup()
    def call(self,action='get',data=None):
        return subprocess.run(['python3',str(HERE/'server-transport-catalog.py'),action],env={**os.environ,'HOME':str(self.home)},input=json.dumps(data,ensure_ascii=False).replace('\n','\r\n')+'\r\n' if data else '',text=True,capture_output=True,timeout=5)
    def get(self):
        p=self.call();self.assertEqual(p.returncode,0,p.stderr);return json.loads(p.stdout)
    def test_empty_server_and_idempotence(self):
        self.assertEqual(self.get(),self.empty)
        f=self.home/'.config/remoteagents/transport-catalog.json';before=f.stat().st_mtime_ns
        self.assertEqual(self.get(),self.empty);self.assertEqual(f.stat().st_mtime_ns,before)
    def test_put_and_crlf(self):
        current=self.get();new={**current,'relays':[{'name':'my-relay','host':'relay.example.invalid','port':8443,'enabled':True}]}
        self.assertEqual(self.call('put',{'expected':current,'catalog':new}).returncode,0)
        f=self.home/'.config/remoteagents/transport-catalog.json';f.write_bytes(f.read_bytes().replace(b'\n',b'\r\n'))
        self.assertEqual(self.get(),new);self.assertEqual(f.stat().st_mode&0o777,0o600)
    def test_concurrent_editor_preserved(self):
        initial=self.get();new={**initial,'hops':[{'name':'other','ssh':'my-hop','enabled':False}]}
        self.assertEqual(self.call('put',{'expected':initial,'catalog':new}).returncode,0)
        self.assertNotEqual(self.call('put',{'expected':initial,'catalog':initial}).returncode,0)
        self.assertEqual(self.get(),new)
    def test_private_fields_and_paths_rejected(self):
        for group,field in [('entries','password'),('hops','private_key_path'),('relays','secret'),('cdn','configPath')]:
            data={**self.empty,group:[{'name':'safe',field:'private-value'}]}
            with self.assertRaises(ValueError):module.validate(data)
        with self.assertRaises(ValueError):module.validate({**self.empty,'token':'private'})
    def test_schema_and_names(self):
        for data in [{'schema':2},{'schema':1,'hops':{}},{**self.empty,'hops':[{'name':'x','ssh':'-oProxyCommand=bad'}]},{**self.empty,'relays':[{'name':'x','host':'host','port':True}]},{**self.empty,'entries':[{'name':'x','ssh':'alias'}],'hops':[{'name':'X','ssh':'alias'}]}]:
            with self.assertRaises(ValueError):module.validate(data)
    def test_full_public_transport_schema(self):
        data={**self.empty,'entries':[{'name':'entry','ssh':'entry-alias','kinds':['ws-cdn'],'enabled':True}],'hops':[{'name':'hop','ssh':'hop-alias'}],'relays':[{'name':'relay','host':'192.0.2.1','port':443}],'cdn':[{'name':'cdn','domain':'cdn.example.invalid','entry':'entry','path':'/connect'}]}
        self.assertEqual(module.validate(data),data)
    def test_symlink_refused_without_touching_target(self):
        directory=self.home/'.config/remoteagents';directory.mkdir(parents=True)
        target=self.home/'other';target.write_text('keep')
        (directory/'transport-catalog.json').symlink_to(target)
        self.assertNotEqual(self.call().returncode,0);self.assertEqual(target.read_text(),'keep')
    def test_catalog_error_does_not_echo_secrets(self):
        current=self.get();p=self.call('put',{'expected':current,'catalog':{**current,'secret':'sensitive-test-value'}})
        self.assertNotEqual(p.returncode,0);self.assertNotIn('sensitive-test-value',p.stdout+p.stderr)
if __name__=='__main__':unittest.main()
