# Действующий контракт HTTP-агента ПК (v2)

- **SHA (git rev-parse HEAD):** `80f1d0a0d4b99eee088254d5ede152c5e5d542dc`
- **Источники:** `lab/ralab/agent.py` целиком; `lab/ralab/app.py:25-31`; `lab/server/mcp_shim.py:120-306`.

---

## 1. Транспорт, аутентификация и ограничения протокола

- **Слушатель HTTP:** `ThreadingHTTPServer` на `127.0.0.1:0` (`agent.py:91`), поток демона `agent` (`agent.py:97`). Сигнал готовности: событие `agent.ready` с полем `port` (`agent.py:98`).
- **Формат ответов:** JSON `Content-Type: application/json; charset=utf-8`, заголовок `Connection: close` (`agent.py:110-112`).
- **Аутентификация:** токен `secrets.token_urlsafe(32)` генерируется при инициализации агента (`agent.py:64`), маскируется в журнале (`agent.py:65`). Проверка через заголовок `Authorization: Bearer <token>` (`agent.py:123`) через `hmac.compare_digest` (`agent.py:123`). Несовпадение -> HTTP 403 `{"error": "forbidden"}` (`agent.py:125`).
- **Конкурентность:** `BoundedSemaphore(4)` (`agent.py:16,66,139`). При отказе неблокирующего захвата -> HTTP 503 `{"error": "слишком много запросов (максимум 4)"}` (`agent.py:141`).
- **Лимиты POST-запросов:** обязателен заголовок `Content-Length` (`agent.py:146`), иначе HTTP 411 `{"error": "нужен Content-Length"}` (`agent.py:148`). Предел тела: 5 МиБ для `/code` (`CODE_MAX = 5 << 20`), 8 МиБ для остальных (`BODY_MAX = 8 << 20`) (`agent.py:16,149`). Превышение -> HTTP 413 `{"error": "тело слишком большое"}` (`agent.py:151`).
- **Проверка управления компьютером (CTRL):** ручки `POST /exec`, `GET /proc`, `GET /procs`, `POST /kill`, `GET /read`, `POST /write`, `GET /files` проверяют `control.enabled(self.ctx.home)` (`agent.py:130-138`). Если отключено -> HTTP 403 `{"error": "Управление компьютером запрещено на этом ПК"}` (`agent.py:136`, `lab/ralab/control.py:4`).
- **Ошибки маршрута и исключения:** неизвестная ручка -> HTTP 404 `{"error": "нет такой ручки"}` (`agent.py:129`). Исключение в обработчике -> HTTP 500 `{"error": "<КлассИсключения>: <текст>"}` (`agent.py:156`).
- **Журнал агента:** каждый запрос фиксируется: `journal.log('agent', 'request', {'method': method, 'path': path[:200], 'code': code})` (`agent.py:161`).

---

## 2. Маршруты HTTP-агента

### `GET /status`
- **Обработчик:** `agent.py:173-174`.
- **Ответ:** HTTP 200, объект `ctx.status()` (`app.py:25-31`).
- **Поля ответа:** `home` (str), `version` (str), `exe_version` (str), `rollback` (str|null), `computer` (str), `uptime_s` (int), `rss_mb` (float), `events` (int), `agent_port` (int), `color` (str), `state` (str) (`app.py:27-29`); `settings` (`paths`: list[str], `skipped`: str|null, `lans`: list[str], `server`: dict) | null (`app.py:30`); `singbox` (dict), `uplink` (dict), `rounds` (dict), `lan` (list), `forward` (str), `tun` (dict), `vpn` (dict), `disk` (str), `procs` (list[str]) (`app.py:31`).

### `GET /log?n=<int>`
- **Обработчик:** `agent.py:194-195`. Параметр `n` (default 200) (`agent.py:195`).
- **Ответ:** HTTP 200 `{"records": [...]}` (последние n записей из `journal.tail`) (`agent.py:195`).

