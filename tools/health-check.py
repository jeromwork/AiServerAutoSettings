#!/usr/bin/env python3
"""Проверка health.log (RaLog или JSONL); исходные строки не выводятся."""
import argparse
from datetime import datetime
from pathlib import Path
import json
import re
import sys


TEXT = re.compile(r'^\S+\s+\S+\s+(?:TRACE|DEBUG|INFO|WARN|ERROR|FATAL)\s+'
                  r'\S+\s+([a-z0-9.-]+)\s+s=([^\s]+)(?:\s+(.*))?$')
FIELD = re.compile(r'(?:^|\s)([\w.-]+)=("(?:\\.|[^"\\])*"|\S+)')


def parse(line):
    line = line.lstrip('\ufeff').strip()
    if not line:
        return None
    if line.startswith('{'):
        row = json.loads(line)
        if not isinstance(row, dict):
            raise ValueError()
        event = row.get('event', row.get('evt', row.get('topic')))
        fields = row.get('fields', {})
        if not isinstance(event, str) or not isinstance(fields, dict):
            raise ValueError()
        return event, row.get('s', row.get('session')), fields
    match = TEXT.fullmatch(line)
    if not match:
        raise ValueError()
    event, session, tail = match.groups()
    fields = {}
    for key, value in FIELD.findall(tail or ''):
        if value.startswith('"'):
            value = json.loads(value)
        fields[key] = value
    return event, session, fields


def normalize(name):
    return 'control' if name.lower() == 'bridge' else name.strip()


def stamp(line):
    if line.lstrip('\ufeff ').startswith('{'):
        row = json.loads(line.lstrip('\ufeff'))
        value = row.get('timestamp', row.get('ts', row.get('time')))
    else:
        value = line.lstrip('\ufeff').split()[0]
    when = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if when.tzinfo is None:
        raise ValueError()
    return when


def correlate(health, launcher):
    starts = [i for i, line in enumerate(launcher)
              if line.strip() and parse(line)[0] == 'launcher.start']
    if not starts:
        raise ValueError()
    launcher = launcher[starts[-1]:]
    boundary = stamp(launcher[0])
    health = [line for line in health if line.strip() and stamp(line) >= boundary]
    # Не объединяем s наблюдателя с s лаунчера: его отказы проверяются отдельно.
    failures = [line for line in launcher if line.strip() and stamp(line) >= boundary
                and parse(line)[0] in ('unhandled', 'launcher.fatal', 'update.failed')]
    return health, failures


def check(stream):
    manifest = Path(__file__).resolve().parents[1] / 'build/components.json'
    critical = {normalize(c['name']) for c in json.loads(manifest.read_text())['components']
                if c.get('critical')}
    session = None
    ready = accepted = seen = False
    errors = []
    exits = {}
    for line in stream:
        try:
            record = parse(line)
        except (ValueError, TypeError):
            errors.append('Повреждённая строка журнала.')
            continue
        if record is None:
            continue
        event, current, fields = record
        # В health.log нет start: реальная граница запуска — поле RaLog s.
        # launcher.start учитывается, если передан объединённый журнал.
        if event == 'launcher.start' or (current is not None and current != session):
            ready = accepted = seen = False
            errors = []
            exits = {}
        if current is not None:
            session = current
        seen = True
        if event == 'block.ready':
            ready = True
            block = fields.get('block')
            if isinstance(block, str):
                exits[normalize(block)] = 0
        elif event == 'health.accepted':
            if not ready:
                errors.append('health.accepted получено раньше block.ready.')
            accepted = True
        elif event in ('unhandled', 'launcher.fatal', 'update.failed'):
            errors.append('Обнаружено необработанное исключение (unhandled).')
        elif event == 'health.fuse':
            errors.append('Сработал предохранитель (fuse).')
        elif event == 'component.exit':
            name = fields.get('name')
            if isinstance(name, str) and not accepted and normalize(name) in critical:
                name = normalize(name)
                exits[name] = exits.get(name, 0) + 1
                if exits[name] == 3:
                    errors.append('Три выхода компонента без готовности: возможный crash-loop.')
        for key in ('reason', 'why'):
            reason = fields.get(key)
            if isinstance(reason, str):
                if reason == 'crash-loop' or reason.startswith('crash-loop:'):
                    errors.append('Обнаружен отказ crash-loop.')
                if reason in ('no-progress-fuse', 'fuse'):
                    errors.append('Сработал предохранитель (fuse).')
    if not seen:
        errors.append('Нет событий запуска.')
    if not ready:
        errors.append('Нет block.ready.')
    if not accepted:
        errors.append('Нет health.accepted.')
    return list(dict.fromkeys(errors))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('health', nargs='?', default='-')
    parser.add_argument('--launcher-log')
    args = parser.parse_args()
    try:
        if args.health != '-':
            with open(args.health, encoding='utf-8-sig') as stream:
                health = list(stream)
        else:
            health = list(sys.stdin)
        failures = []
        if args.launcher_log:
            with open(args.launcher_log, encoding='utf-8-sig') as stream:
                health, failures = correlate(health, list(stream))
        errors = check(health)
        if failures:
            errors.append('В launcher.log обнаружен отказ запуска или обновления.')
    except (OSError, UnicodeError, ValueError, TypeError, IndexError, AttributeError):
        print('FAIL: не удалось прочитать или сопоставить журналы.')
        return 1
    if errors:
        print('FAIL: здоровье последнего запуска не подтверждено.')
        for error in errors:
            print('- ' + error)
        return 1
    print('OK: block.ready → health.accepted; признаков отказа в журнале нет.')
    if not args.launcher_log:
        print('launcher.log не проверялся')
    return 0


if __name__ == '__main__':
    sys.exit(main())
