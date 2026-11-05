import subprocess

args = [
    'ssh.exe', '-F', r'C:\Users\user\.ssh\config',
    '-i', r'C:\Users\user\AppData\Local\RemoteAgents\ssh-profiles\f05e1ca914064b309f1f4900c6bc9da3\id_ed25519',
    '-o', 'ProxyJump=sparfum', '-o', 'StrictHostKeyChecking=no',
    '-p', '22', 'root@109.199.110.63',
    'python3 -c "import time, urllib.request; import urllib.error; t0=time.time(); [urllib.request.urlopen(\'http://api.ipify.org\')]; print(\'direct:\', time.time()-t0)"; curl -o /dev/null -s -w "socks5 time: %{time_total}s\n" -x socks5://104.253.198.239:8017 https://api.ipify.org; curl -o /dev/null -s -w "http proxy time: %{time_total}s\n" -x http://104.253.198.239:8017 https://api.ipify.org'
]
r = subprocess.run(args, capture_output=True, text=True)
print("STDOUT:\n", r.stdout)
print("STDERR:\n", r.stderr)