### `POST /exec`
- **Обработчик:** `agent.py:197-226`. Тело JSON: `cmd` (str, обяз.), `shell` (str, default 'powershell'), `cwd` (str, default `~`), `wait` (bool, default false) (`agent.py:198-199,213,218`).
- **Ограничения:** пустой `cmd` -> HTTP 400 `{"error": "нет cmd"}` (`agent.py:201`). Лимит запущенных процессов: `EXEC_MAX = 64` (`agent.py:16,203`). Если >= 64, очищается один завершённый; если завершённых нет -> HTTP 429 `{"error": "слишком много запущенных процессов"}` (`agent.py:204-207`).
- **Генерация команды:** Windows `cmd` -> `cmd.exe /d /s /c "chcp 65001>nul & <cmd>"` (`agent.py:54-55`); Windows `powershell` -> `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand <UTF16LE_B64>` с UTF-8 выводом (`agent.py:56-58`); POSIX -> `['/bin/sh', '-c', cmd]` (`agent.py:59`).
- **Буферизация:** лимит потока вывода `OUT_MAX = 1 << 20` (1 МиБ) на `out` и `err` (`agent.py:16,32`), отбрасывание старого с установкой флага `truncated = True` (`agent.py:33-36`).
- **Отказ запуска:** OSError/ValueError -> HTTP 500 `{"error": "не запустить: <ErrClass>", "id": eid}` (`agent.py:217`).
- **Ответ при `wait: false`:** HTTP 200 `{"id": eid}` (`agent.py:219`).
- **Ответ при `wait: true`:** ожидание выхода процесса, HTTP 200 `{"id": eid, "exited": true, "code": int|null, "out": str, "err": str, "truncated": bool}` (`agent.py:220-225`).

### `GET /proc?id=<str>&out=<int>&err=<int>&wait=<0|1>`
- **Обработчик:** `agent.py:227-241`. Параметры: `id` (обяз.), `out` (default 0), `err` (default 0), `wait` (default 0) (`agent.py:229,232`).
- **Ошибки:** неизвестный id -> HTTP 404 `{"error": "нет такого процесса"}` (`agent.py:231`).
- **Ожидание:** при `wait=1` поток блокируется на `Condition` до появления новых данных за `out`/`err` или завершения процесса (`agent.py:234-235`).
- **Ответ:** HTTP 200 `{"id": str, "out_b64": str, "err_b64": str, "out_off": int, "err_off": int, "exited": bool, "code": int|null, "truncated": bool}` (`agent.py:238-240`). Флаг `exited: true` возвращается только когда процесс завершён И весь буфер вычитан (`agent.py:239`).

### `GET /procs`
- **Обработчик:** `agent.py:242-243`.
- **Ответ:** HTTP 200 `{"procs": [{"id": str, "cmd": str[:80], "exited": bool, "code": int|null}]}` (`agent.py:243`).

### `POST /kill`
- **Обработчик:** `agent.py:245-251`. Тело JSON: `{"id": str}` (`agent.py:246`).
- **Ошибки:** id отсутствует в `execs` -> HTTP 404 `{"error": "нет такого процесса"}` (`agent.py:248`).
- **Действие:** вызов `procs.kill('exec:' + eid)` (`agent.py:250`).
- **Ответ:** HTTP 200 `{"ok": true}` (`agent.py:251`).

### `GET /read?path=<str>&offset=<int>&length=<int>`
- **Обработчик:** `agent.py:252-263`. Параметры: `path` (str), `offset` (int, default 0), `length` (int, default 4 МиБ, максимум `CHUNK = 4 << 20`) (`agent.py:16,253-254`).
- **Ошибки:** OSError открытия/чтения файла -> HTTP 404 `{"error": "<ErrClass>: <msg[:100]>"}` (`agent.py:261`).
- **Ответ:** HTTP 200 `{"size": int, "offset": int, "b64": str, "eof": bool}` (`agent.py:262`).

### `POST /write`
- **Обработчик:** `agent.py:264-280`. Тело JSON: `path` (str, обяз.), `b64` (str, обяз.), `offset` (int, default 0), `done` (bool, default true) (`agent.py:267,277`).
- **Ошибки:** нет полей или невалидный base64 -> HTTP 400 `{"error": "нужны path, b64 (offset, done необязательно)"}` (`agent.py:269`). Если `offset > 0`, а часть файла `<path>.ralab-part` отсутствует -> HTTP 409 `{"error": "нет начала файла (offset > 0 без предыдущих кусков)"}` (`agent.py:273`).
- **Поведение:** запись во временный файл `<path>.ralab-part` (`agent.py:270,274-276`). При `done: true` — атомарная замена `os.replace` на целевой путь (`agent.py:277-278`).
- **Ответ:** HTTP 200 `{"ok": true, "written": int, "done": bool}` (`agent.py:279`).

