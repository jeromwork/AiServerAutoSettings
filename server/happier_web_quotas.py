"""One poller, native credential files, public allowlisted results. Never log responses."""
import datetime as dt
import email.utils
import hashlib
import json
import math
import os
import re
from pathlib import Path
import threading
import time
import urllib.error
import urllib.request

from happier_web_common import atomic, private_dir, read_json

URLS = dict(claude='https://api.anthropic.com/api/oauth/usage',
            probe='https://api.anthropic.com/v1/messages',
            codex='https://chatgpt.com/backend-api/wham/usage',
            gemini='https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels',
            gemini_project='https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist')


def iso(value):
    return dt.datetime.fromtimestamp(value, dt.timezone.utc).isoformat().replace('+00:00', 'Z')


def epoch(value):
    try:
        if isinstance(value, (float, int)) and math.isfinite(value):
            return value
        return dt.datetime.fromisoformat(str(value).replace('Z', '+00:00')).timestamp()
    except (TypeError, ValueError, OverflowError):
        return None


def percent(value, factor=1):
    if type(value) not in (float, int) or not math.isfinite(value) or value < 0:
        return None
    return min(100, value * factor)


def window(name, label, used, reset, factor=1):
    stamp = epoch(reset)
    return dict(id=name, label=label, usedPercent=percent(used, factor), resetsAt=iso(stamp) if stamp is not None else None)


def retry_delay(raw, stamp, interval):
    try:
        retry = max(0, float(raw))
        if not math.isfinite(retry):
            raise ValueError()
    except ValueError:
        try:
            retry = max(0, email.utils.parsedate_to_datetime(raw).timestamp() - stamp)
        except (TypeError, ValueError, OverflowError):
            retry = interval * 2
    return max(interval * 2, retry)


def discover(home, labels=None):
    home = Path(home)
    labels = {'acc1': '20$', 'acc2': '100$', 'default': '100$', 'native': '100$', **(labels or {})}
    result = {}

    def add(provider, label, token, scopes=(), account_id=None):
        if not isinstance(token, str) or not token or any(ord(c) < 33 or ord(c) > 126 for c in token):
            return
        scopes = scopes if isinstance(scopes, list) else []
        if not isinstance(account_id, str) or any(ord(c) < 33 or ord(c) > 126 for c in account_id):
            account_id = None
        ident = hashlib.sha256((provider + ':' + token).encode()).hexdigest()[:24]
        if ident in result:
            # Prefer a profile name, but retain native scope information on copies.
            if 'user:profile' in scopes:
                result[ident]['scopes'] = scopes
            return
        result[ident] = dict(id=ident, provider=provider, label=label[:100], token=token, scopes=scopes, account_id=account_id)

    def claude_oauth(path):
        value = read_json(path, {})
        oauth = value.get('claudeAiOauth') if isinstance(value, dict) else None
        return oauth if isinstance(oauth, dict) else {}

    happier = Path(os.environ.get('HAPPIER_HOME') or home / '.happier')
    for path in sorted(happier.glob('servers/*/daemon/connected-services/homes/claude-subscription/*/claude/claude-config/.credentials.json')):
        oauth = claude_oauth(path)
        add('claude', 'Claude ' + labels.get(path.parents[2].name, path.parents[2].name), oauth.get('accessToken'), oauth.get('scopes', []))
    oauth = claude_oauth(home / '.claude/.credentials.json')
    add('claude', 'Claude сервера', oauth.get('accessToken'), oauth.get('scopes', []))
    try:
        for line in (home / '.config/remoteagents/claude.env').read_text().splitlines():
            if line.startswith('CLAUDE_CODE_OAUTH_TOKEN='):
                add('claude', 'Claude сервера', json.loads(line.split('=', 1)[1]))
    except (OSError, ValueError):
        pass
    codex = read_json(Path(os.environ.get('CODEX_HOME') or home / '.codex') / 'auth.json', {}) or {}
    tokens = codex.get('tokens') if isinstance(codex, dict) else None
    tokens = tokens if isinstance(tokens, dict) else {}
    add('codex', 'Codex', tokens.get('access_token'), account_id=tokens.get('account_id'))
    # agy wraps the standard Go OAuth token in a 'token' object. Never persist it
    # in the public cache; an expired token is left to agy's own refresh lifecycle.
    path = home / '.gemini/antigravity-cli/antigravity-oauth-token'
    agy = read_json(path, {}) or {}
    token = agy.get('token', agy) if isinstance(agy, dict) else {}
    if isinstance(token, dict) and isinstance(token.get('access_token'), str) and token['access_token']:
        add('gemini', 'Gemini', token.get('access_token'))
        ident = hashlib.sha256(('gemini:' + token['access_token']).encode()).hexdigest()[:24]
        if ident in result:
            result[ident]['expires_at'] = epoch(token.get('expiry'))
    return list(result.values())


