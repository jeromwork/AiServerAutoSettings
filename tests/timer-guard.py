#!/usr/bin/env python3
"""§4а: scan timer sites; debt format: # count: N, [code], [tests], path: text # W2."""
import argparse
from collections import Counter
import re
from pathlib import Path

PATTERNS = {
    '.cs': r'Thread\.Sleep|Task\.Delay|new\s+(?:[\w.]+\.)?Timer\b|PeriodicTimer|System\.Timers|DispatcherTimer|Forms\.Timer|GetLastWriteTime|\.LastWriteTime|maxAgeSec|MaxAge|Stale|UtcNow.*\.TotalSeconds|\.TotalSeconds.*UtcNow',
    '.ps1': r'(?i)Start-Sleep|\[Threading\.Thread\]::Sleep|LastWriteTime|TotalSeconds\s+-(?:gt|ge|lt|le)\b|updatedAt',
    '.py': r'time\.sleep|asyncio\.sleep\s*\(|threading\.Timer\b|\bsleep\s+|st_mtime|getmtime',
    '.sh': r'time\.sleep|\bsleep\s+|st_mtime|getmtime|\bstat\s+-c\b|\bfind\b.*\s-(?:mmin|newer)\b',
}
PATTERNS['.psm1'] = PATTERNS['.psd1'] = PATTERNS['.ps1']
PATTERNS = {ext: re.compile(pattern) for ext, pattern in PATTERNS.items()}
OK = re.compile(r'timer-ok:\s*([BCDE])\s*[—–-]\s*(.{15,})')


def lex(line, ext, block):
    """Keep executable interpolations, masking literal text and collecting comments."""
    code, comments = [], []
    ps = ext in ('.ps1', '.psm1', '.psd1')

    def quoted(i):
        quote, prefix = line[i], line[:i]
        verbatim = ext == '.cs' and prefix.endswith(('@', '@$', '$@'))
        braces = ((ext == '.cs' and prefix.endswith(('$', '$@', '@$')))
                  or (ext == '.py' and re.search(r'(?i)(?<![\w])(?:f|fr|rf)$', prefix)))
        expanded = quote == '"' and (ps or ext == '.sh')
        code.append('""')
        i += 1
        while i < len(line):
            if line[i] == quote:
                if (ps or verbatim) and line[i:i + 2] == quote * 2:
                    i += 2
                    continue
                return i + 1
            if not verbatim and line[i] == ('`' if ps else '\\') and not ((ps or ext == '.sh') and quote == "'"):
                # Python f-string braces are not escaped by a backslash.
                i += 1 if braces and line[i:i + 2] in ('\\{', '\\}') else 2
            elif expanded and line.startswith('$(', i):
                i = embedded(i + 2, ')')
            elif expanded and ext == '.sh' and line[i] == '`':
                i = embedded(i + 1, '`')
            elif braces and line[i:i + 2] in ('{{', '}}'):
                i += 2
            elif braces and line[i] == '{':
                i = embedded(i + 1, '}', True)
            else:
                i += 1
        return i

    def format_text(i):
        # Format specifiers are literal text; Python permits nested replacement fields.
        while i < len(line) and line[i] != '}':
            i = embedded(i + 1, '}', True) if ext == '.py' and line[i] == '{' else i + 1
        code.append(' ')
        return i + 1

    def embedded(i, stop, field=False):
        # Substitutions execute separately from the surrounding word or literal.
        code.append(' ')
        i = walk(i, stop, field)
        code.append(' ')
        return i

    def walk(i, stop=None, field=False):
        nonlocal block
        while i < len(line):
            if block:
                end = line.find(block, i)
                comments.append(line[i:end] if end >= 0 else line[i:])
                if end < 0:
                    return len(line)
                i, block = end + len(block), None
            elif stop and line[i] == stop:
                code.append(line[i])
                return i + 1
            elif field and line[i] == ':' and not (line.startswith('::', i) or line[i - 1] == ':'):
                return format_text(i + 1)
            elif (ext == '.cs' and line.startswith('/*', i)) or (ps and line.startswith('<#', i)):
                block, i = ('*/' if ext == '.cs' else '#>'), i + 2
            elif (ext == '.cs' and line.startswith('//', i)) or (ext != '.cs' and line[i] == '#'):
                comments.append(line[i + (2 if ext == '.cs' else 1):])
                return len(line)
            elif line[i] in ('"', "'"):
                i = quoted(i)
            elif (ps or ext == '.sh') and line.startswith('$(', i):
                i = embedded(i + 2, ')')
            elif ext == '.sh' and line[i] == '`':
                i = embedded(i + 1, '`')
            elif line[i] == ('`' if ps else '\\') and ext != '.cs':
                code.append(' ')
                i += 2
            elif line[i] in '([{':
                code.append(line[i])
                i = walk(i + 1, {'(': ')', '[': ']', '{': '}'}[line[i]])
            else:
                code.append(line[i])
                i += 1
        return i

    walk(0)
    return ''.join(code), comments, block


