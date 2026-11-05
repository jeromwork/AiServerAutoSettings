import subprocess

remote_cmd = """
cat << 'EOF' > /etc/remoteagents-reality443/config.json
{
  "log": {
    "loglevel": "debug"
  },
  "inbounds": [
    {
      "tag": "reality-in",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "e01d4719-5cf6-4bf5-a001-3d7c900bcbdf",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "target": "gateway.icloud.com:443",
          "serverNames": [
            "gateway.icloud.com"
          ],
          "privateKey": "WBp6Vcj1Qi2ymiOm_rLJXt__gPAr7_vVOxUHXV7LbXw",
          "shortIds": [
            "0c8a5799f0787f1f"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
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
          "reality-in"
        ],
        "outboundTag": "residential-out"
      }
    ]
  }
}
EOF

systemctl restart remoteagents-reality443
systemctl status remoteagents-reality443 --no-pager
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
