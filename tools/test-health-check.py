#!/usr/bin/env python3
"""Микротесты CLI на временных журналах, без сторонних зависимостей."""
import importlib.util
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
        ('выходы после приёмки', healthy() + ''.join(
            event('component.exit', name='transport', code='1') for _ in range(3)), 0),
        ('готовность сбрасывает выходы', event('component.exit', name='tray', code='1')
         + event('component.exit', name='tray', code='1') + healthy()
         + event('component.exit', name='tray', code='1'), 0),
        ('граница объединённого журнала', healthy() + event('launcher.start')
         + event('block.ready'), 1),
    ]
    spec = importlib.util.spec_from_file_location('health_check', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    golden = (SCRIPT.parent.parent / 'app/launcher/tests/fixtures/logging/golden-lines.txt')
    lines = golden.read_text(encoding='utf-8-sig').splitlines()
    assert module.parse(lines[3])[2] == {'code': '1', 'tail': 'say "hi" now'}
    assert module.parse(lines[9])[2] == {
        'path': r'C:\Users\Ева\Disk', 'msg': r'C:\Program Files\App'}
    assert module.normalize('BRIDGE') == 'control'
    exits = text('component.exit', fields='seq=2 source=launcher name=transport code=1')
    ready = text('block.ready', fields='seq=3 source=launcher block=transport')
    accepted = text('health.accepted', fields='seq=4 source=launcher')
    cases += [
        ('критичный crash-loop', exits * 3 + ready + accepted, 1),
        ('некритичный', exits.replace('name=transport', 'name=control') * 3
         + ready + accepted, 0),
        ('сброс критичного', exits * 2 + ready + exits + accepted, 0),
        ('текст crash-loop', ready + accepted + text('update.failed',
         fields='seq=5 source=launcher reason=crash-loop:control'), 1),
        ('текст fuse', ready + accepted + text('update.failed',
         fields='seq=5 source=launcher reason=no-progress-fuse'), 1),
        ('эталоны полей', '\n'.join(lines[:11]) + '\n'
         + text('block.ready', '7f3a') + text('health.accepted', '7f3a'), 0),
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
        launcher = Path(directory) / 'launcher.log'
        start = text('launcher.start')
        older = lambda value: value.replace('12:00:00.000Z', '11:00:00.000Z')
        launcher_cases = [
            ('чистый launcher', ready + accepted, start, 0),
            ('launcher unhandled', ready + accepted, start + text('unhandled'), 1),
            ('launcher fatal', ready + accepted, start + text('launcher.fatal'), 1),
            ('launcher crash-loop', ready + accepted, start + text('update.failed',
             fields='reason=crash-loop:control'), 1),
            ('launcher fuse', ready + accepted, start + text('update.failed',
             fields='reason=no-progress-fuse'), 1),
            ('наблюдатель', ready + accepted, start + text('update.failed', 'watcher',
             'reason=process-exited'), 1),
            ('старые события', older(text('unhandled')) + ready + accepted,
             older(start + text('unhandled') + text('update.failed', 'watcher')) + start, 0),
            ('старая приёмка', older(ready + accepted), start, 1),
            ('нет границы', ready + accepted, text('unhandled'), 1),
        ]
        for name, contents, log, expected in launcher_cases:
            path.write_text(contents, encoding='utf-8')
            launcher.write_text(log, encoding='utf-8')
            result = subprocess.run([sys.executable, str(SCRIPT), str(path),
                                     '--launcher-log', str(launcher)],
                                    capture_output=True, text=True, check=False)
            assert result.returncode == expected, (name, result.stdout, result.stderr)
            assert SECRET not in result.stdout + result.stderr
            assert 'launcher.log не проверялся' not in result.stdout
        result = subprocess.run([sys.executable, str(SCRIPT)], input=healthy(),
                                capture_output=True, text=True, check=False)
        assert result.returncode == 0, result.stdout
        assert 'launcher.log не проверялся' in result.stdout
        result = subprocess.run([sys.executable, str(SCRIPT), str(path / SECRET)],
                                capture_output=True, text=True, check=False)
        assert result.returncode == 1 and SECRET not in result.stdout + result.stderr
    print(f'OK: {len(cases) + len(launcher_cases) + 6} проверок.')


if __name__ == '__main__':
    main()
