import subprocess

remote_cmd = """
cat << 'EOF' > /usr/local/etc/remoteagents-happ/config.json
{
  "log": {
    "loglevel": "debug"
  },
  "inbounds": [
    {
      "tag": "cloudflare-ws",
      "listen": "0.0.0.0",
      "port": 80,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "e01d4719-5cf6-4bf5-a001-3d7c900bcbdf"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vless-ws"
        }
      }
    },
    {
      "tag": "local-socks",
      "listen": "127.0.0.1",
      "port": 1080,
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "residential-out",
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "104.253.198.239",
            "port": 8017
          }
        ]
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "cloudflare-ws",
          "local-socks"
        ],
        "outboundTag": "residential-out"
      }
    ]
  }
}
EOF

systemctl restart remoteagents-happ
systemctl status remoteagents-happ --no-pager
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
