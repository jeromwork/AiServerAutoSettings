#!/usr/bin/python3
"""Offline Happier API boundary only. Installer/version are tested separately."""
import json
import os
from pathlib import Path
import signal
import sys
if '--version' in sys.argv:
    print('0.2.17')
elif sys.argv[1:] == ['daemon', 'start-sync']:
    assert json.loads((Path.home() / '.happier/access.key').read_text())['token'] == 'HAPPY_FIXTURE_SENTINEL'
    assert os.environ['CLAUDE_CODE_OAUTH_TOKEN'] == 'CLAUDE_FIXTURE_SENTINEL'
    signal.pause()
else:
    raise SystemExit(1)