def gemini_windows(payload):
    """Only requested model quotas; do not infer a window length from resetTime."""
    models = payload.get('models') or {}
    images = payload.get('imageGenerationModelIds') or []
    windows = []
    if not isinstance(models, dict):
        return windows
    for ident, model in sorted(models.items()):
        if not isinstance(model, dict) or not re.fullmatch(r'[a-zA-Z0-9_.()-]{1,120}', ident):
            continue
        label = model.get('displayName') or ident
        if not isinstance(label, str):
            continue
        if not (re.search(r'gemini[- ](?:3[.-]8|4)(?:[- .]|$)', ident + ' ' + label, re.I) or
                ident in images or re.search(r'(?:gemini.*image|nano[- ]banana)', ident + ' ' + label, re.I)):
            continue
        quota = model.get('quotaInfo')
        if not isinstance(quota, dict):
            continue
        label = label[:100]
        # Current Antigravity responses expose one quotaInfo per model. Retain
        # explicit 5-hour/weekly observations if the API supplies them as well.
        entries = [(ident, label, quota)]
        for key, suffix in [('fiveHour', '5 ч'), ('sevenDay', 'неделя')]:
            if isinstance(quota.get(key), dict):
                entries.append((ident + ':' + key, label + ' ' + suffix, quota[key]))
        for key, title, q in entries:
            remaining = percent(q.get('remainingFraction'), 100)
            if remaining is None:
                continue
            w = window(key, title, 100 - remaining, q.get('resetTime'))
            w['remainingPercent'] = remaining
            windows.append(w)
    return windows


