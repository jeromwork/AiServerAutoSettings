#!/usr/bin/env bash
# Optional component. Run only after the owner selects server browser preparation.
set -Eeuo pipefail
umask 077
server_user=${1:-remoteagents}
[[ $server_user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo 'Invalid server user.' >&2; exit 2; }
[[ $(id -u) == 0 ]] || { echo 'Browser preparation requires root or sudo -n.' >&2; exit 3; }
source /etc/os-release
[[ $ID == ubuntu && ( $VERSION_ID == 22.04 || $VERSION_ID == 24.04 ) && $(dpkg --print-architecture) == amd64 ]] || {
  echo 'Optional server browser supports Ubuntu 22.04/24.04 amd64 only.' >&2; exit 4;
}
[[ -d /run/systemd/system ]] || { echo 'A running systemd system is required.' >&2; exit 5; }
user_id=$(id -u "$server_user")
[[ $user_id != 0 ]] || { echo 'Browser must use a non-root server account.' >&2; exit 6; }
user_home=$(getent passwd "$server_user" | cut -d: -f6)
[[ $user_home == /home/"$server_user" && -d $user_home && ! -L $user_home ]] || {
  echo 'Expected an existing managed account with a normal /home directory.' >&2; exit 7;
}
install_dir=/usr/local/lib/remoteagents-browser
unit=/etc/systemd/system/remoteagents-browser.service
[[ ! -e $install_dir || -f $install_dir/.remoteagents-managed ]] || { echo 'Unmanaged browser install directory exists.' >&2; exit 8; }
[[ ! -e $unit ]] || grep -q '^# Managed by remoteagents-browser$' "$unit" || { echo 'Unmanaged browser service exists.' >&2; exit 9; }
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl xvfb xauth x11-utils x11vnc openbox novnc python3-websockify dbus-x11 fonts-liberation
stage=$(mktemp -d /tmp/remoteagents-browser.XXXXXXXX)
trap 'rm -rf -- "$stage"' EXIT
# The official Google package, fetched over verified HTTPS; no third-party install script.
curl --fail --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
  'https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb' -o "$stage/chrome.deb"
[[ $(dpkg-deb -f "$stage/chrome.deb" Package) == google-chrome-stable && $(dpkg-deb -f "$stage/chrome.deb" Architecture) == amd64 ]] || {
  echo 'Unexpected browser package identity.' >&2; exit 10;
}
chmod 0755 "$stage"
chmod 0644 "$stage/chrome.deb"
apt-get install -y --no-install-recommends "$stage/chrome.deb"
install -d -m 0755 "$install_dir"
cat > "$install_dir/browser.py" <<'REMOTEAGENTS_BROWSER_PY'
#!/usr/bin/python3
"""A private server desktop. Never inspect an account profile or login cache."""
import os
from pathlib import Path
import re
import secrets
import signal
import subprocess
import sys
import time


def allowed_host(host):
    return bool(re.fullmatch(r"127\.0\.0\.1:[1-9][0-9]{0,4}", host or "")) and int(host.rsplit(":", 1)[1]) <= 65535


def allowed_origin(host, origin):
    return allowed_host(host) and origin == "http://" + host


def run_proxy():
    from websockify.websocketproxy import ProxyRequestHandler, WebSocketProxy

    class LocalRequest(ProxyRequestHandler):
        def do_GET(self):
            if not allowed_host(self.headers.get("Host")):
                self.send_error(403, "Loopback host required")
                return
            super().do_GET()

        def validate_connection(self):
            if not allowed_origin(self.headers.get("Host"), self.headers.get("Origin")):
                raise self.server.EClose("Same-origin browser required")
            super().validate_connection()

        def end_headers(self):
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Content-Security-Policy", "frame-ancestors 'none'")
            self.send_header("Referrer-Policy", "no-referrer")
            super().end_headers()

    WebSocketProxy(RequestHandlerClass=LocalRequest, listen_host="127.0.0.1", listen_port=6091,
                   unix_target="/run/remoteagents-browser/vnc.sock", web="/usr/share/novnc",
                   run_once=False, verbose=False).start_server()


def run_desktop():
    if os.getuid() == 0:
        raise RuntimeError("A non-root desktop account is required")
    os.umask(0o077)
    runtime = Path("/run/remoteagents-browser")
    profile = Path.home() / ".local/share/remoteagents/browser"
    profile.mkdir(parents=True, exist_ok=True, mode=0o700)
    if profile.is_symlink():
        raise RuntimeError("Browser profile cannot be a symlink")
    env = os.environ.copy()
    env.update(DISPLAY=":97", XAUTHORITY=str(runtime / "Xauthority"))
    # This fresh display cookie belongs only to our runtime; no existing credentials are read.
    subprocess.run(["xauth", "-q", "-f", env["XAUTHORITY"]],
                   input="add :97 . " + secrets.token_hex(16) + "\n", text=True, check=True)
    children = []

    def start(args):
        process = subprocess.Popen(args, env=env)
        children.append(process)
        return process

    def wait_until(predicate, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if any(child.poll() is not None for child in children):
                raise RuntimeError("A desktop component exited during startup")
            if predicate():
                return
            time.sleep(0.2)
        raise RuntimeError("Desktop startup timed out")

    def stop(_signum, _frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        start(["Xvfb", ":97", "-screen", "0", "1440x900x24", "-nolisten", "tcp", "-auth", env["XAUTHORITY"]])
        wait_until(lambda: subprocess.run(["xdpyinfo"], env=env, stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL).returncode == 0)
        start(["openbox"])
        socket_path = runtime / "vnc.sock"
        socket_path.unlink(missing_ok=True)
        # LibVNCServer has an independent IPv6 port; -no6 alone does not disable it.
        start(["x11vnc", "-display", ":97", "-auth", env["XAUTHORITY"], "-norc", "-nopw", "-forever",
               "-shared", "-rfbport", "0", "-rfbportv6", "0", "-noipv6", "-no6",
               "-listen", "127.0.0.1", "-listenv6", "::1", "-unixsock", str(socket_path),
               "-noxdamage", "-repeat"])
        wait_until(socket_path.exists)
        start(["google-chrome-stable", "--user-data-dir=" + str(profile), "--no-first-run",
               "--no-default-browser-check", "--disable-dev-shm-usage", "https://chatgpt.com/"])
        start([sys.executable, __file__, "--proxy"])
        while all(child.poll() is None for child in children):
            time.sleep(1)
        raise RuntimeError("A desktop component stopped; systemd will restart the desktop")
    finally:
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
        for child in children:
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()


if __name__ == "__main__":
    if sys.argv[1:] == ["--proxy"]:
        run_proxy()
    elif not sys.argv[1:]:
        run_desktop()
    else:
        raise SystemExit("Unexpected arguments")
REMOTEAGENTS_BROWSER_PY
chmod 0644 "$install_dir/browser.py"
printf '%s\n' 'managed by remoteagents-browser' > "$install_dir/.remoteagents-managed"
cat > "$unit" <<UNIT
# Managed by remoteagents-browser
[Unit]
Description=Private RemoteAgents server browser
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=120
StartLimitBurst=3
[Service]
Type=simple
User=$server_user
Group=$(id -gn "$server_user")
Environment=HOME=$user_home
Environment=PATH=/usr/local/bin:/usr/bin:/bin
WorkingDirectory=$user_home
RuntimeDirectory=remoteagents-browser
RuntimeDirectoryMode=0700
UMask=0077
ExecStart=/usr/bin/dbus-run-session -- /usr/bin/python3 $install_dir/browser.py
Restart=on-failure
RestartSec=3
TimeoutStopSec=20
KillMode=control-group
[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 "$unit"
python3 -m py_compile "$install_dir/browser.py"
systemd-analyze verify "$unit"
systemctl daemon-reload
systemctl enable remoteagents-browser.service
systemctl restart remoteagents-browser.service
for attempt in {1..40}; do
  if systemctl is-active --quiet remoteagents-browser.service && curl --silent --fail --max-time 2 -H 'Host: 127.0.0.1:6091' http://127.0.0.1:6091/vnc.html >/dev/null; then
    echo 'SERVER_BROWSER_READY=6091'
    exit 0
  fi
  sleep 1
done
echo 'Server desktop did not become ready. Check: journalctl -u remoteagents-browser.service -n 40 --no-pager' >&2
exit 11
