# Happier в браузере: вкладки онлайн

`happier-tabs-online.user.js` — пользовательский скрипт для https://cloud.happier.dev. Он делает две вещи:

1. **Не отключает Happier при переходе на другую вкладку браузера.** Сам Happier в браузере на скрытой вкладке
   рвёт соединение и при возврате догружает пропущенное (`apps/ui/sources/sync/sync.ts`, обработчик
   `visibilitychange`). Настройки для этого нет, поэтому скрипт подменяет `document.visibilityState` на `visible`
   и не пропускает события `visibilitychange`/`freeze`. Закрытие страницы (`pagehide`) не трогается.
2. **Держит 8 последних чатов в памяти** и сразу разбирает новые сообщения скрытых чатов. Пишет в `localStorage`
   ключ `HAPPIER_SYNC_TUNING_JSON` (его читает сам Happier, `apps/ui/sources/sync/runtime/syncTuning.ts`):
   `sessionTranscriptRetentionRecentKeepCount: 8` (по умолчанию 3, лишние стираются через 3 минуты) и
   `sessionRealtimeProjectionMode: "disabled"`. Остальные ключи в этом значении сохраняются.

## Установка

1. Поставить расширение Tampermonkey (Chrome, Edge, Яндекс Браузер, Firefox).
2. Для Chrome/Edge: в свойствах расширения включить «Разрешить пользовательские скрипты» (или режим разработчика).
3. Tampermonkey → «Создать скрипт» → вставить содержимое файла → сохранить.
4. Перезагрузить вкладку Happier.
5. Желательно: в настройках браузера «Производительность → Всегда держать эти сайты активными» добавить
   `cloud.happier.dev`, чтобы браузер сам не выгружал вкладку для экономии памяти.

## Проверка

В консоли вкладки Happier (F12): `document.visibilityState` на скрытой вкладке остаётся `visible`,
`localStorage.getItem('HAPPIER_SYNC_TUNING_JSON')` содержит оба ключа.

Отменить: выключить скрипт в Tampermonkey и выполнить `localStorage.removeItem('HAPPIER_SYNC_TUNING_JSON')`.
