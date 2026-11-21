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
                i = walk(i + 2, ')')
            elif expanded and ext == '.sh' and line[i] == '`':
                i = walk(i + 1, '`')
            elif braces and line[i:i + 2] in ('{{', '}}'):
                i += 2
            elif braces and line[i] == '{':
                i = walk(i + 1, '}', True)
            else:
                i += 1
        return i

    def format_text(i):
        # Format specifiers are literal text; Python permits nested replacement fields.
        while i < len(line) and line[i] != '}':
            i = walk(i + 1, '}', True) if ext == '.py' and line[i] == '{' else i + 1
        code.append(' ')
        return i + 1

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
            elif ext == '.sh' and line[i] == '`':
                i = walk(i + 1, '`')
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
                found[signature] += 1
                allowed = any((m := OK.search(value)) and m[1] in ('E' if kind == 'tests' else 'BCD')
                              and len(m[2].strip()) >= 15 for value in annotations)
                if not allowed:
                    required[signature] += 1
                    if required[signature] > debt[signature]:
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
