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
    '.sh': r'time\.sleep|\bsleep\s+|st_mtime|getmtime|\bstat\s+-c\s+[\"\']?%Y|\bfind\b.*\s-(?:mmin|newer)\b',
}
PATTERNS['.psm1'] = PATTERNS['.psd1'] = PATTERNS['.ps1']
PATTERNS = {ext: re.compile(pattern) for ext, pattern in PATTERNS.items()}
OK = re.compile(r'timer-ok:\s*([BCDE])\s*[—–-]\s*(.{15,})')


def comment_only(text):
    if text.startswith(('/*', '<#')):
        closing = '*/' if text.startswith('/*') else '#>'
        return closing not in text or not text.split(closing, 1)[1].strip()
    if text.startswith('*') and '*/' in text:
        return not text.split('*/', 1)[1].strip()
    return text.startswith(('#', '//', '*'))


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
    found = Counter()
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
            lines = path.read_text(encoding='utf-8-sig').splitlines()
            for index, line in enumerate(lines):
                text = line.strip()
                if text.startswith(('#', '//', '/*', '*', '<#')) or not PATTERNS[path.suffix.lower()].search(line):
                    continue
                signature = (kind, f'{rel.as_posix()}: {text}')
                found[signature] += 1
                previous = lines[index - 1].strip() if index else ''
                annotations = (text, previous if comment_only(previous) else '')
                allowed = any((m := OK.search(value)) and m[1] in ('E' if kind == 'tests' else 'BCD')
                              and len(m[2].strip()) >= 15 for value in annotations)
                if not allowed and found[signature] > debt[signature]:
                    errors.append(f'NEW VIOLATION: {rel.as_posix()}:{index + 1}: {text}')
    for (kind, signature), missing in (debt - found).items():
        for _ in range(missing):
            errors.append(f'STALE DEBT ENTRY [{kind}]: {signature} (remove it)')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--debt-file', type=Path)
    args = parser.parse_args()
    errors = scan(args.root, args.debt_file)
    print('\n'.join(errors) if errors else 'Timer Guard: OK')
    return int(bool(errors))


if __name__ == '__main__':
    raise SystemExit(main())