def sites(root):
    """Yield the same signatures for checking and explicit baseline generation."""
    for directory in ('app', 'transport', 'build', 'server', 'tests'):
        for path in sorted((root / directory).rglob('*')):
            rel = path.relative_to(root)
            if (not path.is_file() or path.suffix.lower() not in PATTERNS
                    or any(p in {'.git', 'bin', 'obj', '__pycache__', 'node_modules'} for p in rel.parts)
                    or rel.parts[:2] == ('server', 'agent-tools')
                    or rel.as_posix() in ('tests/timer-guard.py', 'tests/test-timer-guard.py')):
                continue
            kind = 'tests' if (any(p.lower() in ('test', 'tests') or p.lower().endswith('.tests')
                                   for p in rel.parts[:-1])
                               or rel.name.startswith(('test-', 'test_'))
                               or rel.name.endswith(('Tests.cs', '_test.py'))) else 'code'
            previous, block = [], None
            for index, line in enumerate(path.read_text(encoding='utf-8-sig').splitlines()):
                text = line.strip()
                code, comments, block = lex(line, path.suffix.lower(), block)
                annotations = comments + previous
                previous = comments if not code.strip() else []
                if not PATTERNS[path.suffix.lower()].search(code):
                    continue
                signature = (kind, f'{rel.as_posix()}: {text}')
                allowed = any((m := OK.search(value)) and m[1] in ('E' if kind == 'tests' else 'BCD')
                              and len(m[2].strip()) >= 15 for value in annotations)
                yield signature, allowed, f'{rel.as_posix()}:{index + 1}: {text}'


def scan(root, debt_file=None):
    root = Path(root).resolve()
    debt_file = Path(debt_file) if debt_file else root / 'tests/timer-debt.txt'
    debt, errors, count, section = [], [], None, 'code'
    if debt_file.exists():
        for raw in debt_file.read_text(encoding='utf-8').splitlines():
            line = raw.strip()
            header = re.fullmatch(r'#\s*count:\s*(\d+)', line)
            if header:
                count = int(header[1])
            elif line in ('[code]', '[tests]'):
                section = line[1:-1]
            elif line and not line.startswith('#'):
                signature = re.sub(r'\s+#\s*W\d+.*$', '', line)
                debt.append((section, signature))
        if count is None:
            errors.append('DEBT HEADER MISSING: expected # count: N')
        elif len(debt) > count:
            errors.append(f'DEBT COUNT EXCEEDED: {len(debt)} > {count}')
    debt = Counter(debt)
    found, required = Counter(), Counter()
    for signature, allowed, location in sites(root):
        found[signature] += 1
        if not allowed:
            required[signature] += 1
            if required[signature] > debt[signature]:
                errors.append(f'NEW VIOLATION: {location}')
    for (kind, signature), missing in (debt - found).items():
        for _ in range(missing):
            errors.append(f'STALE DEBT ENTRY [{kind}]: {signature} (remove it)')
    return errors


def wave(kind, signature):
    """Frozen audit waves; unmatched findings need W5 review, not a blanket exemption."""
    path, text = signature.split(': ', 1)
    name = Path(path).name
    if kind == 'tests':
        return 'W4'
    if path.startswith('server/') and name in ('server_components.py', 'server_recovery.py',
            'base_network.py', 'lan_vpn.py', 'lan_pc_access.py', 'tg_gateway_setup.py',
            'happier_web.py', 'happier_web_quotas.py', 'agy_usage_scrape.py', 'oneshot_link.py'):
        return 'W4'
    if name in ('StatusView.cs', 'Transport.Daemon.ps1', 'Transport.Common.ps1',
                'Get-TransportStatus.ps1', 'Setup.Common.ps1', 'Wizard.Common.ps1',
                'Wizard.Bootstrap.ps1', 'Wizard.Engine.ps1'):
        return 'W2'
    if name == 'TrayContext.cs':
        return 'W2' if ('Task.Delay' in text or '3600' in text) else 'W3'
    if name in ('VpnStatus.cs', 'VpnWatchdog.cs', 'SearchQuieter.cs', 'Supervisor.cs', 'TrayMenuModel.cs',
                'DiskExplorerController.cs', 'UpdateButtonModel.cs', 'HelperClient.cs',
                'Control.Status.ps1', 'Start-WindowsControl.ps1', 'Sync.Orchestrator.ps1'):
        return 'W3'
    return 'W5'


def write_debt(root, debt_file=None):
    root = Path(root).resolve()
    target = Path(debt_file) if debt_file else root / 'tests/timer-debt.txt'
    entries = sorted(signature for signature, allowed, _ in sites(root) if not allowed)
    lines = [f'# count: {len(entries)}', '# Explicit baseline; never regenerate to make CI pass.',
             '# W2: transport; W3: launcher/control/disk; W4: server/tests; W5: further audit.',
             '# WARNING: lexical matches include metadata and generated fixtures; review before removal.']
    if (root / 'transport/test-transport-bus.ps1').is_file():
        lines += ['# WARNING W4: transport/test-transport-bus.ps1: AssertFinalStatus is unstable;',
                  '# Completion.Run uses Complete(1000): 1 s budget can fail under host load.',
                  '# This is tracked test debt, not a timer signature or permission to retry/skip.']
    for kind in ('code', 'tests'):
        lines += ['', f'[{kind}]']
        lines += [f'{signature} # {wave(kind, signature)}' for section, signature in entries if section == kind]
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    return len(entries)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--debt-file', type=Path)
    parser.add_argument('--write-debt', action='store_true', help='explicitly replace the debt baseline; review its diff')
    args = parser.parse_args()
    if args.write_debt:
        count = write_debt(args.root, args.debt_file)
        print(f'Timer Guard: wrote {count} debt entries; review baseline and WARNING comments')
        return 0
    errors = scan(args.root, args.debt_file)
    print('\n'.join(errors) if errors else 'Timer Guard: OK')
    return int(bool(errors))


if __name__ == '__main__':
    raise SystemExit(main())
