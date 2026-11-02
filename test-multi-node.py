"""Synthetic sources and public bindings only. No VPS/account/VPN access."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import socket
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

import server_node_catalog as nodes


def load(name, file):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(file))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


sync=load('shared_sync','server-sync.py')
adapter=load('node_adapter','codex-windows-bridge.py')
broker=load('node_broker','codex-bridge-session.py')


class SharedProjectTests(unittest.TestCase):
    def test_two_hosts_repeat_attach_preserves_server_and_scope(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent=Path(temporary);base=parent/'projects';base.mkdir()
            first=parent/'a';first.mkdir();second=parent/'b';second.mkdir()
            content=b'initial seed'
            manifest={'schema':1,'projectId':'p-shared','hostId':'home','scopeMode':'folder','allowedRoots':['.'],'files':[{'path':'app.js','size':len(content),'sha256':hashlib.sha256(content).hexdigest()}]}
            original=first/'seed-manifest.json';original.write_text(json.dumps(manifest),'utf-8')
            archive=first/'seed.zip'
            with zipfile.ZipFile(archive,'w') as stream:stream.writestr('app.js',content)
            args=SimpleNamespace(base=str(base),project='p-shared',host='home',manifest=str(original),archive=str(archive))
            with contextlib.redirect_stdout(io.StringIO()):
                sync.seed(args)
                (first/'configured.json').write_text(json.dumps({'projectId':'p-shared','hostId':'home'}),'utf-8')
                sync.register_project(args)
                server=base/'p-shared'/'app.js';server.write_text('server newer','utf-8')
                (base/'p-shared'/'added.ts').write_text('server addition','utf-8')
                other=SimpleNamespace(base=str(base),project='p-shared',host='laptop',manifest=str(second/'seed-manifest.json'),archive=str(archive))
                sync.attach(other);attached=json.loads(Path(other.manifest).read_text('utf-8'))
                sync.attach(other)
                self.assertEqual(server.read_text('utf-8'),'server newer')
                self.assertEqual(attached,dict(manifest,hostId='laptop'))
                self.assertFalse((second/'seed.zip').exists())
                (second/'configured.json').write_text(json.dumps({'projectId':'p-shared','hostId':'laptop'}),'utf-8')
                sync.register_project(other)
                for current in (args,other):
                    current.output=str(Path(current.manifest).parent/'snapshot.json');current.refresh_ignores=True
                    sync.snapshot(current)
                    snapshot=json.loads(Path(current.output).read_text('utf-8'))
                    self.assertEqual(snapshot['hostId'],current.host)
                    self.assertEqual({f['path'] for f in snapshot['files']},{'app.js','added.ts'})
                with self.assertRaises(ValueError):sync.seed(args)
                attached['allowedRoots']=['src'];Path(other.manifest).write_text(json.dumps(attached),'utf-8')
                with self.assertRaises(ValueError):sync.attach(other)
                other.project='p-missing'
                with self.assertRaises(FileNotFoundError):sync.attach(other)
            self.assertEqual(server.read_text('utf-8'),'server newer')

    def test_failed_ignore_replacement_preserves_previous_policy(self):
        with tempfile.TemporaryDirectory() as temporary:
            base=Path(temporary);workspace=base/'p-fixture';workspace.mkdir()
            (workspace/'app.js').write_text('fixture','utf-8')
            ignore=workspace/'.stignore';ignore.write_text('!/app.js\n*\n','utf-8')
            manifest=base/'manifest.json';manifest.write_text(json.dumps({'projectId':'p-fixture','hostId':'home','scopeMode':'folder','allowedRoots':['.'],'files':[{'path':'app.js'}]}),'utf-8')
            args=SimpleNamespace(base=str(base),project='p-fixture',host='home',manifest=str(manifest),output=str(base/'snapshot.json'),refresh_ignores=True)
            with patch.object(sync.os,'replace',side_effect=OSError('fixture failure')):
                with self.assertRaises(OSError):sync.snapshot(args)
            self.assertEqual(ignore.read_text('utf-8'),'!/app.js\n*\n')
            self.assertFalse(list(base.glob('.sync-ignore-*')))


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.home=Path(self.temp.name);self.catalog=self.home/'nodes'
        self.data=[]
        for i,host in enumerate(('home','laptop')):
            label='win-'+str(i)*28
            data={'projectId':'p-shared','hostId':host,'deviceLabel':label,'deviceName':host.upper(),'windowsReplica':'C:\\replica\\'+host,'serverWorkspace':str(self.home/'work/projects/p-shared'),'socketPath':str(self.home/'.local/state/codex-remote'/(label+'.sock')),'allowShell':True}
            nodes.register(self.catalog,data,self.home);self.data.append(data)
        self.home_patch=patch.object(adapter.Path,'home',return_value=self.home);self.home_patch.start();self.addCleanup(self.home_patch.stop)

    def call(self,name,values):
        result=adapter.dispatch({'method':'tools/call','params':{'name':name,'arguments':values}},None,str(self.catalog))
        return json.loads(result['content'][0]['text'])

    def status(self,data):
        return {'ok':True,'device':data['deviceLabel'],'workspace':data['windowsReplica'],'file_mutations_enabled':False,'sync_guard':{'required':True,'project_id':data['projectId'],'host_id':data['hostId']},'shell_enabled':True,'capabilities':{'node':{'available':True}}}

    def test_inventory_is_live_and_never_reroutes_missing_or_wrong_target(self):
        def exchange(path,op,args,binding=None,timeout=100):
            if path==self.data[1]['socketPath']:raise ConnectionError('asleep')
            return self.status(self.data[0]) if op=='status' else {'ok':True,'output':'home only'}
        with patch.object(adapter,'exchange',side_effect=exchange) as transport:
            rows=self.call('windows_devices',{})['devices']
            self.assertEqual([row['available'] for row in rows],[True,False])
            values={'projectId':'p-shared','hostId':'laptop','taskId':'build','command':'test'}
            self.assertFalse(self.call('windows_command',values)['ok'])
            self.assertFalse(self.call('windows_command',dict(values,hostId='unregistered'))['ok'])
            self.assertFalse(self.call('windows_command',dict(values,projectId='p-wrong'))['ok'])
            result=self.call('windows_command',dict(values,hostId='home'))
            self.assertEqual(result['target'],{'projectId':'p-shared','hostId':'home'})
            commands=[call for call in transport.call_args_list if call.args[1]=='command']
            self.assertEqual(len(commands),1)
            self.assertEqual(commands[0].args[0],self.data[0]['socketPath'])
            with self.assertRaises(ValueError):self.call('windows_command',{'command':'test'})
            with self.assertRaises(ValueError):self.call('windows_command',{'projectId':'p-shared','hostId':'home','command':'test'})

    def test_status_binding_mismatch_blocks_operation(self):
        with patch.object(adapter,'exchange',return_value=self.status(self.data[1])) as transport:
            result=self.call('windows_command',{'projectId':'p-shared','hostId':'home','taskId':'build','command':'test'})
            self.assertFalse(result['ok']);self.assertEqual(transport.call_count,1)

    def test_reregister_does_not_silently_replace_existing_host_binding(self):
        nodes.register(self.catalog,self.data[0],self.home)
        with self.assertRaises(ValueError):
            nodes.register(self.catalog,dict(self.data[0],windowsReplica='C:\\different'),self.home)
        self.assertEqual(len(nodes.records(self.catalog,self.home)),2)


@unittest.skipUnless(os.name=='posix','Real Unix socket brokers on Linux')
class ConcurrentBrokerTests(unittest.TestCase):
    def test_two_connected_devices_and_legacy_socket_denied(self):
        with tempfile.TemporaryDirectory(prefix='ra-brokers-') as temporary:
            root=Path(temporary);root.chmod(0o700);threads=[];resources=[];errors=[]
            def start(host):
                listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen(4)
                resources.append(listener)
                binding={'projectId':'p-shared','hostId':host,'deviceLabel':host,'windowsReplica':'C:\\replica\\'+host}
                def executor():
                    try:
                        # Only one exact status call reaches each fake executor.
                        conn,_=listener.accept()
                        with conn:
                            request=json.loads(conn.makefile('rb').readline())
                            self.assertEqual(request['binding'],binding)
                            self.assertEqual(request['token'],'a'*64)
                            conn.sendall(json.dumps({'ok':True,'host':host}).encode()+b'\n')
                    except Exception as exc:errors.append(exc)
                thread=threading.Thread(target=executor,daemon=True);thread.start();threads.append(thread)
                control,stop=socket.socketpair();resources.extend((control,stop))
                path=str(root/(host+'.sock'))
                config=dict(binding,token='a'*64,port=listener.getsockname()[1])
                def serve():
                    try:broker.serve(path,config,control)
                    except Exception as exc:errors.append(exc)
                thread=threading.Thread(target=serve,daemon=True);thread.start();threads.append(thread)
                return path,binding,stop
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    home=start('home');laptop=start('laptop')
                    deadline=time.monotonic()+5
                    while not all(Path(node[0]).exists() for node in (home,laptop)):
                        if time.monotonic()>deadline:raise AssertionError('Brokers unavailable')
                        time.sleep(.02)
                    for path,binding,_ in (home,laptop):
                        self.assertFalse(adapter.exchange(path,'status',{})['ok'])
                        self.assertFalse(adapter.exchange(path,'status',{},dict(binding,hostId='wrong'))['ok'])
                        self.assertEqual(adapter.exchange(path,'status',{},binding)['host'],binding['hostId'])
                    # Both sockets remain present; choosing laptop did not close home.
                    self.assertTrue(all(Path(node[0]).exists() for node in (home,laptop)))
                    home[2].send(b'stop');laptop[2].send(b'stop')
                    for thread in threads:thread.join(5);self.assertFalse(thread.is_alive())
                self.assertFalse(errors,errors)
            finally:
                for resource in resources:resource.close()


if __name__=='__main__':unittest.main()
