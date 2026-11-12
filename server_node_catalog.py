#!/usr/bin/env python3
"""Installer-owned public bindings. Presence is always a live authenticated probe."""
import fcntl
import json
import os
from pathlib import Path
import re
import uuid

IDENT = re.compile(r'[a-z0-9][a-z0-9_-]{0,63}\Z')
LABEL = re.compile(r'win-[a-f0-9]{28}\Z')


def device_name(value, fallback):
    """Human computer name (config device.name -> Bridge deviceName): printable, one line, <=80."""
    text = ' '.join(''.join(ch for ch in value if ch.isprintable()).split()) if isinstance(value, str) else ''
    return text[:80].strip() or fallback


def safe(path):
    path = Path(path).absolute()
    if any(node.is_symlink() for node in (path, *path.parents)):
        raise ValueError('Symlink catalog path')
    return path


def validate(data, home):
    for key in ('projectId', 'hostId'):
        if not IDENT.fullmatch(data.get(key, '')):
            raise ValueError('Invalid catalog identity')
    if not LABEL.fullmatch(data.get('deviceLabel', '')):
        raise ValueError('Invalid device label')
    if data.get('socketPath') != str(Path(home)/'.local/state/codex-remote'/(data['deviceLabel']+'.sock')):
        raise ValueError('Catalog socket mismatch')
    if data.get('serverWorkspace') != str(Path(home)/'work/projects'/data['projectId']):
        raise ValueError('Catalog workspace mismatch')
    if not isinstance(data.get('windowsReplica'), str) or not re.match(r'^[A-Za-z]:\\', data['windowsReplica']):
        raise ValueError('Invalid replica')
    return data


def register(directory, data, home):
    data = validate(data, home)
    directory = safe(directory)
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    host_directory=safe(directory/data['hostId'])
    host_directory.mkdir(mode=0o700,exist_ok=True)
    # One lock per computer: choosing the name, writing this record and renaming the
    # other records of the same hostId must not interleave with another registration.
    lock = safe(host_directory/'.lock')
    with lock.open('a') as guard:
        fcntl.flock(guard, fcntl.LOCK_EX)
        _register(host_directory, data, home)


def _write(host_directory, path, record):
    temporary = host_directory/(uuid.uuid4().hex+'.tmp')
    try:
        with temporary.open('x', encoding='utf-8') as stream:
            json.dump(record, stream, ensure_ascii=False)
        temporary.chmod(0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _register(host_directory, data, home):
    path = safe(host_directory/(data['projectId']+'.json'))
    record = {key: data[key] for key in ('projectId', 'hostId', 'deviceLabel', 'socketPath', 'serverWorkspace', 'windowsReplica', 'allowShell')}
    if data.get('controlOnly') is True:
        record['controlOnly'] = True
    others = [validate(json.loads(safe(other).read_text('utf-8')), home) for other in sorted(host_directory.glob('*.json'))]
    chosen = [device_name(x.get('deviceName'), '') for x in others if x.get('controlOnly') is True and x['hostId'] == data['hostId']]
    given = device_name(data.get('deviceName'), '')
    if data.get('controlOnly') is True:
        # The name chosen in RemoteAgents settings arrives with the control (Bridge)
        # registration; an empty name keeps the previously chosen one.
        record['deviceName'] = given or next((x for x in chosen if x), '') or data['hostId']
    else:
        # Project handoffs only know MachineName: the computer's chosen name wins.
        record['deviceName'] = next((x for x in chosen if x), '') or given or data['hostId']
    record['projectName'] = str(data.get('projectName',data['projectId']))[:120]
    if path.exists():
        previous=validate(json.loads(path.read_text('utf-8')),home)
        if any(previous[key]!=record[key] for key in ('projectId','hostId','deviceLabel','socketPath','serverWorkspace','windowsReplica')):
            raise ValueError('Existing host/project binding differs; explicit repair required')
    # Catalog records contain no token; a stale record never means online.
    _write(host_directory, path, record)
    if data.get('controlOnly') is True and given:
        # The name belongs to the computer, not to one project binding.
        for other in sorted(host_directory.glob('*.json')):
            previous = validate(json.loads(safe(other).read_text('utf-8')), home)
            if previous['hostId'] == data['hostId'] and previous.get('deviceName') != record['deviceName']:
                previous['deviceName'] = record['deviceName']
                _write(host_directory, other, previous)


def records(directory, home):
    directory = safe(directory)
    result = []
    if directory.exists():
        for path in sorted(directory.glob('*/*.json')):
            data = validate(json.loads(safe(path).read_text('utf-8')), home)
            if path.parent.name != data['hostId'] or path.name != data['projectId']+'.json':
                raise ValueError('Catalog file identity mismatch')
            result.append(data)
    return result


def matches(data, status):
    if data.get('controlOnly') is True:
        return (status.get('ok') is True and status.get('device') == data['deviceLabel']
                and isinstance(status.get('workspace'), str)
                and status.get('workspace', '').casefold().rstrip('\\') == data['windowsReplica'].casefold().rstrip('\\')
                and status.get('control_only') is True and status.get('project_id') == data['projectId']
                and status.get('host_id') == data['hostId'])
    guard = status.get('sync_guard', {})
    return (status.get('ok') is True and status.get('device') == data['deviceLabel']
            and status.get('workspace', '').casefold().rstrip('\\') == data['windowsReplica'].casefold().rstrip('\\')
            and guard.get('required') is True and guard.get('project_id') == data['projectId']
            and guard.get('host_id') == data['hostId'] and status.get('file_mutations_enabled') is False)