### `GET /files?path=<str>`
- **Обработчик:** `agent.py:281-297`. Параметр `path` (default `~`) (`agent.py:282`).
- **Ограничения:** максимум `LIST_MAX = 2000` элементов (`agent.py:16,287-289`). Ошибка доступа к каталогу -> HTTP 404 `{"error": "<ErrClass>: <msg[:100]>"}` (`agent.py:296`).
- **Ответ:** HTTP 200 `{"path": str, "entries": [{"name": str, "dir": bool, "size": int|null, "mtime": int|null}]}` (`agent.py:291-294`).

### `POST /code`
- **Обработчик:** `agent.py:298-303`. Сырое тело (макс. 5 МиБ `CODE_MAX`), заголовок `X-Sha256` (`agent.py:149,299`).
- **Действие:** вызов `ctx.updater.install(body, sha)` (`agent.py:299`).
- **Ошибки:** валидация не прошла (`not res['ok']`) -> HTTP 422 `res` (`agent.py:301`).
- **Ответ:** HTTP 200 `res`, после ответа отправка события `app.restart` в шину (`agent.py:302`).

### `POST /restart`
- **Обработчик:** `agent.py:304-307`. Сброс `ctx.updater.clear_pending()` (`agent.py:305`).
- **Ответ:** HTTP 200 `{"ok": true}`, после ответа отправка события `app.restart` с причиной `'команда ассистента'` (`agent.py:306`).

### `POST /switch`
- **Обработчик:** `agent.py:308-314`. Тело JSON: `{"path": str}` (`agent.py:309`).
- **Ошибки:** пустой `path` -> HTTP 400 `{"error": "нужен path"}` (`agent.py:311`).
- **Ответ:** HTTP 200 `{"ok": true}`, событие `path.switch` с полем `path` (`agent.py:312-313`).

### `POST /vpn`
- **Обработчик:** `agent.py:315-319`. Тело JSON: `{"mode": "off"|"auto"|"only"}` (`agent.py:316-318`).
- **Ошибки:** невалидный режим -> HTTP 400 `{"error": "режим: off, auto или only"}` (`agent.py:318`).
- **Ответ:** HTTP 200, статус `ctx.vpn.status()` (`agent.py:319`).

### `POST /expose`
- **Обработчик:** `agent.py:176-184`. Тело JSON: `{"name": str, "serverPort": int, "pcPort": int|null}` (`agent.py:177,179`).
- **Ошибки:** ValueError -> HTTP 400 `{"error": str}` (`agent.py:181`), OSError -> HTTP 409 `{"error": str}` (`agent.py:183`).
- **Ответ:** HTTP 200, результат `ctx.forward.expose` (`agent.py:179`).

### `POST /unexpose`
- **Обработчик:** `agent.py:185-190`. Тело JSON: `{"name": str}` (`agent.py:187`).
- **Ошибки:** ValueError -> HTTP 400 `{"error": str}` (`agent.py:189`).
- **Ответ:** HTTP 200, результат `ctx.forward.unexpose` (`agent.py:187`).

### `GET /exposed`
- **Обработчик:** `agent.py:191-193`.
- **Ответ:** HTTP 200 `{"exposed": ctx.forward.exposed_status(), "channel": bool}` (`agent.py:192`).

---

## 3. Контракт серверного моста (mcp_shim) к агенту ПК

- **Транспорт:** HTTP-вызовы через обратный туннель SSH `http://127.0.0.1:<port>` (`lab/server/ra_lab.py:51,57`).
- **Заголовки запроса:** `Authorization: Bearer <token>`, `Content-Type: application/json` для тел (`ra_lab.py:53-56`).
- **Предварительная проверка туннеля (pre-flight):** перед любым вызовом `mcp_shim` запрашивает `GET /status` с таймаутом 10 с (`mcp_shim.py:145`). Если код 503 -> `{"ok": false, "reason": "busy"}` (`mcp_shim.py:147`); код != 200 -> `{"ok": false, "reason": "tunnel-down"}` (`mcp_shim.py:149`).
- **Семафоры mcp_shim:** максимум 2 параллельные команды (`CMD_SLOTS = 2`) (`mcp_shim.py:8,216`), максимум 32 фоновых процесса (`PROCS_MAX = 32`) (`mcp_shim.py:8,267`). При нехватке слотов -> `{"ok": false, "reason": "busy"}` (`mcp_shim.py:217,268`). Флаг `exclusive: true` отклоняется как `busy`, если есть активные команды или процессы (`mcp_shim.py:219-221,267-268`).
- **Трансляция путей (`wpath`):** пути соединяются с `windowsReplica`, переход `..` запрещён -> `{"ok": false, "error": "Path outside workspace."}` (`mcp_shim.py:134-142,175,228,272`).

