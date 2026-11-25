#!/usr/bin/env bash
# Read-only instance snapshot. No privileged operations or safe-mode bypasses.
set -euo pipefail
command -v python3 >/dev/null || { echo 'ERROR unsupported: python3' >&2; exit 1; }
exec python3 - "$@" <<'PY'
import datetime, difflib, json, os, pathlib, re, shutil, subprocess, sys, tempfile
def fail(kind, detail): raise RuntimeError('ERROR ' + kind + ': ' + detail)
def run(*args):
    if not shutil.which(args[0]): fail('unsupported', args[0])
    p = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, timeout=15, check=False)
    if p.returncode:
        kind = 'permission' if re.search(r'permi|denied|not permitted', p.stderr, re.I) else 'unsupported'
        fail(kind, args[0] + ': ' + p.stderr.strip())
    return p.stdout
def snapshot(home):
    lines = []; traces = []
    def add(section, value): lines.append(section + ': ' + value)
    instance = home / 'state/instance'; inst = instance.read_text().strip() if instance.exists() else ''
    journal = home / 'state/traces.jsonl'
    if journal.exists():
        for line in journal.read_text().splitlines():
            try:
                t = json.loads(line)
            except json.JSONDecodeError: continue  # WAL can end in a truncated record.
            if isinstance(t, dict): traces.append(t)
    if not inst: inst = next((t.get('instance', '') for t in traces if t.get('instance')), '')
    if inst and not re.fullmatch(r'[0-9a-fA-F]{32}', inst): fail('unsupported', 'invalid instance id')
    tags = ['ra3-' + inst[:8], 'ra3_' + inst[:8]] if inst else []
    def owned(value): return any(re.search(re.escape(tag) + r'(?![0-9a-fA-F])', value) for tag in tags)
    def traced(kind): return [t for t in traces if t.get('kind') == kind and t.get('instance') == inst]
    def data(t): return dict(t.get('data') or {}, **(t.get('set') or {}))
    for raw in run('nft', '-j', 'list', 'ruleset').splitlines():
        obj = json.loads(raw)
        for entry in obj.get('nftables', []):
            for kind, value in entry.items():
                if kind != 'metainfo' and owned(json.dumps(value)):
                    value = dict(value)
                    for field in ('handle', 'packets', 'bytes'): value.pop(field, None)
                    for expr in value.get('expr', []):
                        if 'counter' in expr: expr['counter'] = {}
                    add('firewall', json.dumps({kind: value}, sort_keys=True))
    links = json.loads(run('ip', '-j', 'link', 'show'))
    ifaces = {data(t).get('name', '') for t in traced('adapter')}
    ifaces.update(x['ifname'] for x in links if owned(x['ifname']))
    for link in links:
        if link['ifname'] in ifaces: add('interface', link['ifname'])
    for family in ('-4', '-6'):
        for kind, args in [('route', ('route', 'show', 'table', 'all')), ('rule', ('rule', 'show'))]:
            for obj in json.loads(run('ip', '-j', family, *args)):
                match = owned(json.dumps(obj)) or obj.get('dev') in ifaces
                for t in traced(kind):
                    d = data(t)
                    if kind == 'route': match |= obj.get('dst') == d.get('dest') and obj.get('dev') == d.get('iface')
                    else:
                        match |= str(obj.get('table')) == d.get('table') and str(obj.get('priority')) == d.get('prio')
                if match:
                    for field in ('expires', 'used', 'cache', 'stats', 'age'): obj.pop(field, None)
                    add(kind, family + ' ' + json.dumps(obj, sort_keys=True))
    hosts = pathlib.Path('/etc/hosts').read_text()
    active = False
    for line in hosts.splitlines():
        if re.match(r'^\s*#\s*ra3-', line):
            if 'begin' in line: active = owned(line)
            if active: add('hosts', line.strip())
            if 'end' in line: active = False
        elif active: add('hosts', line.strip())
    for iface in sorted(ifaces & {x['ifname'] for x in links}):
        for key in ('dns', 'domain'): add('dns', run('resolvectl', key, iface).strip())
    pids = {}
    proc = pathlib.Path('/proc')
    if not proc.is_dir(): fail('unsupported', '/proc')
    for entry in proc.iterdir():
        if not entry.name.isdigit(): continue
        try:
            exe = (entry / 'exe').readlink()
        except FileNotFoundError: continue
        except PermissionError:
            if entry.stat().st_uid == os.getuid(): raise
            continue
        match = str(exe).startswith(str(home) + '/')
        for t in traced('process'):
            d = data(t)
            if str(d.get('pid')) == entry.name and str(exe) == d.get('exe'):
                start = d.get('start', '')
                ticks = (entry / 'stat').read_text().rsplit(')', 1)[1].split()[19]
                if str(start) == ticks: match = True
                elif start:
                    try:
                        stamp = datetime.datetime.fromisoformat(str(start).replace('Z', '+00:00')).timestamp()
                        boot = next(int(x.split()[1]) for x in (proc / 'stat').read_text().splitlines() if x.startswith('btime '))
                        if abs(stamp - (boot + int(ticks) / os.sysconf('SC_CLK_TCK'))) < 1: match = True
                    except (ValueError, StopIteration): fail('unsupported', 'unknown process start format')
        if match:
            pids[entry.name] = str(exe)
            add('process', os.path.relpath(exe, home) if str(exe).startswith(str(home) + '/') else str(exe))
    listeners = run('ss', '-H', '-lntup')
    for line in listeners.splitlines():
        owners = set(re.findall(r'pid=(\d+)', line)) & pids.keys()
        if owners:
            fields = line.split()
            add('listen', 'proto=' + fields[0] + ' addr=' + fields[4] + ' exe=' + ','.join(sorted(pids[p] for p in owners)))
    tmp = home / 'tmp'
    roots = {tmp}
    roots.update(pathlib.Path(data(t)['path']) for t in traced('tmp') if data(t).get('path'))
    def walk_error(error): raise error
    for base in sorted(roots):
        if not base.exists() and not base.is_symlink(): continue
        if base != tmp: add('tmp', str(base))
        if base.is_symlink(): continue
        for root, dirs, files in os.walk(base, onerror=walk_error, followlinks=False):
            for name in dirs + files:
                p = pathlib.Path(root) / name
                add('tmp', str(p.relative_to(tmp) if base == tmp else p) + ('/' if p.is_dir() else ''))
    for t in traced('autostart'):
        d = data(t)
        path = d.get('path')
        if path and pathlib.Path(path).exists(): add('autostart', path + ' ' + pathlib.Path(path).read_text())
    return '\n'.join(sorted(lines)) + '\n'
