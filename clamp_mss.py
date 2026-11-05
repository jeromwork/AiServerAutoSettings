import subprocess

remote_cmd = """
iptables -t mangle -F
iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1280
iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1280
iptables -t mangle -L -n -v
"""

args = [
    'ssh.exe', '-F', r'C:\Users\user\.ssh\config',
    '-i', r'C:\Users\user\AppData\Local\RemoteAgents\ssh-profiles\f05e1ca914064b309f1f4900c6bc9da3\id_ed25519',
    '-o', 'ProxyJump=sparfum', '-o', 'StrictHostKeyChecking=no',
    '-p', '22', 'root@109.199.110.63',
    remote_cmd
]

r = subprocess.run(args, capture_output=True, text=True)
print("STDOUT:\n", r.stdout)
print("STDERR:\n", r.stderr)
