#!/usr/bin/env python3
"""Offline channel regressions: real packaging, disposable fixtures, no external tools."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent
HEAD = 'fixture-head'
TEST_DIST = '~/.local/share/remote-agents/dist-test'


class ChannelTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='remoteagents-channel-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.build = self.root / 'repo/build'
        self.build.mkdir(parents=True)
        # Copy only the scripts under test into an explicitly disposable fixture.
        for name in ('release-lib.sh', 'require-main.sh', 'release.sh', 'release-github.sh',
                     'bundle.py', 'release-dist.py', 'build-exe.sh', 'make-bundle.sh'):
            shutil.copy2(ROOT / name, self.build / name)
        (self.build / 'components.json').write_text('[]')
        (self.build / 'bundle-files.txt').write_text('build/components.json => components.json\n')
        (self.build / 'Start.cmd').write_text('@echo off\n')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.assets = self.root / 'assets'
        self.assets.mkdir()
        self.calls = self.root / 'calls.jsonl'
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        DOTNET=str(self.bin / 'dotnet'), FAKE_LOG=str(self.calls),
                        ASSETS=str(self.assets), HOME=str(self.root / 'home'),
                        REMOTEAGENTS_BUNDLE_VERSION='20261121.120000-fixture')
        for key in ('REMOTEAGENTS_BUILD_OUT', 'REMOTEAGENTS_BINARY_CACHE'):
            self.env.pop(key, None)
        # Git is called many times per release; a shell stub avoids interpreter startup per guard.
        self.shell_stub('git', r'''printf '["git",[' >> "$FAKE_LOG"
separator=""
for arg in "$@"; do
  printf '%s"%s"' "$separator" "$arg" >> "$FAKE_LOG"
  separator=,
done
printf ']]\n' >> "$FAKE_LOG"
[[ "$1" != -C ]] || shift 2
case "$1" in
  branch) printf '%s\n' "${BRANCH-main}" ;;
  rev-parse)
    ref="${!#}"
    if [[ "$ref" == origin/int/vpn-master ]]; then
      [[ -z "${NO_REMOTE:-}" ]] || exit 1
      printf '%s\n' "${REMOTE_HEAD-fixture-head}"
    else
      echo fixture-head
    fi ;;
  status) [[ -z "${DIRTY:-}" ]] || echo ' M fixture' ;;
  diff|merge-base|tag|push) ;;
  *) exit 91 ;;
esac
exit 0
''')
        self.shell_stub('gh', r'''printf '%s\0' "$@" >> "$FAKE_LOG.gh"
printf '\0' >> "$FAKE_LOG.gh"
[[ "$1" == release ]] || exit 92
case "$2" in
  view) exit "${NO_RELEASE:-0}" ;;
  upload|create)
    shift 3
    for arg in "$@"; do
      if [[ -f "$arg" ]]; then cp -- "$arg" "$ASSETS/"; fi
    done ;;
  download)
    shift 3
    names=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -p) names+=("$2"); shift 2 ;;
        -D) dest="$2"; shift 2 ;;
        *) exit 92 ;;
      esac
    done
    for name in "${names[@]}"; do cp -- "$ASSETS/$name" "$dest/$name"; done ;;
  edit) ;;
  *) exit 92 ;;
esac
''')
        self.shell_stub('ssh', r'''printf '%s\0' "$@" >> "$FAKE_LOG.ssh"
printf '\0' >> "$FAKE_LOG.ssh"
[[ "${@: -2:1}" == fixture.invalid ]] || exit 94
# Execute the generated publisher locally in the disposable HOME.
exec bash -c "${!#}"
''')
        fixtures = self.root / 'executables'
        fixtures.mkdir()
        for product in ('RemoteAgents', 'RemoteAgentsTest'):
            (fixtures / (product + '.exe')).write_bytes(b'MZ fixture' + product.encode() + 'FileVersion\0'.encode('utf-16le') + '1.4.0.0\0'.encode('utf-16le'))
        self.env['FIXTURES'] = str(fixtures)
        self.shell_stub('dotnet', r'''printf '["dotnet",[]]\n' >> "$FAKE_LOG"
[[ "$1" == publish ]] || exit 95
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p:AssemblyName=*) product="${1#*=}"; shift ;;
    -o) dest="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p -- "$dest"
cp -- "$FIXTURES/$product.exe" "$dest/$product.exe"
''')
        self.shell_stub('python3', r'''printf '["python3",[]]\n' >> "$FAKE_LOG"
# Never download, even if a channel guard regresses into a build.
if [[ "${1##*/}" == bundle.py && "${2:-}" == fetch ]]; then exit 0; fi
if [[ "${1##*/}" == bundle.py && "${2:-}" == attach && -n "${FAIL_ATTACH:-}" ]]; then exit 93; fi
exec ''' + shlex.quote(sys.executable) + ' "$@"\n')
        cache = self.root / 'cache'
        cache.mkdir()
        data = b'fixture binary'
        archive = cache / 'fixture.zip'
        with zipfile.ZipFile(archive, 'w') as z:
            z.writestr('sing-box.exe', data)
        sha = lambda raw: hashlib.sha256(raw).hexdigest()
        (self.build / 'bundle-binaries.json').write_text(json.dumps({'binaries': [{
            'name': 'fixture', 'url': 'https://fixture.invalid/fixture.zip',
            'sha256': sha(archive.read_bytes()), 'member': 'sing-box.exe',
            'memberSha256': sha(data), 'target': 'transport/sing-box.exe'}]}))
        self.env['REMOTEAGENTS_BINARY_CACHE'] = str(cache)

    def shell_stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/usr/bin/env bash\nset -euo pipefail\n' + body)
        path.chmod(0o755)

    def load(self, name):
        spec = importlib.util.spec_from_file_location(name, self.build / name)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def run_script(self, name, *args, ok=True, code=None):
        command = ([sys.executable] if name.endswith('.py') else []) + [str(self.build / name), *map(str, args)]
        result = subprocess.run(command, env=self.env,
                                capture_output=True, text=True, timeout=30)
        if code is not None:
            self.assertEqual(result.returncode, code, result.stderr)
        elif ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def reset_calls(self):
        for path in (self.calls, Path(str(self.calls) + '.gh'), Path(str(self.calls) + '.ssh')):
            path.unlink(missing_ok=True)

    def events(self, tool=None):
        rows = [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []
        for name in ('gh', 'ssh'):
            path = Path(str(self.calls) + '.' + name)
            if path.exists():
                rows.extend([name, call.split('\0')] for call in path.read_text().split('\0\0') if call)
        return [args for name, args in rows if name == tool] if tool else rows

    def prepare(self, channel):
        product = 'RemoteAgentsTest' if channel == 'test' else 'RemoteAgents'
        self.env['BRANCH'] = 'int/vpn-master' if channel == 'test' else 'main'
        out = self.root / ('prepared-' + channel)
        out.mkdir(exist_ok=True)
        exe = out / (product + '.exe')
        exe.write_bytes(b'MZ fixture' + product.encode() + 'FileVersion\0'.encode('utf-16le') + '1.4.0.0\0'.encode('utf-16le'))
        bundle = self.load('bundle.py')
        dist = self.load('release-dist.py')
        stage = self.root / ('stage-' + channel)
        with contextlib.redirect_stdout(io.StringIO()):
            initial = bundle.make('20261121.120000-fixture', out, launcher=exe, product=product)
            bundle.attach_launcher(initial, exe, out / 'bundle.zip', product=product)
            bundle.publish(out / 'bundle.zip', stage / 'agents', launcher=exe, product=product)
            dist.metadata(stage, out / 'release-info.json', HEAD, product=product)
        self.assertEqual(json.loads((stage / 'agents/manifest.json').read_text())['product'], product)
        self.reset_calls()
        return out, product

    def assert_publication(self, channel, product, out):
        tag = channel + '-latest'
        calls = self.events('gh')
        self.assertTrue(calls)
        for args in calls:
            self.assertEqual(args[2], tag)
            self.assertNotIn(('main' if channel == 'test' else 'test') + '-latest', args)
        self.assertEqual({p.name for p in self.assets.iterdir()}, {product + '.exe', 'release-info.json'})
        self.assertEqual((self.assets / (product + '.exe')).read_bytes(), (out / (product + '.exe')).read_bytes())
        self.assertTrue(any('refs/tags/' + tag in args for args in self.events('git')))
        info = json.loads((self.assets / 'release-info.json').read_text())
        self.assertEqual(set(info['sha256']), {product + '.exe'})

    def test_make_bundle_forwards_product(self):
        for channel in ('main', 'test'):
            product = 'RemoteAgentsTest' if channel == 'test' else 'RemoteAgents'
            exe = self.root / (product + '.exe')
            exe.write_bytes(b'fixture')
            self.run_script('make-bundle.sh', '20261121.1', self.root, '--channel', channel, '--launcher', exe)
            with zipfile.ZipFile(self.root / '20261121.1.zip') as z:
                self.assertIn(product + '.exe', z.namelist())
                self.assertNotIn(('RemoteAgents' if channel == 'test' else 'RemoteAgentsTest') + '.exe', z.namelist())

    def test_github_test_tag_and_assets(self):
        out, product = self.prepare('test')
        self.run_script('release-github.sh', '--channel', 'test', out)
        self.assert_publication('test', product, out)
        self.assertFalse(self.events('ssh'))

    def test_prepared_release_test_and_default_main(self):
        for channel in ('test', 'main'):
            with self.subTest(channel=channel):
                for p in self.assets.iterdir():p.unlink()
                out, product = self.prepare(channel)
                options = ['--channel', 'test'] if channel == 'test' else []
                self.env['NO_RELEASE'] = '1' if channel == 'main' else '0'
                self.run_script('release.sh', *options, 'fixture.invalid', '--prepared', out)
                self.assert_publication(channel, product, out)
                command = self.events('ssh')[0][-1]
                expected = TEST_DIST if channel == 'test' else TEST_DIST.removesuffix('-test')
                self.assertEqual(shlex.split(command)[-2:], [expected, product])
                if channel == 'test':self.assertNotIn('dist/', command)
                remote = Path(self.env['HOME']) / '.local/share/remote-agents' / ('dist-test' if channel == 'test' else 'dist')
                self.assertEqual(json.loads((remote / 'manifest.json').read_text())['product'], product)
                self.assertEqual((remote / (product + '.exe')).read_bytes(), (out / (product + '.exe')).read_bytes())
                self.assertFalse(self.events('dotnet'))

    def test_stale_metadata_stops_before_gh_or_tag(self):
        for channel in ('main', 'test'):
            out, product = self.prepare(channel)
            original_info = (out / 'release-info.json').read_bytes()
            original_bundle = (out / 'bundle.zip').read_bytes()
            for bad in ('commit', 'hash', 'bundle', 'product'):
                with self.subTest(channel=channel, bad=bad):
                    self.reset_calls()
                    (out / 'bundle.zip').write_bytes(original_bundle)
                    info = json.loads(original_info)
                    if bad == 'commit':info['commit'] = 'stale'
                    if bad == 'hash':info['sha256'][product + '.exe'] = '0' * 64
                    if bad == 'product':info['sha256'] = {'Other.exe': '0' * 64}
                    if bad == 'bundle':
                        with zipfile.ZipFile(out / 'bundle.zip', 'w') as z:z.writestr('bundle-version.txt', 'stale')
                    (out / 'release-info.json').write_text(json.dumps(info))
                    if bad == 'commit':
                        self.run_script('release-github.sh', '--channel', channel, out, ok=False)
                    else:
                        with self.assertRaises((ValueError, KeyError)):
                            self.load('release-dist.py').verify(out, HEAD, product=product)
                    self.assertFalse(self.events('gh'))
                    self.assertFalse(any('tag' in args or 'push' in args for args in self.events('git')))

    def test_isolation_whitelist_before_external_commands(self):
        paths = ['~/.local/share/remote-agents/dist', '~/.local/share/remote-agents/dist/',
                 '/home/owner/.local/share/remote-agents/dist/.',
                 str(Path(self.env['HOME']) / '.local/share/remote-agents/dist'),
                 TEST_DIST + '/../dist', TEST_DIST + '/..', TEST_DIST + '/', TEST_DIST + '/.',
                 '~/.local/share/remote-agents/other/../dist-test', '/tmp/dist-test',
                 str(Path(self.env['HOME']) / '.local/share/remote-agents/dist-test'), '']
        # Batch path checks in one shell, then verify release.sh invokes the guard before any work.
        script = 'source "$1"; shift; for path in "$@"; do if check_channel_isolation test "$path"; then exit 90; fi; done'
        result = subprocess.run(['bash', '-c', script, 'fixture', str(self.build / 'release-lib.sh'), *paths],
                                env=self.env, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in (paths[1], TEST_DIST + '/../dist'):
            self.run_script('release.sh', '--channel', 'test', 'fixture.invalid', path, ok=False)
        self.assertEqual(self.events(), [])

    def test_test_source_guards(self):
        out, _ = self.prepare('test')
        for extra in ({'NO_REMOTE': '1'}, {'BRANCH': 'main'}, {'BRANCH': ''},
                      {'BRANCH': 'feat/test-channel'}, {'REMOTE_HEAD': 'other'}, {'DIRTY': '1'}):
            with self.subTest(extra=extra):
                env = self.env.copy()
                self.env.update(extra)
                self.run_script('require-main.sh', '--channel', 'test', ok=False)
                self.assertFalse(self.events('gh'))
                self.assertFalse(self.events('ssh'))
                self.assertFalse(self.events('dotnet'))
                self.env = env
        self.assertFalse(any(args[-1:] == ['int/vpn-master'] and 'rev-parse' in args for args in self.events('git')))
        self.env['NO_REMOTE'] = '1'
        self.run_script('release-github.sh', '--channel', 'test', out, ok=False)
        self.env.pop('NO_REMOTE')
        self.env['BRANCH'] = 'main'
        self.run_script('release.sh', '--channel', 'test', 'fixture.invalid', ok=False)
        self.assertFalse(self.events('gh'))
        self.assertFalse(self.events('ssh'))
        self.assertFalse(self.events('dotnet'))

    def test_unknown_channel_never_builds(self):
        for name, args in [('release.sh', ['fixture.invalid']), ('release-github.sh', [self.root]),
                           ('build-exe.sh', []), ('require-main.sh', []),
                           ('make-bundle.sh', ['20261121.1', self.root])]:
            self.run_script(name, '--channel', 'invalid_channel', *args, ok=False)
        self.assertEqual(self.events(), [])

    def test_extra_or_missing_release_arguments_exit_2(self):
        for args in [[], ['fixture.invalid', 'dist', 'extra'],
                     ['fixture.invalid', '--prepared'], ['fixture.invalid', 'dist', '--prepared'],
                     ['fixture.invalid', '--prepared', 'X', 'extra'],
                     ['fixture.invalid', 'dist', '--prepared', 'X', 'extra'],
                     ['fixture.invalid', '--unknown'], ['fixture.invalid', 'dist', '--unknown', 'X']]:
            with self.subTest(args=args):self.run_script('release.sh', *args, code=2)
        self.assertEqual(self.events(), [])

    def test_test_build_rejects_main_output_overrides(self):
        for out in (self.build / 'out', self.build / 'out/subdir',
                    self.build.parent / 'release', self.build.parent / 'release/subdir'):
            self.env['REMOTEAGENTS_BUILD_OUT'] = str(out)
            self.run_script('build-exe.sh', '--channel', 'test', ok=False)
        self.assertEqual(self.events(), [])

    def test_build_test_outputs_and_attach_failure(self):
        # Exercise defaults using the fake SDK, pinned fixture binaries and real packaging.
        self.env['BRANCH'] = 'int/vpn-master'
        main = self.build / 'out'
        main.mkdir()
        for name in ('bundle.zip', 'initial-bundle.zip', 'release-info.json'):
            (main / name).write_bytes(b'main sentinel')
        self.run_script('release.sh', '--channel', 'test', 'fixture.invalid')
        out = self.build / 'out-test'
        self.assertTrue((out / 'RemoteAgentsTest.exe').is_file())
        self.assertFalse((self.build.parent / 'release').exists())
        with zipfile.ZipFile(out / 'bundle.zip') as z:
            self.assertIn('RemoteAgentsTest.exe', z.namelist())
            self.assertNotIn('RemoteAgents.exe', z.namelist())
            self.assertNotIn('transport/sing-box.exe', z.namelist())
        self.assert_publication('test', 'RemoteAgentsTest', out)
        for p in main.iterdir():self.assertEqual(p.read_bytes(), b'main sentinel')
        (out / 'bundle.zip').unlink()
        self.env['FAIL_ATTACH'] = '1'
        self.run_script('build-exe.sh', '--channel', 'test', code=93)
        self.assertFalse((out / 'bundle.zip').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
