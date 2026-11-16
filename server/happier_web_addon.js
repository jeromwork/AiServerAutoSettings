// The official UI is kept intact; these missing browser options need a head add-on.
(() => {
    'use strict';
    window.__HAPPIER_WEB_RUNTIME_CONFIG__ = {serverUrl: __REMOTEAGENTS_SERVER_URL__};
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
        const resize = () => document.documentElement.style.setProperty('--ra-quota-height', `${bar.getBoundingClientRect().height}px`);
        new ResizeObserver(resize).observe(bar); resize();
        function render(data) {
            bar.replaceChildren();
            const accounts = Array.isArray(data.accounts) ? data.accounts : [];
            if (!accounts.length) { bar.textContent = 'лимиты: нет данных'; return; }
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
                    if (used >= 95) part.style.color = '#ff7777';
                    else if (used >= 80) part.style.color = '#ffd45c';
                    tips.push(`${w.label}: сброс ${w.resetsAt ? new Date(w.resetsAt).toLocaleString('ru-RU') : 'неизвестен'}`);
                    line.append(part);
                });
                if (age !== null) line.append(document.createTextNode(` (${age} мин)`));
                if (account.retryAt) tips.push(`Следующий опрос: ${new Date(account.retryAt).toLocaleString('ru-RU')}`);
                line.title = tips.join('\n'); bar.append(line);
            });
        }
        async function poll() {
            try {
                const response = await fetch('/_remoteagents/quotas', {cache:'no-store', credentials:'omit'});
                if (!response.ok) throw Error();
                render(await response.json());
            } catch { bar.textContent = 'лимиты: нет данных'; }
        }
        poll(); setInterval(poll, 60000);
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mount, {once:true});
    else mount();
})();
