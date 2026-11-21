#!/usr/bin/env bash
# Sign a completed OTA bundle locally. No key generation, network or publication.
# Usage: sign-helper.sh key Main|Test build|auto bundle.zip launcher.exe initial-bundle.zip
set -euo pipefail
[[ $# == 6 ]] || { echo 'Usage: sign-helper.sh key Main|Test build|auto bundle.zip launcher.exe initial-bundle.zip' >&2; exit 2; }
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python3 - "$here/.." "$@" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import zipfile


def openssl(*args, data=None):
    return subprocess.run(['openssl', *args], input=data, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=True).stdout


def raw_signature(der):
    # OpenSSL DER ECDSA -> CNG/IEEE P1363 r || s, fixed-width big endian.
    if len(der) < 8 or der[0] != 0x30 or der[1] != len(der) - 2:
        raise ValueError('Invalid ECDSA DER signature')
    pos, values = 2, []
    for _ in range(2):
        if der[pos] != 2:
            raise ValueError('Invalid ECDSA integer')
        size = der[pos + 1]
        value = int.from_bytes(der[pos + 2:pos + 2 + size], 'big')
        if size < 1 or size > 33 or not 0 < value < 2**256:
            raise ValueError('Invalid ECDSA scalar')
        values.append(value.to_bytes(32, 'big'))
        pos += 2 + size
    if pos != len(der):
        raise ValueError('Trailing ECDSA bytes')
    return b''.join(values)


def der_signature(raw):
    if len(raw) != 64:
        raise ValueError('Invalid P1363 signature')
    integers = []
    for value in (raw[:32], raw[32:]):
        value = value.lstrip(b'\0') or b'\0'
        if value[0] & 0x80:
            value = b'\0' + value
        integers.append(bytes((2, len(value))) + value)
    body = b''.join(integers)
    return bytes((0x30, len(body))) + body


def main():
    root, key, instance, build, archive, launcher, initial = sys.argv[1:]
    if instance not in ('Main', 'Test'):
        raise ValueError('Instance must be Main or Test')
    product = 'RemoteAgents' if instance == 'Main' else 'RemoteAgentsTest'
    # Reject a missing/unprovisioned or identical anchor before opening the private key.
    source = (Path(root) / 'app/launcher/HelperUpdate.cs').read_text(encoding='utf-8-sig')
    anchors = dict(re.findall(r'const string (Main|Test)PublicKeyHex = "([0-9a-f]*)";', source))
    anchor = anchors.get(instance, '')
    if not re.fullmatch('[0-9a-f]{128}', anchor) or anchor == anchors.get('Test' if instance == 'Main' else 'Main'):
        raise ValueError('Provision distinct public anchors in HelperUpdate.cs before signing')
    key_stat = Path(key).stat()
    if not stat.S_ISREG(key_stat.st_mode) or stat.S_IMODE(key_stat.st_mode) != 0o600:
        raise ValueError('Signing key must be a regular file with mode 600')
    # SPKI DER for id-ecPublicKey + prime256v1; a different curve/type is refused.
    public = openssl('pkey', '-in', key, '-pubout', '-outform', 'DER')
    prefix = bytes.fromhex('3059301306072a8648ce3d020106082a8648ce3d03010703420004')
    if len(public) != len(prefix) + 64 or not public.startswith(prefix) or public[len(prefix):].hex() != anchor:
        raise ValueError('Signing key does not match the selected P-256 public anchor')
    archive, launcher = Path(archive), Path(launcher)
    with zipfile.ZipFile(archive) as bundle, zipfile.ZipFile(initial) as embedded:
        names = bundle.namelist()
        if len(names) != len(set(names)):
            raise ValueError('Duplicate ZIP entries')
        if bundle.read(product + '.exe') != launcher.read_bytes():
            raise ValueError('Launcher differs from the OTA bundle')
        if ('RemoteAgentsTest.exe' if instance == 'Main' else 'RemoteAgents.exe') in names:
            raise ValueError('Mixed-instance bundle')
        if build == 'auto':
            version = bundle.read('bundle-version.txt').decode('utf-8-sig').strip()
            match = re.fullmatch(r'(\d{8})\.(\d{6})-[A-Za-z0-9._-]+', version)
            if not match:
                raise ValueError('Custom bundle version requires an explicit helper build number')
            build = ''.join(match.groups())
        if not re.fullmatch(r'[1-9][0-9]{0,18}', build) or int(build) > 2**63 - 1:
            raise ValueError('Invalid helper build number')
        manifest = (json.dumps(dict(product=product, instance=instance, helperBuild=int(build),
                                   exeSha256=hashlib.sha256(launcher.read_bytes()).hexdigest(),
                                   singboxSha256=hashlib.sha256(embedded.read('transport/sing-box.exe')).hexdigest()),
                               separators=(',', ':')) + '\n').encode('utf-8')
        signature = None
        # Preserve a previously signed prepared bundle byte-for-byte if it is still valid.
        if 'helper-update.json' in names and 'helper-update.sig' in names and bundle.read('helper-update.json') == manifest:
            previous = bundle.read('helper-update.sig')
            with tempfile.TemporaryDirectory(prefix='.helper-verify-', dir=archive.parent) as tmp:
                pubfile, sigfile = Path(tmp) / 'public.der', Path(tmp) / 'signature.der'
                pubfile.write_bytes(public)
                sigfile.write_bytes(der_signature(previous))
                openssl('dgst', '-sha256', '-verify', str(pubfile), '-keyform', 'DER', '-signature', str(sigfile), data=manifest)
            return
        signature = raw_signature(openssl('dgst', '-sha256', '-sign', key, data=manifest))
        # Replace the archive only after both complete signed files exist; update the unpack allowlist.
        fd, temp = tempfile.mkstemp(prefix='.helper-signed-', dir=archive.parent)
        os.close(fd)
        try:
            with zipfile.ZipFile(temp, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as dest:
                payloads = {'helper-update.json': manifest, 'helper-update.sig': signature}
                all_names = set(names) | set(payloads) | {'bundle-files.txt'}
                payloads['bundle-files.txt'] = ('\n'.join(sorted(all_names - {'bundle-files.txt'})) + '\n').encode()
                for name in sorted(all_names):
                    data = payloads[name] if name in payloads else bundle.read(name)
                    info = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
                    info.compress_type = zipfile.ZIP_DEFLATED
                    info.external_attr = (stat.S_IFREG | (0o755 if name.endswith('.sh') else 0o644)) << 16
                    dest.writestr(info, data)
            os.chmod(temp, 0o644)
            os.replace(temp, archive)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)
    print('helper-update: signed ' + instance + ' build=' + build)


try:
    main()
except (ValueError, OSError, KeyError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
    # OpenSSL diagnostics and key contents never enter the release log.
    message = 'OpenSSL signing/verification failed' if isinstance(error, subprocess.CalledProcessError) else str(error)
    raise SystemExit('helper-update: ' + message)
PY
