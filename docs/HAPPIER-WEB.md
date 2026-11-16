# Happier с нашего сервера (план А, решение владельца 16.11.2026)

## Зачем

Облачная страница Happier (`cloud.happier.dev`) в браузере:
- держит в памяти только 3 последних чата, остальные через 3 минуты стираются и при открытии грузятся заново;
- на скрытой вкладке браузера рвёт соединение (`visibilitychange` в `apps/ui/sources/sync/sync.ts`), при возврате
  переподключается и догружает пропущенное — секунды и десятки секунд;
- лимиты подписок видны только в настройках и у поля ввода, для Claude с setup-token — пусто.

Владелец: никаких расширений браузера, всё встроено. Поэтому наш сервер раздаёт **официальный подписанный
веб-интерфейс Happier** со встроенной добавкой, а кнопка «Открыть Happier» в RemoteAgents открывает его через канал.
Аккаунт, чаты и мобильное приложение остаются в облаке Happier (`api.happier.dev`), свой сервер Happier не ставится.

## Как устроено

```
Браузер ── http://127.0.0.1:47831 ── канал EXE (sing-box) ── сервер 127.0.0.1:<port> ── служба happier-web
                                                                                         ├─ /            официальный ui-web + добавка
                                                                                         ├─ /_remoteagents/health
                                                                                         └─ /_remoteagents/quotas
Страница ── напрямую https://api.happier.dev (HTTP + Socket.IO, CORS `*` проверен 16.11.2026)
```

- **Адрес сервера Happier** задаётся штатно: `window.__HAPPIER_WEB_RUNTIME_CONFIG__ = {serverUrl: "https://api.happier.dev"}`
  до бандла (есть в релизе ui-web v0.2.21). Без этого UI считает сервером сам origin.
- **Origin постоянный**: `http://127.0.0.1:47831` (loopback — secure context, WebCrypto работает). От origin зависят
  `localStorage` и вход; на новом origin нужен один вход в тот же аккаунт (ключ или QR).
- **Добавка** (`<script>` в `<head>` до бандла, отдельный файл, без зависимостей):
  1. runtime-конфиг сервера (выше);
  2. `localStorage.HAPPIER_SYNC_TUNING_JSON` слить с `{sessionTranscriptRetentionRecentKeepCount: N, sessionRealtimeProjectionMode: "disabled"}`
     (N из конфига, по умолчанию 8) — штатный ключ Happier (`apps/ui/sources/sync/runtime/syncTuning.ts`);
  3. `document.visibilityState` всегда `visible`, `hidden` всегда `false`, события `visibilitychange`,
     `webkitvisibilitychange`, `freeze` перехватываются на `window` в фазе capture. `pagehide` не трогать;
  4. плашка лимитов: тонкая полоса сверху вне React-корня, данные `/_remoteagents/quotas` раз в 60 с, отступ под неё
     у страницы, чтобы не перекрывать интерфейс. Нет данных — честно «нет данных», не 0%.
- **Почему свой код** (конституция §2): готового режима «держать чаты онлайн» и показа лимитов setup-token в Happier
  нет; правим не Happier, а только добавляем маленький скрипт к его официальному релизу.

## Обновление ui-web

Отдельный таймер (по умолчанию раз в 6 ч): последний не-prerelease релиз `ui-web-v*` с GitHub `happier-dev/happier` →
проверка `checksums-…txt.minisig` закреплённым ключом `RWQ85PZ7FyiukYbL3qv/bKnwgbT68wLVzotapeMFIb8n+c7pBQ7U8W2t`
(из `scripts/release/installers/happier-release.pub` Happier) → SHA256 архива → безопасная распаковка (без `..`,
ссылок, абсолютных путей) → вставка добавки → проверка (index.html отдаётся, добавка на месте) → атомарная смена
`current`. Хранятся `keepReleases` (по умолчанию 2) последних версий; хешированные файлы прежних версий тоже
раздаются, чтобы открытая вкладка догрузила старый chunk. Сбой обновления не трогает работающую версию.

## Лимиты

Один опросчик на сервере, страницы читают только кэш.
- Аккаунты Claude: managed `agents.claude` (`~/.config/remoteagents/claude.env`), `~/.claude/.credentials.json`,
  подключённые профили Happier (`~/.happier/servers/*/daemon/connected-services/homes/claude-subscription/<profile>/claude/claude-config/.credentials.json`).
  Повторяющиеся токены — одна строка. Подпись — имя профиля Happier или «Claude сервера».
