import subprocess
import time
import threading

def run_dump():
    args = [
        'ssh.exe', '-F', r'C:\Users\user\.ssh\config',
        '-i', r'C:\Users\user\AppData\Local\RemoteAgents\ssh-profiles\f05e1ca914064b309f1f4900c6bc9da3\id_ed25519',
        '-o', 'ProxyJump=sparfum', '-o', 'StrictHostKeyChecking=no',
        '-p', '22', 'root@109.199.110.63',
        'timeout 10 tcpdump -nn -v -s 128 port 80'
    ]
    r = subprocess.run(args, capture_output=True, text=True)
    print("=== CONTABO TCPDUMP PORT 80 ===\n", r.stdout)

t = threading.Thread(target=run_dump)
t.start()
time.sleep(2)

p = subprocess.Popen([
    r'C:\Program Files\FlyFrogLLC\Happ\core\xray.exe',
    'run', '-c', r'C:\work\AiServerAutoSettings\test-cf-directip.json'
], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

time.sleep(2)
try:
    c = subprocess.run([
        'curl.exe', '-s', '--connect-timeout', '5', '--max-time', '6',
        '-x', 'socks5h://127.0.0.1:10898', 'https://api.ipify.org'
    ], capture_output=True, text=True)
finally:
    p.terminate()

t.join()
