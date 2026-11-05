import subprocess
import time

p = subprocess.Popen([
    r'C:\Program Files\FlyFrogLLC\Happ\core\xray.exe',
    'run', '-c', r'C:\work\AiServerAutoSettings\test-cf-directip.json'
], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

time.sleep(2)
try:
    # Test with python urllib / socket through socks5
    py_code = """
import urllib.request
import socket

# Test HTTP
opener = urllib.request.build_opener(urllib.request.ProxyHandler({'http': 'http://127.0.0.1:10899', 'https': 'http://127.0.0.1:10899'}))
try:
    resp = opener.open('http://api.ipify.org', timeout=5).read().decode()
    print('HTTP via HTTP-inbound:', resp)
except Exception as e:
    print('HTTP err:', e)

try:
    resp = opener.open('https://api.ipify.org', timeout=8).read().decode()
    print('HTTPS via HTTP-inbound:', resp)
except Exception as e:
    print('HTTPS err:', e)
"""
    c = subprocess.run(['python', '-c', py_code], capture_output=True, text=True)
    print("PY STDOUT:\n", c.stdout)
    print("PY STDERR:\n", c.stderr)
finally:
    p.terminate()
