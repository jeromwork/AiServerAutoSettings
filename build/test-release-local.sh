#!/usr/bin/env bash
# Offline fixture: no build, GitHub, SSH or real user dist.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python3 - "$here" <<'PY'
import hashlib, importlib.util, io, json, os, pathlib, subprocess, sys, tarfile, tempfile
from unittest.mock import patch
here = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('release_dist', here / 'release-dist.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, HOME=tmp):
    root = pathlib.Path(tmp) / '.local/share/remote-agents/dist-test'
    root.mkdir(parents=True)
    payload, exe = b'fixture zip', b'fixture exe'
    sha = lambda b: hashlib.sha256(b).hexdigest()
    manifest = dict(product='RemoteAgents', configSchema=1, channel='test',
                    version='fixture-test', file='fixture-test.zip', sha256=sha(payload),
                    size=len(payload), launcher={'sha256': sha(exe)})
    def stream(data=payload):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode='w') as tar:
            for name, content in [('fixture-test.zip', data), ('RemoteAgents.exe', exe),
                                  ('manifest.json', json.dumps(manifest).encode())]:
                entry = tarfile.TarInfo('agents/' + name)
                entry.size = len(content)
                tar.addfile(entry, io.BytesIO(content))
        buf.seek(0)
        return type('Input', (), {'buffer': buf})()
    def publish(check=False, data=payload):
        with patch.object(sys, 'stdin', stream(data)):
            try:
                m.local_publish(str(root), 'RemoteAgents', 'test', check)
            except SystemExit as e:
                assert check and e.code == 0
    def rejects(fn):
        try: fn()
        except (ValueError, FileNotFoundError): return
        raise AssertionError('Expected rejection')
    rejects(lambda: m.local_destination(str(root), 'main'))
    rejects(lambda: m.local_destination(str(root.parent / 'dist'), 'main'))
    rejects(lambda: m.local_destination(str(root.parent / 'missing'), 'test'))
    # A symlink named dist-test must not redirect to main.
    main = root.parent / 'dist'
    main.mkdir()
    root.rmdir()
    root.symlink_to(main, target_is_directory=True)
    rejects(lambda: m.local_destination(str(root), 'test'))
    root.unlink()
    root.mkdir()
    publish(True)
    assert not (root / 'manifest.json').exists()
    rejects(lambda: publish(data=b'corrupt'))
    replacements = []
    replace = os.replace
    def record(src, dest):
        name = pathlib.Path(dest).name
        if name == 'manifest.json':
            assert (root / manifest['file']).read_bytes() == payload
            assert (root / 'RemoteAgents.exe').read_bytes() == exe
        else:
            assert not (root / 'manifest.json').exists()
        replacements.append(name)
        replace(src, dest)
    with patch.object(os, 'replace', record): publish()
    assert replacements == ['fixture-test.zip', 'RemoteAgents.exe', 'manifest.json']
    for name in replacements:
        assert (root / name).stat().st_mode & 0o777 == 0o644
    assert json.loads((root / 'manifest.json').read_text()) == manifest
    # Remote command still invokes exactly the existing publisher and quoted arguments.
    import shlex
    assert shlex.split(m.command('~/some dist', channel='test')) == [
        'python3', '-c', m.REMOTE, '~/some dist', 'RemoteAgents', 'test']
    for args in [('fixture.invalid', '--unknown'), ('localhost', '--prepared'),
                 ('127.0.0.1', 'dist', '--prepared', 'out', 'extra')]:
        result = subprocess.run(['bash', str(here / 'release.sh'), *args],
                                capture_output=True)
        assert result.returncode == 2, result.stderr
print('release-local: OK (offline)')
PY