def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ('snap', 'diff'): fail('unsupported', 'usage: leftovers.sh snap <home> <file> | diff <a> <b>')
    mode, a, b = sys.argv[1:]
    if mode == 'diff':
        old = pathlib.Path(a).read_text().splitlines(keepends=True)
        new = pathlib.Path(b).read_text().splitlines(keepends=True)
        if old == new: return 0
        ports = [x.strip() for x in new if x not in old and x.startswith('listen:') and 'addr=127.0.0.1:' in x]
        if ports: print('New listening ports on 127.0.0.1:\n' + '\n'.join(ports))
        sys.stdout.writelines(difflib.unified_diff(old, new, fromfile=a, tofile=b))
        return 1
    home = pathlib.Path(a).resolve(strict=True)
    result = snapshot(home)
    target = pathlib.Path(b).absolute()
    name = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', dir=target.parent, delete=False) as f:
            name = f.name
            f.write(result)
        os.replace(name, target)
    finally:
        if name and os.path.exists(name): os.unlink(name)
    return 0
try:
    sys.exit(main())
except PermissionError as e: print('ERROR permission: ' + str(e), file=sys.stderr)
except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as e: print(str(e) if str(e).startswith('ERROR ') else 'ERROR unsupported: ' + str(e), file=sys.stderr)
sys.exit(1)
PY