### Трансляция операций MCP в HTTP-вызовы:
1. **`status`:** не делает дополнительных запросов к агенту, возвращает метаданные каталога (`mcp_shim.py:151-153`).
2. **`list`:** вызывает `GET /files?path=<quoted_wpath>` (`mcp_shim.py:156`). Ошибка != 200 -> `{"ok": false, "error": "Path not available."}` (`mcp_shim.py:158`). Ограничивает ответ первыми 200 элементами: `{"ok": true, "entries": [...], "limit": 200}` (`mcp_shim.py:159-160`).
3. **`read`:** запрашивает `GET /read?length=65537&path=<quoted_wpath>` (`mcp_shim.py:162`). Ошибка != 200 -> `{"ok": false, "error": "File not available."}` (`mcp_shim.py:164`). Размер файла > 64 КиБ (65536 байт) -> отказ `{"ok": false, "error": "File exceeds 64 KiB."}` (`mcp_shim.py:165-166`). Декодирует base64 в UTF-8 string -> `{"ok": true, "content": str}` (`mcp_shim.py:167`).
4. **`write`:** проверяет размер UTF-8 содержимого <= 64 КиБ (`len > 65536` -> `{"ok": false, "error": "Content exceeds 64 KiB."}`) (`mcp_shim.py:170-171`). Вызывает `POST /write` с `path`, `b64`, `offset: 0`, `done: True` (`mcp_shim.py:172`). При коде 200 возвращает `{"ok": true, "bytes": len}`, иначе `{"ok": false, "error": "Write failed."}` (`mcp_shim.py:173`).
5. **`command`:** таймаут `timeout_seconds` в диапазоне 1..60 с (default 30) (`mcp_shim.py:213`).
   - Запуск: `POST /exec` с `{"cmd": command, "shell": "powershell", "cwd": wpath(cwd)}` (`mcp_shim.py:187-192`). Код 429/503 -> `busy` (`mcp_shim.py:194`).
   - Опрос вывода: цикл вызовов `GET /proc?id=<eid>&out=<o>&err=<e>&wait=1` с таймаутом HTTP `rem + 2` с (`mcp_shim.py:201,237`). Сбой канала -> `{"ok": false, "reason": "tunnel-down"}` (`mcp_shim.py:243`).
   - По таймауту: вызов `POST /kill` с `{"id": eid}` (таймаут 5 с) (`mcp_shim.py:253`), финальный опрос `GET /proc` без ожидания (`mcp_shim.py:254`).
   - Обрезка вывода: возвращаются последние `OUT_CHARS = 32768` символов (`mcp_shim.py:7,209`). Формат: `{"ok": true, "exit_code": int|null, "output": str, "timed_out": bool, "output_limit_chars": 32768}` (`mcp_shim.py:256-257`).
   - Аварийное завершение: при прерывании отправляется `POST /kill` с таймаутом 2 с (`mcp_shim.py:260`).
6. **`process_start`:** вызывает `POST /exec` через `start_exec` (`mcp_shim.py:192,270`). Сохраняет `eid` со смещениями `[0, 0]` в словаре `self.procs` (`mcp_shim.py:276`). Возврат: `{"ok": true, "id": eid}` (`mcp_shim.py:277`).
7. **`process_poll`:** вызывает `GET /proc?id=<eid>&out=<o>&err=<e>&wait=0` с таймаутом 15 с (`mcp_shim.py:201,285`). Если процесс завершён, удаляет его из `procs` (`mcp_shim.py:294`). Возврат: `{"ok": true, "running": bool, "exit_code": int|null, "output": str[:32768], "output_limit_chars": 32768}` (`mcp_shim.py:296-297`).
8. **`process_stop`:** удаляет процесс из `procs` (`mcp_shim.py:302`), отправляет `POST /kill` с таймаутом 10 с (`mcp_shim.py:305`). Ответ агента 200 или 404 трактуется как успех: `{"ok": true, "stopped": true}` (`mcp_shim.py:306`). При закрытии сессии шима для всех оставшихся процессов посылается `POST /kill` с таймаутом 1 с (`mcp_shim.py:76`).
