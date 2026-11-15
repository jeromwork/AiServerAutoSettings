"""Real conntrack regression, confined to a disposable network namespace."""
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import unittest


def kernel_check():
    from test_server_apply import app

    def run(*args, **kwargs):
        return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs)

    run('ip', 'link', 'set', 'lo', 'up')
    # Enable tracking BEFORE connecting: loading conntrack only after connect
    # would silently test a different case (an untracked existing connection).
    run('nft', '-f', '-', input='''table inet tracking {
 chain out { type filter hook output priority 10; policy accept;
 ct state established accept
 }
}
''')
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        with socket.create_connection(listener.getsockname(), timeout=2) as client:
            server, _ = listener.accept()
            with server:
                client.sendall(b'before')
                assert server.recv(6) == b'before'
                server.sendall(b'ack')
                assert client.recv(3) == b'ack'
                # Model diversion into TUN by discarding unmarked replies.
                # Also reject accidental marking of locally originated traffic.
                run('nft', '-f', '-', input=app.inbound_nft('wan0') + '''
table inet regression {
 chain out { type filter hook output priority 0; policy accept;
 ct direction reply meta mark != 0x5241 drop
 ct direction original meta mark != 0 drop
 }
}
''')
                rendered = run('nft', 'list', 'table', 'inet', 'remoteagents_inbound').stdout
                assert app.nft_normal(rendered) == app.nft_normal(app.inbound_nft('wan0')), 'installed guard falsely differs (decimal/hex zero mark)'
                server.sendall(b'after')
                assert client.recv(5) == b'after', 'existing reply lost'
                # A separate outbound connection must retain mark zero.
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver:
                    receiver.bind(('127.0.0.1', 0))
                    receiver.settimeout(2)
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as outbound:
                        outbound.sendto(b'original', receiver.getsockname())
                        assert receiver.recv(8) == b'original'
                # Preserve a foreign conntrack mark used by earlier routing
                # rules: filling an unmarked legacy connection must not replace it.
                run('nft', '-f', '-', input='''delete table inet regression
table inet foreign_policy {
 chain tagging { type route hook output priority -160; policy accept;
 ct direction reply ct mark set 0x1234 meta mark set 0x1234
 }
 chain checking { type filter hook output priority 0; policy accept;
 ct direction reply ct mark != 0x1234 drop
 ct direction reply meta mark != 0x1234 drop
 }
}
''')
                server.sendall(b'foreign')
                assert client.recv(7) == b'foreign', 'foreign routing mark replaced'


class ConntrackTests(unittest.TestCase):
    def test_guard_protects_connections_established_before_first_tun(self):
        if not all(shutil.which(p) for p in ('unshare', 'nft', 'ip')):
            self.skipTest('unshare/nft/ip unavailable')
        prefix = [] if os.geteuid() == 0 else ['sudo', '-n']
        try:
            probe = subprocess.run(prefix + ['unshare', '-n', 'true'], capture_output=True, timeout=5)
        except FileNotFoundError:
            self.skipTest('isolated privileged network namespace unavailable')
        if probe.returncode:
            self.skipTest('isolated privileged network namespace unavailable')
        result = subprocess.run(prefix + ['unshare', '-n', sys.executable,
                                         str(Path(__file__).resolve()), '--kernel-check'],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    if sys.argv[1:] == ['--kernel-check']:
        kernel_check()
    else:
        unittest.main()
