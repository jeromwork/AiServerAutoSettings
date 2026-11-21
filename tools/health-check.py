#!/usr/bin/env python3
"""Проверка health.log (RaLog или JSONL); исходные строки не выводятся."""
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


def check(stream):
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
                exits[block] = 0
        elif event == 'health.accepted':
            if not ready:
                errors.append('health.accepted получено раньше block.ready.')
            accepted = True
        elif event == 'unhandled':
            errors.append('Обнаружено необработанное исключение (unhandled).')
        elif event == 'health.fuse':
            errors.append('Сработал предохранитель (fuse).')
        elif event == 'component.exit':
            name = fields.get('name')
            if isinstance(name, str) and fields.get('code') is not None:
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
    if len(sys.argv) > 2:
        print('FAIL: укажите путь к health.log или передайте журнал через stdin.')
        return 1
    try:
        if len(sys.argv) == 2 and sys.argv[1] != '-':
            with open(sys.argv[1], encoding='utf-8-sig') as stream:
                errors = check(stream)
        else:
            errors = check(sys.stdin)
    except (OSError, UnicodeError):
        print('FAIL: не удалось прочитать журнал в UTF-8.')
        return 1
    if errors:
        print('FAIL: здоровье последнего запуска не подтверждено.')
        for error in errors:
            print('- ' + error)
        return 1
    print('OK: block.ready → health.accepted; признаков отказа в журнале нет.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