class NoRedirect(urllib.request.HTTPRedirectHandler):
    # Credentials must never follow an endpoint redirect to a different origin.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Poller:
    def __init__(self, home, cache, options=None, urls=None, now=time.time):
        self.home, self.cache = Path(home), Path(cache)
        self.options, self.urls, self.now = options or {}, urls or URLS, now
        self.opener = urllib.request.build_opener(NoRedirect())
        self.next = {}
        self.accounts = {}
        saved = read_json(cache, {}) or {}
        # Only our own public records are restored; credentials are always rediscovered.
        for row in saved.get('accounts', []):
            if isinstance(row, dict) and isinstance(row.get('id'), str):
                self.accounts[row['id']] = row
                self.next[row['id']] = epoch(row.get('retryAt')) or 0
        self.stop = threading.Event()

    def fetch(self, account):
        probe = account['provider'] == 'claude' and 'user:profile' not in account['scopes']
        interval = (self.options.get('claudeProbeSec', 600) if probe else 1800) if account['provider'] == 'claude' else 300
        stamp = self.now()
        row = {k: account[k] for k in ('id', 'provider', 'label')}
        previous = self.accounts.get(account['id'], {})
        row.update(status='unknown', fetchedAt=previous.get('fetchedAt'), staleAfterSec=interval,
                   windows=previous.get('windows', []))
        if probe and not self.options.get('claudeProbe', True):
            row.update(status='disabled', windows=[])
            return row, interval
        if account.get('expires_at') is not None and account['expires_at'] <= stamp:
            row['status'] = 'auth_required'
            return row, interval
        headers = {'Authorization': 'Bearer ' + account['token'], 'Accept': 'application/json', 'User-Agent': 'RemoteAgents-HappierWeb/1'}
        data = None
        if account['provider'] == 'claude':
            headers.update({'anthropic-beta': 'oauth-2025-04-20', 'anthropic-version': '2023-06-01'})
            if probe:
                headers['Content-Type'] = 'application/json'
                data = json.dumps({'model': 'claude-haiku-4-5', 'max_tokens': 1, 'messages': [{'role': 'user', 'content': 'Hi'}]}).encode()
        elif account.get('account_id'):
            headers['ChatGPT-Account-Id'] = account['account_id']
        url = self.urls['probe' if probe else account['provider']]
        try:
            if account['provider'] == 'gemini':
                headers['Content-Type'] = 'application/json'
                headers['User-Agent'] = 'antigravity'
                project_request = urllib.request.Request(self.urls['gemini_project'],
                    data=b'{"metadata":{"ideType":"ANTIGRAVITY"}}', headers=headers)
                try:
                    with self.opener.open(project_request, timeout=20) as response:
                        raw = response.read(1024 * 1024 + 1)
                        if len(raw) > 1024 * 1024:
                            raise ValueError('project response too large')
                        project = json.loads(raw).get('cloudaicompanionProject')
                except urllib.error.HTTPError as error:
                    row['status'] = 'auth_required' if error.code in (401, 403) else 'error'
                    delay = interval
                    if error.code == 429:
                        delay = retry_delay(error.headers.get('Retry-After', ''), stamp, interval)
                        row.update(status='paused', retryAt=iso(stamp + delay))
                    error.close()
                    return row, delay
                project = project.get('id') if isinstance(project, dict) else project
                if not isinstance(project, str) or not project:
                    raise ValueError('project unavailable')
                data = json.dumps({'project': project}).encode()
            request = urllib.request.Request(url, data=data, headers=headers)
            try:
                response = self.opener.open(request, timeout=20)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                if response.status in (401, 403):
                    row['status'] = 'auth_required'
                    return row, interval
                if response.status == 429:
                    delay = retry_delay(response.headers.get('Retry-After', ''), stamp, interval)
                    row.update(status='paused', retryAt=iso(stamp + delay))
                    return row, delay
                if not 200 <= response.status < 300:
                    raise ValueError('provider error')
                windows = []
                if probe:
                    for ident, short, label in [('five_hour', '5h', '5 ч'), ('seven_day', '7d', 'неделя')]:
                        prefix = 'anthropic-ratelimit-unified-' + short + '-'
                        used = response.headers.get(prefix + 'utilization')
                        if used is not None:
                            reset = response.headers.get(prefix + 'reset')
                            try:
                                reset = float(reset)
                            except (ValueError, TypeError):
                                pass
                            windows.append(window(ident, label, float(used), reset, 100))
                    row['limitStatus'] = {'allowed':'доступно', 'allowed_warning':'близко к лимиту', 'rejected':'лимит исчерпан'}.get(
                        response.headers.get('anthropic-ratelimit-unified-status'), 'неизвестно')
                else:
                    raw = response.read(1024 * 1024 + 1)
                    if len(raw) > 1024 * 1024:
                        raise ValueError('usage too large')
                    payload = json.loads(raw)
                    if account['provider'] == 'claude':
                        labels = dict(five_hour='5 ч', seven_day='неделя', seven_day_sonnet='неделя Sonnet', seven_day_opus='неделя Opus')
                        for ident, label in labels.items():
                            w = payload.get(ident)
                            if isinstance(w, dict):
                                windows.append(window(ident, label, w.get('utilization'), w.get('resets_at')))
                    elif account['provider'] == 'gemini':
                        windows = gemini_windows(payload)
                    else:
                        rate = payload.get('rate_limit') or {}
                        for ident, label in [('primary_window', '5 ч'), ('secondary_window', 'неделя')]:
                            w = rate.get(ident)
                            if isinstance(w, dict):
                                # The slot does not define the length: a plan may have only a weekly primary window.
                                seconds = w.get('limit_window_seconds')
                                if type(seconds) in (float, int) and seconds > 0:
                                    label = {18000: '5 ч', 86400: 'сутки', 604800: 'неделя'}.get(
                                        seconds, '%g ч' % round(seconds / 3600, 1))
                                reset = w.get('reset_at')
                                if reset is None and type(w.get('reset_after_seconds')) in (float, int):
                                    reset = stamp + w['reset_after_seconds']
                                windows.append(window(ident, label, w.get('used_percent'), reset))
                row.update(status='ok' if any(w['usedPercent'] is not None for w in windows) else 'unknown',
                           fetchedAt=iso(stamp), windows=windows)
        except Exception:
            # No exception text, URL, provider body, headers or credentials escape.
            row['status'] = 'error'
        return row, interval

    def tick(self):
        if not self.options.get('enabled', True):
            self.accounts = {}
        else:
            accounts = discover(self.home, self.options.get('claudeAccountLabels'))
            present = {a['id'] for a in accounts}
            self.accounts = {k: v for k, v in self.accounts.items() if k in present}
            for account in accounts:
                ident = account['id']
                if self.now() < self.next.get(ident, 0):
                    if ident in self.accounts:
                        self.accounts[ident]['label'] = account['label']
                    continue
                row, delay = self.fetch(account)
                self.next[ident] = self.now() + delay
                row['retryAt'] = iso(self.next[ident])
                self.accounts[ident] = row
        atomic(self.cache, json.dumps(dict(schema=1, accounts=list(self.accounts.values())), ensure_ascii=False))

    def run(self):
        private_dir(self.cache.parent)
        while not self.stop.is_set():
            try:
                self.tick()
            except Exception:
                # Broken credential files must not kill static serving or leak values.
                pass
            self.stop.wait(15)
