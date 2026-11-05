import subprocess
import time

p = subprocess.Popen([
    r'C:\Program Files\FlyFrogLLC\Happ\core\xray.exe',
    'run', '-c', r'C:\work\AiServerAutoSettings\test-client-reality-443.json'
], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

time.sleep(2)
try:
    urls = [
        'http://api.ipify.org',
        'http://cp.cloudflare.com/generate_204',
        'https://cp.cloudflare.com/generate_204',
        'https://www.google.com',
        'https://2ip.ru'
    ]
    for u in urls:
        t0 = time.time()
        c = subprocess.run([
            'curl.exe', '-s', '-o', 'NUL', '-w', '%{http_code} time=%{time_total}s',
            '--connect-timeout', '6', '--max-time', '10',
            '-x', 'socks5h://127.0.0.1:10896', u
        ], capture_output=True, text=True)
        print(f"{u:40}: res='{c.stdout.strip()}' err='{c.stderr.strip()}' ({time.time()-t0:.2f}s)")
finally:
    time.sleep(1)
    p.terminate()
    out, _ = p.communicate(timeout=2)
    with open(r'C:\work\AiServerAutoSettings\test_multi_https.log', 'w', encoding='utf-8') as f:
        f.write(out)
