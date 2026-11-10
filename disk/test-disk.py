#!/usr/bin/env python3
"""Two Syncthing 2.1.7 peers in disposable homes; total deadline includes all checks."""
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
import xml.etree.ElementTree as E

HERE = Path(__file__).resolve().parent
START = time.monotonic()
DEADLINE = START + 120
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))
SIDES = []
CHECKS = []
sys.stdout.reconfigure(line_buffering=True)


def require(value, message):
    if not value:
        raise RuntimeError(message)


def remaining():
    value = DEADLINE - time.monotonic()
    require(value > 0, '120s total deadline exceeded')
    return value


def kill_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def test_engines():
    states = {os.fsencode(side['state']) for side in SIDES}
    pids = []
    for cmdline in Path('/proc').glob('[0-9]*/cmdline'):
        try:
            args = cmdline.read_bytes().split(b'\0')
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
        if args[0].rsplit(b'/', 1)[-1] == b'syncthing' and any(
                (arg == b'--home' and value in states) or
                (arg.startswith(b'--home=') and arg[7:] in states)
                for arg, value in zip(args, args[1:])):
            pids.append(int(cmdline.parent.name))
    return pids


def stop_engines():
    end = min(DEADLINE, time.monotonic() + 5)
    while pids := test_engines():
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if time.monotonic() >= end:
            break
        time.sleep(.02)
    require(not test_engines(), 'test engines remain after cleanup')
    print('engine cleanup: no test syncthing processes')


def run(args, env=None, ok=True, limit=15, title=None):
    before = time.monotonic()
    process = subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    if title:
        CHECKS.append(process)
    command = 'server-disk.sh ' + args[2] if args[:2] == ['bash', str(HERE / 'server-disk.sh')] else Path(args[0]).name
    try:
        stdout, stderr = process.communicate(timeout=min(limit, remaining()))
        last = stderr.decode(errors='replace').strip().splitlines()
        require(not ok or process.returncode == 0, f'command failed: {command}, exit {process.returncode}: {last[-1][:300] if last else "(no stderr)"}')
        return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
    except subprocess.TimeoutExpired as error:
        last = (error.stderr or b'').decode(errors='replace').strip().splitlines()
        raise RuntimeError(f'command timed out: {command}: {last[-1][:300] if last else "(no stderr)"}') from error
    finally:
        kill_group(process)
        process.wait(timeout=1)
        if title:
            CHECKS.remove(process)
            print(f'{title}: exit {process.returncode}, {time.monotonic() - before:.2f}s')


def server(side, action, data=None, ok=True):
    args = ['bash', str(HERE / 'server-disk.sh'), action]
    if data is not None:
        args.append(base64.b64encode(json.dumps(data).encode()).decode())
    result = run(args, side['env'], ok)
    return json.loads(result.stdout) if ok else result


def api(side, route, method='GET', body=None):
    request = urllib.request.Request(
        f"http://127.0.0.1:{side['gui']}/rest/{route}", method=method,
        headers={'X-API-Key': side['key'], 'Content-Type': 'application/json'},
        data=None if body is None else json.dumps(body).encode())
    with HTTP.open(request, timeout=min(2, remaining())) as response:
        return json.loads(response.read() or b'{}')


def wait(predicate, description, seconds=18):
    end = min(DEADLINE, time.monotonic() + seconds)
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(.15)
    raise RuntimeError('timeout: ' + description)


def scan():
    for side in SIDES:
        api(side, 'db/scan?folder=' + side['id'], 'POST')


def both(name, text):
    return all((s['folder'] / name).exists() and (s['folder'] / name).read_text() == text for s in SIDES)


def settled():
    return all((lambda d: d['state'] == 'idle' and d['needTotalItems'] == 0)(
        api(s, 'db/status?folder=' + s['id'])) for s in SIDES)


