#!/usr/bin/env bash
# Managed AmneziaWG server. Dependencies and container image download on the VPS.
# stdout is a private client config, consumed directly into an ACL-protected file.
set -Eeuo pipefail
umask 077
[[ $(id -u) == 0 ]] || exit 3
endpoint=${1:?server address required}
client=${2:?client id required}
[[ $endpoint =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$ && $client =~ ^[a-f0-9]{32}$ ]] || exit 4
source /etc/os-release
[[ $ID == ubuntu ]] || { echo 'AmneziaWG requires Ubuntu.' >&2; exit 5; }
[[ $(uname -m) == x86_64 ]] || { echo 'This pinned VPN image requires x86_64.' >&2; exit 5; }
base=/var/lib/remote-agents-vpn
image=amneziavpn/amneziawg-go@sha256:cbafc02b8373a83f428272db6d8001b37bc02e6211cbd8c0cb4e2e3759b12b72
name=remoteagents-awg
# Refuse symlinks or pre-existing, user-writable state before privileged writes.
for path in /var /var/lib "$base"; do
    if [[ -e $path || -L $path ]]; then
        [[ ! -L $path && $(stat -c %u "$path") == 0 && -z $(find "$path" -maxdepth 0 -perm /022 -print -quit) ]] || exit 6
    fi
done
mkdir -p "$base"
chmod 700 "$base"
exec 9>"$base/lock"
flock -n 9 || { echo 'VPN setup already running.' >&2; exit 7; }
if [[ ! -f $base/managed-v1 ]]; then
    # Heuristic preflight, not a universal VPN detector. Never alter an existing VPN.
    if ip -o link show | grep -qiE ': (tun|tap|wg|awg|tailscale|zt)[^:]*:'; then
        echo 'Existing tunnel found on VPS; automatic VPN setup skipped to preserve it.' >&2; exit 13
    fi
    if command -v docker >/dev/null && docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -qiE 'amnezia|wireguard|openvpn|tailscale|xray|vless'; then
        echo 'Existing VPN container found; automatic VPN setup skipped to preserve it.' >&2; exit 13
    fi
fi
if ! command -v docker >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >&2
    apt-get install -y --no-install-recommends docker.io >&2
fi
systemctl start docker
docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image" >&2
if docker inspect "$name" >/dev/null 2>&1; then
    [[ -f $base/managed-v1 && $(docker inspect -f '{{index .Config.Labels "remoteagents.managed"}}' "$name") == awg-v1 ]] || {
        echo 'Existing container is not managed by this installer.' >&2; exit 8;
    }
fi
if [[ ! -f $base/managed-v1 ]]; then
    # Keep a single dedicated subnet; do not disturb existing VPNs or routes.
    if ip -4 route show | grep -qE '(^| )10\.203\.77\.'; then
        echo 'VPN subnet is already in use.' >&2; exit 9
    fi
    for port in $(seq 51820 51840); do
        if ! ss -H -lun | awk '{print $5}' | grep -qE ":${port}$"; then break; fi
    done
    if ss -H -lun | awk '{print $5}' | grep -qE ":${port}$"; then exit 10; fi
    # Generate all secrets inside a container on the server, never in shell argv.
    docker run --rm -i --network none -v "$base:/state" --entrypoint /bin/sh "$image" <<'KEYS'
set -eu
umask 077
awg genkey > /state/server.key
awg pubkey < /state/server.key > /state/server.pub
KEYS
    printf '%s\n' "$port" > "$base/port"
    key=$(cat "$base/server.key")
    cat > "$base/awg0.conf" <<CONFIG
[Interface]
PrivateKey = $key
Address = 10.203.77.1/24
ListenPort = $port
MTU = 1280
Jc = 4
Jmin = 40
Jmax = 70
S1 = 0
S2 = 0
H1 = 1324578123
H2 = 1834739212
H3 = 1547892365
H4 = 1789234561
CONFIG
    cat > "$base/start.sh" <<'START'
#!/bin/sh
set -eu
export WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go
awg-quick up /state/awg0.conf
iptables -A FORWARD -i awg0 -j ACCEPT
iptables -A FORWARD -o awg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -t nat -A POSTROUTING -s 10.203.77.0/24 -o eth0 -j MASQUERADE
exec tail -f /dev/null
START
    printf 'awg-v1\n' > "$base/managed-v1"
fi
if ! docker inspect "$name" >/dev/null 2>&1; then
    port=$(cat "$base/port")
    docker run -d --name "$name" --label remoteagents.managed=awg-v1 --restart unless-stopped \
        --cap-add NET_ADMIN --device /dev/net/tun --sysctl net.ipv4.ip_forward=1 \
        -p "$port:$port/udp" -v "$base:/state" --entrypoint /bin/sh "$image" /state/start.sh >&2
else
    docker start "$name" >&2
fi
ready=false
for attempt in $(seq 1 30); do
    if docker exec "$name" awg show awg0 >/dev/null 2>&1; then ready=true; break; fi
    sleep 1
done
[[ $ready == true ]] || { echo 'AmneziaWG interface did not start.' >&2; exit 11; }
mkdir -p "$base/clients"
config="$base/clients/$client.conf"
if [[ ! -f $config ]]; then
    for address in $(seq 2 250); do
        if ! grep -qF "AllowedIPs = 10.203.77.$address/32" "$base/awg0.conf"; then break; fi
    done
    if grep -qF "AllowedIPs = 10.203.77.$address/32" "$base/awg0.conf"; then exit 12; fi
    docker exec -i "$name" /bin/sh <<'CLIENT_KEYS'
set -eu
umask 077
awg genkey > /state/client.pending.key
awg pubkey < /state/client.pending.key > /state/client.pending.pub
awg genpsk > /state/client.pending.psk
CLIENT_KEYS
    private=$(cat "$base/client.pending.key")
    public=$(cat "$base/client.pending.pub")
    psk=$(cat "$base/client.pending.psk")
    server_public=$(cat "$base/server.pub")
    port=$(cat "$base/port")
    # Only the new peer changes; existing peers remain in the interface.
    cat >> "$base/awg0.conf" <<PEER

[Peer]
PublicKey = $public
PresharedKey = $psk
AllowedIPs = 10.203.77.$address/32
PEER
    docker exec "$name" awg set awg0 peer "$public" preshared-key /state/client.pending.psk allowed-ips "10.203.77.$address/32"
    cat > "$config.tmp" <<CLIENT
[Interface]
PrivateKey = $private
Address = 10.203.77.$address/32
DNS = 1.1.1.1
MTU = 1280
Jc = 4
Jmin = 40
Jmax = 70
S1 = 0
S2 = 0
H1 = 1324578123
H2 = 1834739212
H3 = 1547892365
H4 = 1789234561

[Peer]
PublicKey = $server_public
PresharedKey = $psk
Endpoint = $endpoint:$port
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CLIENT
    mv "$config.tmp" "$config"
    rm -f "$base/client.pending.key" "$base/client.pending.pub" "$base/client.pending.psk"
fi
cat "$config"