- Claude со scope `user:profile`: `GET https://api.anthropic.com/api/oauth/usage` (как в Happier), раз в 30 мин.
  Только `user:inference` (setup-token): запрос `POST /v1/messages` с `max_tokens: 1` и чтение заголовков
  `anthropic-ratelimit-unified-{5h,7d}-{utilization,reset}`, `…-status`, раз в `claudeProbeSec` (по умолчанию 600).
  Запрос тратит ничтожную часть лимита; выключается `quotas.claudeProbe: false`.
- Codex: `~/.codex/auth.json` (OAuth), `GET https://chatgpt.com/backend-api/wham/usage`, раз в 5 мин.
- 429/`Retry-After` — пауза больше; 401/403 — статус «нужен вход», не 0%. Токены не попадают в JSON и журналы.
- Ответ: `{"schema":1,"accounts":[{"id","provider","label","status","fetchedAt","windows":[{"id","label","usedPercent","resetsAt"}]}]}`.

## Конфиг

Сервер (`serverComponents`, ставит root reconcile, входит в экспорт):

```json
"happierWeb": {"enabled": true, "port": 47831, "updateIntervalHours": 6, "keepReleases": 2,
               "keepChats": 8, "quotas": {"enabled": true, "claudeProbe": true, "claudeProbeSec": 600}}
```

Компьютер (`happier`, конфиг вставкой):

```json
"happier": {"localWeb": {"enabled": true, "port": 47831, "serverPort": 47831}}
```

- Канал EXE поднимает постоянный вход `127.0.0.1:<port>` → сервер `127.0.0.1:<serverPort>` тем же способом, что вход
  SSH/Syncthing. Порт не перевыбирается при каждом запуске (иначе меняется origin). Занят — диагностика, кто держит
  порт, и запасной путь.
- «Открыть Happier» (трей и окно): `GET http://127.0.0.1:<port>/_remoteagents/health` (таймаут ~1,5 с, ожидаемый JSON)
  → открыть локальный адрес; иначе — прежний облачный `webappUrl`. `account.WebUrl` не подменяется.

## Компьютер

- `localWeb` — необязательный строгий объект; при наличии обязательны `enabled`, `port`, `serverPort`,
  допускается общая публичная подсказка `hint`. Порты — целые 1024–65535. Отсутствие объекта выключает вход.
- Клиентская схема принимает также описанный выше `serverComponents.happierWeb`, чтобы полный
  серверный экспорт применялся одним конфигом; серверные файлы/экспорт этой клиентской задачей не меняются.
- Транспорт читает `profile.happier.localWeb`, для прежней/ручной установки — `happier.localWeb`;
  явное выключение в profile имеет приоритет. Поле входит в ревизию для штатного reload.
- Фиксированный порт резервируется до остальных входов, API и блоков проб/SOCKS. При конфликте
  только `happier-web` исключается из конфига; статус и журнал содержат порт, доступные PID/путь процесса
  и действие владельца. Освобождение порта подхватывается при следующем запуске/перезапуске канала.
- Все кандидаты используют общий selector `active`; OpenSSH несёт вход через существующий `ssh -D`.
- Общий resolver трея/окна делает GET без системного прокси и редиректов, проверяет HTTP 200 и
  JSON-объект с логическим `ok: true`, ограничивает ответ 4096 символами. Таймаут 1,5 с охватывает
  заголовки и тело, проверка идёт вне UI-потока. При отказе открывается прежний облачный URL.
  Если облачного адреса нет и локальный недоступен, левый клик показывает окно программы.
  `account.WebUrl` и API-адрес не подменяются.

## Что проверить на Windows (вручную, после «да» владельца)

Вход в тот же аккаунт на `127.0.0.1:47831`, машины и чаты видны; Socket.IO доходит до WebSocket; скрытая вкладка
не рвёт соединение; 8 чатов переключаются без загрузки; плашка лимитов; перезапуск EXE и обновление ui-web не
меняют origin; занятый порт → облачная страница. Ограничение: экономия памяти браузера, сон компьютера и выгрузка
вкладки остаются — для `127.0.0.1` стоит добавить исключение «всегда активен».