def channel_test(root, side):
    # RFC 7748 section 6.1, Alice's scalar and public result; no material is printed.
    private = bytes.fromhex('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a')
    expected = bytes.fromhex('8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a')
    source = root / 'fake-channel.json'
    fake = dict(inbounds=[dict(type='vless', listen_port=443, users=[dict(name='client', uuid='test-only', flow='xtls-rprx-vision')], tls=dict(enabled=True, server_name='test.invalid', reality=dict(private_key=base64.urlsafe_b64encode(private).decode().rstrip('='), short_id=['ab'])))])
    source.write_text(json.dumps(fake))
    side['env']['REMOTE_DISK_CHANNEL_SOURCE'] = str(source)
    before = source.read_bytes()
    for hop in (None, dict(server='hop.invalid', server_port=22, user='tester', private_key_path='unused')):
        data = dict(server='server.invalid', hop=hop)
        result = server(side, 'channel-config', data)
        out = result['outbounds']; v = out[0]
        require(base64.urlsafe_b64decode(v['tls']['reality']['public_key'] + '===') == expected, 'RFC 7748 X25519')
        require(v['uuid'] == 'test-only' and v['flow'] == 'xtls-rprx-vision' and v['tls']['utls']['fingerprint'] == 'chrome', 'VLESS fields')
        require(result['route'] == dict(final='server', auto_detect_interface=True), 'route')
        require([(x['listen'], x['listen_port'], x['override_address'], x['override_port']) for x in result['inbounds']] == [('127.0.0.1', 2222, '127.0.0.1', 22), ('127.0.0.1', 22001, '127.0.0.1', side['listen'])], 'direct inbounds')
        require(out[-1] == dict(type='urltest', tag='server', outbounds=['vless-direct', 'vless-hop'] if hop else ['vless-direct'], url='https://www.gstatic.com/generate_204', interval='1m', tolerance=300), 'urltest')
        if hop:
            require(out[1]['detour'] == 'hop-ssh' and out[2] == dict(hop, type='ssh', tag='hop-ssh'), 'SSH detour')
        require('"private_key":' not in json.dumps(result) and base64.urlsafe_b64encode(private).decode().rstrip('=') not in json.dumps(result), 'private key exposed')
    require(source.read_bytes() == before, 'server channel configuration changed')
    print('channel-config: exit 0')


