// ==UserScript==
// @name         Happier: вкладки онлайн
// @namespace    remoteagents
// @version      1.0
// @description  Не отключать Happier при переходе на другую вкладку браузера и держать 8 последних чатов в памяти.
// @match        https://cloud.happier.dev/*
// @run-at       document-start
// @grant        none
// @sandbox      raw
// @inject-into  page
// ==/UserScript==

// Happier в браузере рвёт соединение, когда вкладка скрыта (событие visibilitychange), и при возврате
// догружает пропущенное. Настройками это не выключается, поэтому страница всегда считается видимой.
// Настоящее закрытие и переход со страницы (pagehide) не трогаем.
(() => {
    'use strict';
    const KEY = 'HAPPIER_SYNC_TUNING_JSON';
    const WANT = {
        sessionTranscriptRetentionRecentKeepCount: 8, // сколько чатов держать в памяти
        sessionRealtimeProjectionMode: 'disabled',    // новые сообщения скрытых чатов разбирать сразу
    };
    let current = {};
    try { current = JSON.parse(localStorage.getItem(KEY) || '{}') || {}; } catch { current = {}; }
    localStorage.setItem(KEY, JSON.stringify({ ...current, ...WANT }));

    Object.defineProperty(Document.prototype, 'visibilityState', { configurable: true, get: () => 'visible' });
    Object.defineProperty(Document.prototype, 'hidden', { configurable: true, get: () => false });
    for (const type of ['visibilitychange', 'webkitvisibilitychange', 'freeze']) {
        window.addEventListener(type, (event) => event.stopImmediatePropagation(), true);
    }
})();
