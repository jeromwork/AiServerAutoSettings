#!/usr/bin/env python3
"""Снимает остаток квоты Gemini из `/usage` в agy (облачные методы для 3.8 Flash отдают неверные данные).

Пишет ~/.cache/remoteagents/agy-usage.json; читает его happier_web_quotas.py.
Запуск по cron раз в 10 минут: python3 agy_usage_scrape.py [--home DIR]. Токены не читает и не пишет: вход держит сам agy.
"""
import fcntl
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

SESSION = 'agy-usage-scrape'
WINDOWS = (('Weekly Limit Remaining', 'seven_day'), ('Five Hour Limit Remaining', 'five_hour'))


def parse_duration(text):
    hours = re.search(r'(\d+)\s*h', text)
    minutes = re.search(r'(\d+)\s*m', text)
    if not hours and not minutes:
        return None
    return (int(hours.group(1)) if hours else 0) * 3600 + (int(minutes.group(1)) if minutes else 0) * 60


def parse(screen):
    """Текст экрана `/usage` → {'gemini': [{'id','remainingPercent','resetsInSec'}], 'other': [...]}."""
    groups, current = {}, None
    lines = [line.strip() for line in screen.splitlines()]
    for i, line in enumerate(lines):
        if line.startswith('GEMINI MODELS'):
            current = 'gemini'
        elif line.startswith('CLAUDE AND GPT'):
            current = 'other'
        for title, ident in WINDOWS:
            if current and line.startswith(title):
                chunk = ' '.join(lines[i + 1:i + 4])
                percent = re.search(r'(\d+(?:\.\d+)?)%', chunk)
                if percent:
                    refresh = re.search(r'Refreshes in ([^\n]*?)(?=Weekly|Five|$)', chunk)
                    groups.setdefault(current, []).append(dict(
                        id=ident, remainingPercent=float(percent.group(1)),
                        resetsInSec=parse_duration(refresh.group(1)) if refresh else None))
    return groups


def tmux(*args):
    return subprocess.run(('tmux',) + args, capture_output=True, text=True, timeout=15)


def capture():
    return tmux('capture-pane', '-t', SESSION, '-p', '-J').stdout


def scrape():
    tmux('kill-session', '-t', SESSION)
    tmux('new-session', '-d', '-s', SESSION, '-x', '170', '-y', '60', '-c', '/tmp', 'agy')
    try:
        screen = ''
        for _ in range(20):
            time.sleep(1)
            screen = capture()
            if 'trust the contents' in screen:
                tmux('send-keys', '-t', SESSION, 'Enter')
            elif 'Select login method' in screen:
                raise RuntimeError('agy не авторизован')
            elif 'Google AI' in screen and '\n> ' in screen:
                break
        time.sleep(1)
        tmux('send-keys', '-t', SESSION, '-l', '/usage')
        time.sleep(1)
        tmux('send-keys', '-t', SESSION, 'Enter')
        for _ in range(15):
            time.sleep(1)
            groups = parse(capture())
            if groups.get('gemini'):
                return groups
        raise RuntimeError('экран /usage не распознан')
    finally:
        tmux('kill-session', '-t', SESSION)


def main():
    home = Path(sys.argv[sys.argv.index('--home') + 1]) if '--home' in sys.argv else Path.home()
    out = home / '.cache/remoteagents/agy-usage.json'
    out.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(out.parent / 'agy-usage.lock', 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return 0
        try:
            data = dict(ok=True, fetchedAt=time.time(), groups=scrape())
        except Exception as error:
            # Прежние проценты остаются, но помечаются устаревшими по fetchedAt.
            data = dict(json.loads(out.read_text()) if out.exists() else {}, ok=False, error=str(error)[:200])
        tmp = out.with_suffix('.tmp')
        tmp.write_text(json.dumps(data, ensure_ascii=False))
        os.chmod(tmp, 0o600)
        tmp.replace(out)
    return 0 if data['ok'] else 1


if __name__ == '__main__':
    sys.exit(main())