def exercise(root, archive):
    for i in range(2):
        home = root / f'peer-{i}'; home.mkdir()
        side = dict(home=home, env=dict(os.environ, HOME=str(home)), state=home / '.local/share/remote-disk', folder=home / 'Disk/project')
        SIDES.append(side)
        fake_bin = home / 'fake-bin'; fake_bin.mkdir()
        crontab = fake_bin / 'crontab'
        crontab.write_text(f'#!{sys.executable}\nimport os,sys\nfrom pathlib import Path\np=Path.home()/"fake-crontab"\nif os.environ.get("FAIL_CRONTAB"):sys.exit(2)\nif sys.argv[1]=="-l":sys.stdout.buffer.write(p.read_bytes()) if p.exists() else sys.exit(1)\nelse:p.write_bytes(sys.stdin.buffer.read())\n')
        crontab.chmod(0o700); side['env']['PATH'] = str(fake_bin) + os.pathsep + os.environ['PATH']
        foreign_cron = b'# foreign cron\n\n17 * * * * echo preserved\n'
        (home / 'fake-crontab').write_bytes(foreign_cron)
        result = run(['bash', str(HERE / 'server-disk.sh'), 'bootstrap', '--archive', str(archive)], side['env'])
        side.update(json.loads(result.stdout))
        require(server(side, 'bootstrap')['deviceId'] == side['deviceId'], 'repeat bootstrap')
        cron_line = b'* * * * * bash "$HOME/.local/share/remote-disk/server-disk.sh" bootstrap >/dev/null 2>&1\n'
        require((home / 'fake-crontab').read_bytes() == foreign_cron + cron_line, 'one cron entry, foreign lines preserved')
        side['env']['FAIL_CRONTAB'] = '1'
        require(server(side, 'bootstrap')['deviceId'] == side['deviceId'], 'crontab failure must not break bootstrap')
        del side['env']['FAIL_CRONTAB']
        config = E.parse(side['state'] / 'config.xml')
        side['gui'] = config.findtext('gui/address').rsplit(':', 1)[1]
        side['key'] = config.findtext('gui/apikey')
        version = run([str(side['state'] / 'bin/syncthing'), '--version']).stdout
        require(version.startswith(b'syncthing v2.1.7 '), 'engine version')
        opt = config.find('options')
        require(all(opt.findtext(n) == 'false' for n in ('relaysEnabled', 'globalAnnounceEnabled', 'localAnnounceEnabled', 'natEnabled')), 'external discovery')
        require(opt.findtext('autoUpgradeIntervalH') == '0' and opt.findtext('reconnectionIntervalS') == '10', 'engine options')
    a, b = SIDES
    channel_test(root, a)
    for side, peer in ((a, b), (b, a)):
        server(side, 'add-device', dict(deviceId=peer['deviceId'], addresses=[f"tcp://127.0.0.1:{peer['listen']}"]))
        api(side, 'config/devices/' + peer['deviceId'], 'PATCH', dict(paused=True))
        side['folder'].mkdir(parents=True)
        run(['git', 'init', '-q', str(side['folder'])])
        data = dict(name='project', deviceId=peer['deviceId'], localHasFiles=False)
        # A foreign policy fails before a folder is registered.
        ignore = side['folder'] / '.stignore'; ignore.write_text('foreign-policy')
        refused = server(side, 'attach', data, ok=False)
        require(refused.returncode != 0 and 'Чужой .stignore' in refused.stderr.decode() and ignore.read_text() == 'foreign-policy', 'foreign policy refusal')
        ignore.unlink()
        probe = side['folder'] / 'merge-probe.txt'; probe.write_text('existing')
        refused = server(side, 'attach', dict(data, localHasFiles=True), ok=False)
        require(refused.returncode != 0 and 'требуется -Merge' in refused.stderr.decode(), 'initial nonempty folders require merge')
        side['id'] = server(side, 'attach', dict(data, localHasFiles=True, merge=True))['id']
        require(server(side, 'attach', dict(data, localHasFiles=True))['id'] == side['id'], 'repeat nonempty attachment without merge')
        server(side, 'detach', data)
        refused = server(side, 'attach', dict(data, localHasFiles=True), ok=False)
        require(refused.returncode != 0 and 'требуется -Merge' in refused.stderr.decode(), 'detached device still requires merge')
        server(side, 'attach', dict(data, localHasFiles=True, merge=True)); probe.unlink()
        require(side['id'] == 'disk-' + hashlib.sha256(b'folder:project').hexdigest()[:24], 'stable folder ID')
        require(ignore.read_bytes() == (HERE / 'stignore.txt').read_bytes(), 'canonical policy')
        require(set(('.stignore', '.stfolder', '*.sync-conflict-*')) <= set((side['folder'] / '.git/info/exclude').read_text().splitlines()), 'Git exclusions')
        server(side, 'detach', data)
        require(not any(d['deviceID'] == peer['deviceId'] for d in api(side, 'config/folders/' + side['id'])['devices']), 'detach')
        server(side, 'attach', data)
        server(side, 'attach', data)
        f = api(side, 'config/folders/' + side['id'])
        require(f['maxConflicts'] == -1 and f['versioning']['type'] == 'staggered' and f['versioning']['params']['maxAge'] == '0' and not f['paused'] and len(f['devices']) == 2, 'repeat attachment')
        api(side, 'config/folders/' + side['id'], 'PATCH', dict(paused=True))
        server(side, 'attach', data)
        require(api(side, 'config/folders/' + side['id'])['paused'], 'pause preserved')
        api(side, 'config/folders/' + side['id'], 'PATCH', dict(paused=False))
    allowed = {'log/LogBuffer.kt': 'log source', 'db/x.sql': 'SQL source', 'AccessToken.php': 'PHP source', 'race.txt': 'base'}
    denied = ['.env', 'identity.key', 'build/output.txt', 'node_modules/module.txt']
    for name, value in {**allowed, **{x: 'excluded-test-content' for x in denied}}.items():
        p = a['folder'] / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(value)
    (b['folder'] / 'reverse.txt').write_text('reverse')
    scan()
    wait(lambda: api(a, 'db/status?folder=' + a['id'])['localFiles'] == len(allowed) and api(b, 'db/status?folder=' + b['id'])['localFiles'] == 1, 'initial scans')
    for side, peer in ((a, b), (b, a)):
        api(side, 'config/devices/' + peer['deviceId'], 'PATCH', dict(paused=False))
    wait(lambda: all(both(n, v) for n, v in allowed.items()) and both('reverse.txt', 'reverse') and settled(), 'two-way transfer')
    require(all(not (b['folder'] / n).exists() for n in denied), 'excluded files transferred')
    # Stop the link, index simultaneous edits on both peers, then reconnect.
    api(a, 'config/devices/' + b['deviceId'], 'PATCH', dict(paused=True))
    wait(lambda: not api(a, 'system/connections')['connections'].get(b['deviceId'], {}).get('connected'), 'disconnect')
    for i, side in enumerate(SIDES):
        (side['folder'] / 'race.txt').write_text('offline-A' if i == 0 else 'offline-B')
        stamp = time.time() - 60 + i * 3; os.utime(side['folder'] / 'race.txt', (stamp, stamp))
        (side['folder'] / f'offline-{i}.txt').write_text('writable')
    scan(); wait(settled, 'offline indexing')
    api(a, 'config/devices/' + b['deviceId'], 'PATCH', dict(paused=False))
    def conflict_kept():
        for side in SIDES:
            files = [side['folder'] / 'race.txt', *side['folder'].glob('race.sync-conflict-*')]
            if {p.read_text() for p in files if p.is_file()} != {'offline-A', 'offline-B'}:
                return False
        return both('offline-0.txt', 'writable') and both('offline-1.txt', 'writable') and settled()
    wait(conflict_kept, 'both conflict versions and offline writes')
    for side in SIDES:
        require(server(side, 'list')[0]['id'] == side['id'], 'list identity')
    # A legacy ID remains authoritative for its path.
    f = api(b, 'config/folders/' + b['id']); old = b['id']; api(b, 'config/folders/' + old, 'DELETE')
    f['id'] = 'legacy-project'; api(b, 'config/folders/legacy-project', 'PUT', f)
    require(server(b, 'attach', dict(name='project', deviceId=a['deviceId'], localHasFiles=False))['id'] == 'legacy-project', 'legacy ID retained')
    # Server discovery + actual Windows companion scripts against both real engines.
    auto = a['home'] / 'Disk/AutoTest'; auto.mkdir(); (auto/'hello.txt').write_text('auto')
    outside = a['home']/'outside'; outside.mkdir(); (outside/'keep.txt').write_text('untouched')
    (a['home']/'Disk/Linked').symlink_to(outside, target_is_directory=True)
    foreign = a['home']/'Disk/Foreign'; foreign.mkdir(); (foreign/'.stignore').write_text('custom')
    server(a, 'reconcile'); server(a, 'reconcile')
    row = next(f for f in api(a, 'config/folders') if f['label']=='AutoTest'); aid=row['id']
    require(any(d['deviceID']==b['deviceId'] for d in row['devices']), 'auto shared')
    require(not any(f['label'] in ('Foreign','Linked') for f in api(a,'config/folders')), 'foreign policy and symlink skipped')
    require(list(outside.iterdir())==[outside/'keep.txt'], 'outside Disk untouched')
    wait(lambda: aid in api(b,'cluster/pending/folders'), 'pending automatic offer')
    appdata=b['home']/'appdata'; local=appdata/'RemoteDisk'; (local/'state').mkdir(parents=True)
    (local/'state/config.xml').write_bytes((b['state']/'config.xml').read_bytes())
    (local/'server.txt').write_text(a['deviceId'])
    base=b['home']/'work'; base.mkdir(); target=base/'AutoTest'; target.mkdir(); (target/'.git').mkdir()
    ps=str(Path.home()/'.cache/pwsh-test/pwsh')
    env=dict(b['env'],LOCALAPPDATA=str(appdata))
    (local/'base.txt').write_text(str(base))
    def accept():
        run([ps,'-NoProfile','-File',str(HERE/'Sync-RemoteDiskFolders.ps1')],env,limit=12)
    accept()
    require(api(b,'config/defaults/folder')['path']==str(base), 'tray default path follows the saved base')
    require(not any(f['id']==aid for f in api(b,'config/folders')) and (target/'.git').is_dir(), 'occupied git-only folder stays pending')
    (target/'.git').rmdir(); accept(); accept()
    require(len([f for f in api(b,'config/folders') if f['id']==aid])==1, 'accept idempotent')
    wait(lambda: (target/'hello.txt').exists(), 'automatic folder transfer')
    moved=base/'MovedAutoTest'
    run([ps,'-NoProfile','-File',str(HERE/'Move-RemoteDiskFolder.ps1'),'-FolderId',aid,'-Destination',str(moved)],env,limit=15)
    require((moved/'hello.txt').read_text()=='auto' and not target.exists(), 'local move keeps content')
    require(api(b,'config/folders/'+aid)['path']==str(moved) and not api(b,'config/folders/'+aid)['paused'], 'move keeps ID and resumes')
    (auto/'after.txt').write_text('after move'); api(a,'db/scan?folder='+aid,'POST')
    wait(lambda:(moved/'after.txt').exists(), 'sync after move')
    require((auto/'hello.txt').read_text()=='auto', 'server content preserved by move')
    occupied=base/'Busy'; occupied.mkdir(); (occupied/'keep.txt').write_text('keep')
    refused=run([ps,'-NoProfile','-File',str(HERE/'Move-RemoteDiskFolder.ps1'),'-FolderId',aid,'-Destination',str(occupied)],env,ok=False,limit=10)
    require(refused.returncode!=0 and (occupied/'keep.txt').read_text()=='keep' and (moved/'hello.txt').exists(), 'occupied move rejected without altering files')
    api(b,'config/folders/'+aid,'PATCH',dict(paused=True))
    moved_again=base/'MovedPaused'
    run([ps,'-NoProfile','-File',str(HERE/'Move-RemoteDiskFolder.ps1'),'-FolderId',aid,'-Destination',str(moved_again)],env,limit=15)
    require(api(b,'config/folders/'+aid)['paused'] and (moved_again/'hello.txt').exists(), 'original pause retained on move')
    # Changing the base moves server folders from the old base, like Yandex Disk.
    base2=b['home']/'Disk2'; stamp=(moved_again/'hello.txt').stat().st_mtime_ns
    common=str(HERE/'Disk.Common.ps1').replace("'","''")
    def rebase(path):
        return run([ps,'-NoProfile','-Command',f"$ErrorActionPreference='Stop';. '{common}';$script:DiskHome=Join-Path $env:LOCALAPPDATA 'RemoteDisk';Set-DiskBase '{path}'"],env,limit=20)
    rebase(base2); rebase(base2)
    relocated=base2/'MovedPaused'
    require(api(b,'config/folders/'+aid)['path']==str(relocated) and (relocated/'hello.txt').read_text()=='auto' and not moved_again.exists(), 'base change moves folders')
    require((local/'base.txt').read_text()==str(base2) and api(b,'config/folders/'+aid)['paused'], 'base saved, pause kept')
    copied=base2/'Copied'
    run([ps,'-NoProfile','-File',str(HERE/'Move-RemoteDiskFolder.ps1'),'-FolderId',aid,'-Destination',str(copied),'-Copy'],env,limit=15)
    require((copied/'hello.txt').read_text()=='auto' and (copied/'hello.txt').stat().st_mtime_ns//10**7==stamp//10**7 and (copied/'.stignore').exists() and (relocated/'hello.txt').read_text()=='auto', 'copy move across volumes keeps files, times and recovery source')
    require(api(b,'config/folders/'+aid)['path']==str(copied), 'copy move updates path')
    refused=run([ps,'-NoProfile','-File',str(HERE/'Move-RemoteDiskFolder.ps1'),'-FolderId',aid,'-Destination',str(copied/'inner'),'-Copy'],env,ok=False,limit=10)
    require(refused.returncode!=0 and not (copied/'inner').exists(), 'move into itself refused')

    # A newly registered peer gets all existing managed folders without manual attach.
    api(a,'config/folders/'+aid,'PATCH',dict(devices=[dict(deviceID=a['deviceId'])]))
    server(a,'add-device',dict(deviceId=b['deviceId'],addresses=[f"tcp://127.0.0.1:{b['listen']}"]))
    require(any(d['deviceID']==b['deviceId'] for d in api(a,'config/folders/'+aid)['devices']), 'registration reconciles existing folders')
    print('auto discovery, occupied-path guard, accept, move and resumed transfer: exit 0')
    print('engine 2.1.7: attach/detach, transfer, exclusions, conflict, offline writes: exit 0')


def main():
    def expired(*_):
        raise RuntimeError('120s total deadline exceeded')
    signal.signal(signal.SIGALRM, expired); signal.setitimer(signal.ITIMER_REAL, 120)
    archive = Path(sys.argv[1] if len(sys.argv) > 1 else '/tmp/remote-disk-release-zP80am/syncthing-linux-amd64-v2.1.7.tar.gz').resolve()
    try:
        with tempfile.TemporaryDirectory(prefix='disk-test-') as tmp:
            root = Path(tmp)
            with ThreadPoolExecutor(max_workers=3) as pool:
                checks = []
                try:
                    for title, args in [('install', [str(Path.home() / '.cache/pwsh-test/pwsh'), '-NoProfile', '-File', str(HERE / 'test-install.ps1')]), ('windows-control', ['python3', '-B', str(HERE.parent / 'test-windows-control.py')]), ('bash syntax', ['bash', '-n', str(HERE / 'server-disk.sh')])]:
                        checks.append(pool.submit(run, args, dict(os.environ, HOME=tmp, PYTHONDONTWRITEBYTECODE='1'), limit=remaining(), title=title))
                    before = time.monotonic(); exercise(root, archive)
                    print(f'engine checks: exit 0, {time.monotonic() - before:.2f}s')
                    for check in checks:
                        check.result(timeout=remaining())
                finally:
                    signal.setitimer(signal.ITIMER_REAL, 0)
                    for process in list(CHECKS):
                        kill_group(process)
                    stop_engines()
        remaining()
        print(f'total: exit 0, {time.monotonic() - START:.2f}s (limit 120s)')
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        message = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        if isinstance(error.__context__, RuntimeError):
            message = f'{error.__context__}; cleanup: {message}'
        print(f'FAIL: {message}; {time.monotonic() - START:.2f}s', file=sys.stderr)
        sys.exit(1)
