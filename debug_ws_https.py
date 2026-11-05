import subprocess
import time
import threading

def capture_server():
    args = [
        'ssh.exe', '-F', r'C:\Users\user\.ssh\config',
        '-i', r'C:\Users\user\AppData\Local\RemoteAgents\ssh-profiles\f05e1ca914064b309f1f4900c6bc9da3\id_ed25519',
        '-o', 'ProxyJump=sparfum', '-o', 'StrictHostKeyChecking=no',
        '-p', '22', 'root@109.199.110.63',
        'timeout 10 tcpdump -nn -v -s 0 port 80'
    ]
    r = subprocess.run(args, capture_output=True, text=True)
    print("=== SERVER TCPDUMP PORT 80 ===\n", r.stdout[:3000])

t = threading.Thread(target=capture_server)
t.start()
time.sleep(2)

# Start local xray with test-user-happ-hostfix.json
xray = subprocess.Popen([
    r'C:\Program Files\FlyFrogLLC\Happ\core\xray.exe',
    'run', '-c', r'C:\work\AiServerAutoSettings\test-user-happ-hostfix.json'
], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

time.sleep(2)
try:
    print("--- CURL REQUEST HTTPS ---")
    c = subprocess.run([
        'curl.exe', '-v', '--connect-timeout', '5', '--max-time', '6',
        '-x', 'socks5h://127.0.0.1:10898', 'https://api.ipify.org'
    ], capture_output=True, text=True)
    print("CURL STDOUT:", c.stdout)
    print("CURL STDERR:\n", c.stderr)
finally:
    xray.terminate()
    out, _ = xray.communicate(timeout=2)
    print("=== LOCAL XRAY LOG ===\n", out[-1500:])

t.join()
