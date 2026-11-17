// The official UI is kept intact; these missing browser options need a head add-on.
(() => {
    'use strict';
    const sessionPolicy = __REMOTEAGENTS_SESSION_POLICY__;
    // Built-in profiles hardcode "default" ahead of account defaults. Wrap only
    // the new-session default resolver; explicit chat choices and drafts still
    // belong to the UI. Discover the export by name, never by bundle module id.
    function wrapDefine(define) {
        return function(factory, ...args) {
            return define.call(this, function(...params) {
                factory.apply(this, params);
                const exports = params[4]?.exports;
                const resolve = exports?.resolveNewSessionDefaultPermissionMode;
                if (sessionPolicy.defaultPermissionMode === 'yolo' && typeof resolve === 'function') {
                    exports.resolveNewSessionDefaultPermissionMode = options => resolve({...options,
                        profileDefaultsByTargetKey: null, accountDefaults: {byTargetKey: {}},
                        legacyProfileDefaultPermissionMode: 'yolo'});
                }
            }, ...args);
        };
    }
    if (typeof window.__d === 'function') window.__d = wrapDefine(window.__d);
    else Object.defineProperty(window, '__d', {configurable: true, get: () => undefined,
        set: define => Object.defineProperty(window, '__d', {configurable: true, writable: true, value: wrapDefine(define)})});
    window.__HAPPIER_WEB_RUNTIME_CONFIG__ = {serverUrl: __REMOTEAGENTS_SERVER_URL__};
    // One-use handoff. Scrub the URL before any vendor code (or resource) can see it.
    // The UI itself owns authentication, key normalization and credential storage.
    const loginSlot = 'remoteagents.happier-login';
    let restoring = false;
    const keyFormat = /^(?:[A-Z2-7]{5}-){10}[A-Z2-7][AQ]$/;
    function hasLogin() {
        // TokenStorage uses scopedStorageId(`${base}__srv_${serverId}`, null),
        // with legacy auth_credentials. Preserve ANY saved account, even another server.
        for (let i = 0; i < localStorage.length; i++) {
            const name = localStorage.key(i);
            if (name !== 'auth_credentials' && !name?.startsWith('auth_credentials__srv_')) continue;
            try {
                const value = JSON.parse(localStorage.getItem(name));
                if (typeof value?.token === 'string' && value.token.trim()) return true;
            } catch { /* A corrupt entry is not a login. */ }
        }
        return false;
    }
    function autoLogin(event) {
        try {
            if (location.hash.startsWith('#ra-login=')) {
                event?.stopImmediatePropagation(); // Do not route a handoff as an Expo hash link.
                const key = location.hash.slice('#ra-login='.length);
                history.replaceState(history.state, '', location.pathname + location.search);
                sessionStorage.removeItem(loginSlot);
                if (keyFormat.test(key)) sessionStorage.setItem(loginSlot, JSON.stringify({key, at: Date.now()}));
            }
            const raw = sessionStorage.getItem(loginSlot);
            if (!raw) return;
            // Consume before parsing, navigation retry or any asynchronous work.
            sessionStorage.removeItem(loginSlot);
            const pending = JSON.parse(raw);
            if (!keyFormat.test(pending.key) || !Number.isFinite(pending.at) ||
                Date.now() - pending.at > 30000 || hasLogin() || restoring) return;
            restoring = true;
            if (location.pathname !== '/restore/manual') {
                if (pending.navigated) return;
                sessionStorage.setItem(loginSlot, JSON.stringify({...pending, navigated: true}));
                location.replace('/restore/manual' + location.search);
                return;
            }
            let secret = pending.key;
            pending.key = '';
            const deadline = Date.now() + 20000;
            const timer = setInterval(() => {
                try {
                    if (hasLogin() || Date.now() > deadline) { clearInterval(timer); secret = ''; return; }
                    const input = document.querySelector('input[data-testid="restore-manual-secret-input"]');
                    const submit = document.querySelector('[data-testid="restore-manual-submit"]');
                    if (!input || !submit || submit.getAttribute('aria-disabled') === 'true' || submit.disabled) return;
                    clearInterval(timer);
                    // Bypass React's value tracker, then deliver its normal input event.
                    const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
                    setValue.call(input, secret);
                    secret = '';
                    input.dispatchEvent(new Event('input', {bubbles: true}));
                    // Allow the controlled field's state/submit closure to commit first.
                    setTimeout(() => {
                        try { if (!hasLogin() && input.isConnected && submit.isConnected) submit.click(); }
                        catch { /* Incompatible UI: leave its ordinary screen. */ }
                        finally {
                            setValue.call(input, '');
                            input.dispatchEvent(new Event('input', {bubbles: true}));
                        }
                    }, 0);
                } catch { clearInterval(timer); secret = ''; }
            }, 100);
        } catch {
            // Storage denied, incompatible UI or malformed handoff: ordinary Happier.
            try { sessionStorage.removeItem(loginSlot); } catch { /* no storage */ }
        }
    }
    window.addEventListener('hashchange', autoLogin, true);
    autoLogin();
    const KEY = 'HAPPIER_SYNC_TUNING_JSON';
    let current = {};
    try {
        current = JSON.parse(localStorage.getItem(KEY) || '{}');
        if (!current || Array.isArray(current) || typeof current !== 'object') current = {};
    } catch { current = {}; }
    try {
        localStorage.setItem(KEY, JSON.stringify({...current,
            sessionTranscriptRetentionRecentKeepCount: __REMOTEAGENTS_KEEP_CHATS__,
            sessionRealtimeProjectionMode: 'disabled'}));
    } catch { /* Private browsing may deny storage; runtime/visibility still apply. */ }
    Object.defineProperty(Document.prototype, 'visibilityState', {configurable: true, get: () => 'visible'});
    Object.defineProperty(Document.prototype, 'hidden', {configurable: true, get: () => false});
    for (const type of ['visibilitychange', 'webkitvisibilitychange', 'freeze']) {
        window.addEventListener(type, event => event.stopImmediatePropagation(), true);
    }
    function resetTime(value) {
        const date = new Date(value);
        if (!value || !Number.isFinite(date.getTime())) return '';
        const pad = n => String(n).padStart(2, '0');
        return `${pad(date.getHours())}:${pad(date.getMinutes())} ${pad(date.getDate())}.${pad(date.getMonth() + 1)}`;
    }
    function mount() {
        if (document.getElementById('remoteagents-quotas')) return;
        const style = document.createElement('style');
        // Shrink the body rather than moving React's root with a transform: fixed
        // dialogs keep their containing block and their normal stacking order.
        style.textContent = `html {--ra-quota-height:24px} body {box-sizing:border-box!important;
          padding-top:var(--ra-quota-height)!important} #root {height:100%!important}
          #remoteagents-quotas {position:fixed;top:0;left:0;right:0;height:auto;min-height:24px;
          box-sizing:border-box;padding:3px 8px;background:#20252b;color:#eee;font:12px/18px sans-serif;
          white-space:nowrap;overflow:auto;z-index:1} #remoteagents-quotas span {display:inline-block}`;
        document.head.append(style);
        const bar = document.createElement('div');
        bar.id = 'remoteagents-quotas'; bar.setAttribute('role', 'status');
        bar.textContent = 'лимиты: нет данных';
        document.body.append(bar);
        // The upstream auth selector collapses to an unlabeled key icon on
        // narrow screens. Expose that same selector without inventing bindings.
        const accountButton = document.createElement('button');
        accountButton.type = 'button';
        accountButton.textContent = 'Аккаунт чата';
        accountButton.title = Object.entries(sessionPolicy.claudeAccountLabels).map(([id, label]) => `${id}: ${label}`).join(' · ');
        accountButton.style.cssText = 'margin-right:8px;color:inherit;background:#343c45;border:1px solid #68717c;border-radius:3px;cursor:pointer';
        const authSelector = () => document.querySelector('[data-testid="new-session-connected-services-auth-chip"]');
        accountButton.onclick = () => authSelector()?.click();
        function showAccountSelector() {
            const present = !!authSelector();
            if (accountButton.hidden === !present) return;
            accountButton.hidden = !present;
        }
        accountButton.hidden = true;
        new MutationObserver(showAccountSelector).observe(document.body, {childList:true, subtree:true});
        showAccountSelector();
        const resize = () => document.documentElement.style.setProperty('--ra-quota-height', `${bar.getBoundingClientRect().height}px`);
        new ResizeObserver(resize).observe(bar); resize();
        function render(data) {
            bar.replaceChildren(accountButton);
            const accounts = Array.isArray(data.accounts) ? data.accounts : [];
            if (!accounts.length) { bar.append(document.createTextNode('лимиты: нет данных')); return; }
            accounts.forEach((account, i) => {
                if (i) bar.append(document.createTextNode(' | '));
                const line = document.createElement('span');
                const windows = Array.isArray(account.windows) ? account.windows : [];
                const status = {auth_required:'нужен вход', paused:'пауза', unknown:'нет данных', disabled:'опрос выключен', error:'ошибка опроса'};
                line.textContent = `${account.label}: ` + (status[account.status] ? status[account.status] + (windows.length ? '; ' : '') : (windows.length ? '' : 'нет данных'));
                const age = account.fetchedAt ? Math.max(0, Math.floor((Date.now() - Date.parse(account.fetchedAt)) / 60000)) : null;
                const tips = [age === null ? 'нет данных' : `Данные: ${age} мин назад`];
                windows.forEach((w, j) => {
                    if (j) line.append(document.createTextNode(' · '));
                    const part = document.createElement('span');
                    const used = typeof w.usedPercent === 'number' && Number.isFinite(w.usedPercent) ? w.usedPercent : null;
                    part.textContent = `${w.label} ${used === null ? 'нет данных' : Math.round(used) + '%'}`;
                    const reset = resetTime(w.resetsAt);
                    if (typeof w.remainingPercent === 'number' && Number.isFinite(w.remainingPercent)) part.textContent += ` (ост. ${Math.round(w.remainingPercent)}%)`;
                    if (reset) part.textContent += ` ${reset}`;
                    if (used >= 95) part.style.color = '#ff7777';
                    else if (used >= 80) part.style.color = '#ffd45c';
                    tips.push(`${w.label}: ${reset || 'время неизвестно'}`);
                    line.append(part);
                });
                if (account.retryAt) tips.push(`Следующий опрос: ${new Date(account.retryAt).toLocaleString('ru-RU')}`);
                line.title = tips.join('\n'); bar.append(line);
            });
        }
        async function poll() {
            try {
                const response = await fetch('/_remoteagents/quotas', {cache:'no-store', credentials:'omit'});
                if (!response.ok) throw Error();
                render(await response.json());
            } catch { bar.replaceChildren(accountButton, document.createTextNode('лимиты: нет данных')); }
        }
        poll(); setInterval(poll, 60000);
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mount, {once:true});
    else mount();
})();
