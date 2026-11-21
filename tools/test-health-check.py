#!/usr/bin/env python3
"""Микротесты CLI на временных журналах, без сторонних зависимостей."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

SCRIPT = Path(__file__).with_name('health-check.py')
SECRET = 'SECRET-do-not-print'


def event(topic, session='one', **fields):
    return json.dumps(dict(event=topic, s=session, fields=fields)) + '\n'


def healthy(session='one'):
    return event('block.ready', session, block='tray') + event('health.accepted', session)


def text(topic, session='one', fields=''):
    return ('2026-11-21T12:00:00.000Z 13:00:00.000+01:00 INFO  health    '
            + topic + ' s=' + session + ' ' + fields + '\n')


def main():
    cases = [
        ('здоровая цепочка', healthy(), 0),
        ('нет приёмки', event('block.ready'), 1),
        ('исключение', healthy() + event('unhandled', message=SECRET), 1),
        ('crash-loop', healthy() + event('health.rollback', why='crash-loop:tray'), 1),
        ('fuse', healthy() + event('health.fuse'), 1),
        ('причина fuse', healthy() + event('health.rollback', reason='no-progress-fuse'), 1),
        ('последний здоров', event('unhandled') + healthy('two'), 0),
        ('последний нездоров', healthy() + event('block.ready', 'two'), 1),
        ('повреждённый jsonl', healthy() + '{' + SECRET + '\n', 1),
        ('порядок', event('health.accepted') + event('block.ready'), 1),
        ('пустой журнал', '', 1),
        ('неверный тип', '[]\n', 1),
        ('текст RaLog', '\ufeff' + text('block.ready') + text('health.accepted'), 0),
        ('сессии RaLog', text('unhandled') + text('block.ready', 'two')
         + text('health.accepted', 'two'), 0),
        ('повторные выходы', healthy() + ''.join(
            event('component.exit', name='control', code='1') for _ in range(3)), 1),
        ('готовность сбрасывает выходы', event('component.exit', name='tray', code='1')
         + event('component.exit', name='tray', code='1') + healthy()
         + event('component.exit', name='tray', code='1'), 0),
        ('граница объединённого журнала', healthy() + event('launcher.start')
         + event('block.ready'), 1),
    ]
    with tempfile.TemporaryDirectory(prefix='health-check-') as directory:
        path = Path(directory) / 'health.log'
        for name, contents, expected in cases:
            path.write_text(contents, encoding='utf-8')
            result = subprocess.run([sys.executable, str(SCRIPT), str(path)],
                                    capture_output=True, text=True, check=False)
            assert result.returncode == expected, (name, result.stdout, result.stderr)
            assert SECRET not in result.stdout + result.stderr, name
            assert result.stdout.startswith('OK:' if expected == 0 else 'FAIL:'), name
        result = subprocess.run([sys.executable, str(SCRIPT)], input=healthy(),
                                capture_output=True, text=True, check=False)
        assert result.returncode == 0, result.stdout
        result = subprocess.run([sys.executable, str(SCRIPT), str(path / SECRET)],
                                capture_output=True, text=True, check=False)
        assert result.returncode == 1 and SECRET not in result.stdout + result.stderr
    print(f'OK: {len(cases) + 2} проверок.')


if __name__ == '__main__':
    main()
