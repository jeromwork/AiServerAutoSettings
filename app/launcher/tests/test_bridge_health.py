"""Loopback broker heartbeat, no Windows/network outside this process."""
import importlib.util
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT=Path(__file__).resolve().parents[3]

class HeartbeatTests(unittest.TestCase):
    def run_broker(self, reply):
        with tempfile.TemporaryDirectory() as tmp:
            server=socket.socket();server.bind(('127.0.0.1',0));server.listen();server.settimeout(.1)
            stopped=threading.Event();requests=[]
            def accept():
                while not stopped.is_set():
                    try: client,_=server.accept()
                    except socket.timeout: continue
                    except OSError: break
                    with client:
                        client.settimeout(2)
                        frame=client.makefile('rb').readline()
                        requests.append(json.loads(frame))
                        client.sendall(json.dumps(reply).encode()+b'\r\n')
            worker=threading.Thread(target=accept);worker.start()
            config=dict(token='b'*64,port=server.getsockname()[1],device='test',deviceLabel='test',hostId='host',projectId='control',windowsReplica=r'C:\Control',controlOnly=True,heartbeat=True)
            code="import json,sys; from codex_bridge_session import serve; serve(sys.argv[1],json.loads(sys.stdin.buffer.readline()),sys.stdin.buffer,heartbeat_interval=.05,heartbeat_timeout=.1)"
            # Import by real path; production module filename has hyphens.
            code="import importlib.util,json,sys; s=importlib.util.spec_from_file_location('broker',sys.argv[2]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); m.serve(sys.argv[1],json.loads(sys.stdin.buffer.readline()),sys.stdin.buffer,heartbeat_interval=.05,heartbeat_timeout=.1)"
            p=subprocess.Popen([sys.executable,'-u','-c',code,str(Path(tmp)/'bridge.sock'),str(ROOT/'codex-bridge-session.py')],cwd=ROOT,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            try:
                p.stdin.write(json.dumps(config).encode()+b'\r\n');p.stdin.flush()
                def line():
                    self.assertTrue(select.select([p.stdout],[],[],5)[0], 'bounded broker response')
                    return json.loads(p.stdout.readline())
                self.assertEqual(line()['state'],'connected')
                state=line()['state']
                if reply.get('host_id')=='host':
                    self.assertEqual(state,'heartbeat')
                    # Server TCP forward disappears while broker/parent remain alive.
                    stopped.set();server.close();worker.join(2)
                    while line()['state']!='unavailable': pass
                    self.assertEqual(line()['state'],'unavailable');self.assertEqual(line()['state'],'unavailable')
                else:
                    self.assertEqual(state,'unavailable');self.assertEqual(line()['state'],'unavailable');self.assertEqual(line()['state'],'unavailable')
                self.assertNotEqual(p.wait(5),0)
                self.assertTrue(requests)
                self.assertTrue(all(r['op']=='status' and r['binding']['hostId']=='host' for r in requests))
                self.assertFalse((Path(tmp)/'bridge.sock').exists())
            finally:
                stopped.set();server.close();worker.join(2)
                if p.poll() is None:p.kill();p.wait(5)
                p.stdin.close();p.stdout.close();p.stderr.close()
    def test_authenticated_roundtrip_then_dead_reverse_forward(self):
        self.run_broker(dict(ok=True,device='test',workspace=r'C:\Control',control_only=True,project_id='control',host_id='host'))
    def test_wrong_executor_binding_never_healthy(self):
        self.run_broker(dict(ok=True,device='test',workspace=r'C:\Control',control_only=True,project_id='control',host_id='other'))

if __name__=='__main__':unittest.main(verbosity=2)
