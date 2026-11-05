import subprocess
import time

p = subprocess.Popen([
    r'C:\Program Files\FlyFrogLLC\Happ\core\xray.exe',
    'run', '-c', r'C:\work\AiServerAutoSettings\test-cf-directip.json'
], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

time.sleep(2)
try:
    c = subprocess.run([
        'curl.exe', '-s', '--connect-timeout', '4', '--max-time', '5',
        '-x', 'socks5h://127.0.0.1:10898', 'https://api.ipify.org'
    ], capture_output=True, text=True)
finally:
    time.sleep(1)
    p.terminate()
    out, _ = p.communicate(timeout=2)
    with open(r'C:\work\AiServerAutoSettings\xray_full_https_debug.log', 'w', encoding='utf-8') as f:
        f.write(out)

print("Log written, length:", len(out))
