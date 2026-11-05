import subprocess
import time
import socket

# On server, start a listener on 6443
remote_cmd = 'python3 -c "import socket; s=socket.socket(); s.bind((\'0.0.0.0\', 6443)); s.listen(1); print(\'READY\', flush=True); c, a = s.accept(); print(\'CONN FROM\', a, flush=True); c.sendall(b\'HELLO_PORT_6443\\n\'); c.close()"'

args = [
    'ssh.exe', '-F', r'C:\Users\user\.ssh\config',
    '-i', r'C:\Users\user\AppData\Local\RemoteAgents\ssh-profiles\f05e1ca914064b309f1f4900c6bc9da3\id_ed25519',
    '-o', 'ProxyJump=sparfum', '-o', 'StrictHostKeyChecking=no',
    '-p', '22', 'root@109.199.110.63',
    remote_cmd
]

p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
time.sleep(3)

sock = socket.socket()
sock.settimeout(4)
try:
    sock.connect(('109.199.110.63', 6443))
    data = sock.recv(1024)
    print("DIRECT TCP CLIENT RECEIVED:", data)
except Exception as e:
    print("DIRECT TCP CLIENT ERROR:", e)
finally:
    sock.close()

out, err = p.communicate(timeout=3)
print("SERVER OUT:\n", out)
