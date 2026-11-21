Сейчас делай только Этап 1. После отчёта остановись.

# Задание B (объёмное): шлюз Telegram — замена ключа клиента `rotate` и `list --json`

Рабочий каталог: `WORKDIR` (git worktree, ветка предоставлена набором). Все пути ниже — от него.

**В этом прогоне только Этап 1. После отчёта остановиться.**

## Цель

Утилита `server/tg-gateway/tg_gateway_keys.py` (на сервере — `~/.local/bin/tg-gateway-keys`) выдаёт клиентам шлюза
секретные ключи доступа. Сейчас, если ключ клиента утёк, единственный путь — `revoke name` + `add name` (два шага,
между ними клиент без доступа, и легко ошибиться с именем). Нужно:

1. Команда `rotate <имя> [--json]`: атомарно, под той же блокировкой, заменить ключ существующего клиента новым.
   Старый ключ перестаёт работать (шлюз перечитывает файл раз в 2 с), новый выдаётся один раз в том же формате, что у `add`.
2. Ключ `list --json`: машинный список `[{"name": …, "created": …}]` (без хэшей и ключей) — для скриптов.
3. Тесты. Документация — вне этого задания.

Файл ключей `state/keys.json` формат НЕ меняет: `{"version":1,"keys":{"<имя>":{"sha256":"…","created":"<ISO>"}}}`.
У `rotate` поле `created` — время выдачи нового ключа.

## Файлы

Разрешено менять ТОЛЬКО:
- `server/tg-gateway/tg_gateway_keys.py` (Этап 1);
- `server/tg-gateway/test_gateway.py` (Этап 1);
Документацию не менять: она относится к отдельному заданию.

Не трогать: `server/tg-gateway/gateway.py`, `install.sh`, `tg_gateway_setup.py`, `test_install.py`,
`server/component_files.py` (он переиспользует `validate_keys` — эту функцию НЕ менять), всё остальное.

---

## Этап 1. Код и тесты

### Шаг 1.1. `tg_gateway_keys.py`: общая функция выдачи ключа

Добавить функцию (над `main()`), которая готовит новый ключ и запись, но файл не пишет:

```python
def issue(pem, fingerprint, machine):
    """Новый ключ: (запись для keys.json, текст для вывода). Настройки проверяются ДО изменения файла."""
    key = secrets.token_urlsafe(32)
    details = connection_data(key, pem, fingerprint, machine)
    record = {
        "sha256": hashlib.sha256(key.encode("ascii")).hexdigest(),
        "created": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    return record, details
```

### Шаг 1.2. `main()`: разбор аргументов

- Подкоманды с аргументом `name`: `("add", "revoke", "rotate")`. `--json` (`action="store_true"`,
  help `"Данные подключения в JSON"`) — у `add` и `rotate`.
- `list` получает `--json` (`action="store_true"`, help `"Список в JSON"`): `commands.add_parser("list").add_argument(...)`.
- Проверка имени: `if args.command in ("add", "revoke", "rotate") and not NAME.fullmatch(args.name): parser.error(...)` (текст ошибки тот же).

### Шаг 1.3. `main()`: выполнение

- `list`: без `--json` — как сейчас. С `--json`:
  `print(json.dumps([{"name": n, "created": r["created"]} for n, r in sorted(read_keys(path)["keys"].items())]))`.
  Пустой/отсутствующий файл → `[]`.
- Ветка под `with locked_keys(path) as data:` должна стать такой (логика `add` сохраняется полностью):
  - `add`: если имя есть → `KeyErrorMessage("Имя уже существует")`; иначе `pem, fingerprint = certificate()`,
    `record, details = issue(pem, fingerprint, args.json)`, `data["keys"][args.name] = record`.
  - `rotate`: если имени нет → `KeyErrorMessage("Имя не найдено")`; иначе так же `certificate()` + `issue(...)`,
    `data["keys"][args.name] = record` (заменяет старую запись, порядок ключей словаря сохраняется).
  - `revoke`: как сейчас.
  - затем `write_keys(path, data)` (как сейчас — один раз, после подготовки вывода).
- После `with`:
  - `add`: `print(details, end="")` (как сейчас);
  - `rotate`: `print(details, end="")`, и только если НЕ `--json` — дополнительно `print("Прежний ключ отозван")`
    (в `--json` stdout содержит ровно один JSON-объект, как у `add`);
  - `revoke`: `print("Ключ отозван")`.
- Обработка ошибок (`except KeyErrorMessage`, `except (OSError, ValueError, …)`) — без изменений.
  Важно: при любой ошибке до `write_keys` файл ключей не меняется и stdout пустой.

### Шаг 1.4. `test_gateway.py`: помощник `key_command`

Расширить сигнатуру существующего метода `GatewayTests.key_command` (около строки 683) ключевым аргументом
`settings=None`: если `None` — писать `settings.json` как сейчас
(`{"port": 18444, "public_host": "gateway.example"}`), иначе записать строку `settings` как есть.
Остальное поведение помощника не менять (все существующие вызовы продолжают работать).

### Шаг 1.5. `test_gateway.py`: новые тесты в классе `GatewayTests`

Добавить после `test_key_utility_refuses_corrupt_file`. Ключи, попавшие в вывод, добавлять в `self.extra_secrets`
(так проверка журналов шлюза убеждается, что ключи туда не утекли).

1. `test_key_utility_rotate_replaces_key_and_reloads`:
   - `first = json.loads(self.key_command("add", "rot-client", "--json").stdout)`;
     `old = first["base_url"].rsplit("/", 1)[1]`; `self.extra_secrets.append(old)`;
     `self.wait_status(f"/{old}/health", 200)`;
     запомнить `created_before = json.loads(self.keys.read_text())["keys"]["rot-client"]["created"]`.
   - `result = self.key_command("rotate", "rot-client", "--json")`; `data = json.loads(result.stdout)`;
     `set(data) == {"base_url", "ca_pem", "sha256"}`; `new = data["base_url"].rsplit("/", 1)[1]`;
     `self.extra_secrets.append(new)`; `new != old`.
   - В файле: `sha256` у `rot-client` == `hashlib.sha256(new.encode()).hexdigest()`; ни `new`, ни `old` нет в тексте файла;
     `created` — строка, разбирается `datetime.datetime.fromisoformat` (добавить `import datetime` в импорты теста),
     и `>= created_before` при сравнении через `fromisoformat`; другой клиент `test-client` остался в файле без изменений
     (сравнить его запись до и после).
   - Права: `self.keys.stat().st_mode & 0o777 == 0o600`.
   - Шлюз: `self.wait_status(f"/{new}/health", 200)` и `self.wait_status(f"/{old}/health", 404)`.
2. `test_key_utility_rotate_text_and_errors`:
   - `self.key_command("add", "rot-text")` (вывод текста; извлечь ключ регэкспом как в
     `test_key_utility_add_list_revoke_and_reload` и добавить в `extra_secrets`).
   - `result = self.key_command("rotate", "rot-text")`: в stdout ровно одно `"Данные подключения"` и строка
     `"Прежний ключ отозван"`; новый ключ извлечь тем же регэкспом, добавить в `extra_secrets`.
   - Нет имени: `before = self.keys.read_bytes()`; `r = self.key_command("rotate", "missing", check=False)`;
     `r.returncode != 0`, `r.stdout == ""`, `"Имя не найдено" in r.stderr`, файл байт-в-байт тот же.
   - Плохое имя: `self.key_command("rotate", "Bad", check=False).returncode != 0`, файл тот же.
   - Повреждённые настройки: `r = self.key_command("rotate", "rot-text", check=False, settings="{broken")`;
     `r.returncode != 0`, `r.stdout == ""`, файл байт-в-байт тот же (ключ не заменён).
3. `test_key_utility_list_json`:
   - `self.key_command("add", "list-b")` (ключ из вывода — в `extra_secrets`, регэксп как выше);
   - `items = json.loads(self.key_command("list", "--json").stdout)`;
   - `[i["name"] for i in items] == ["list-b", "test-client"]` (сортировка по имени);
     у каждого элемента ровно ключи `{"name", "created"}`; в stdout нет ни одного `sha256` из файла.
   - После `self.keys.unlink()` — `json.loads(self.key_command("list", "--json").stdout) == []`.

Существующие тесты не менять (кроме сигнатуры `key_command` из шага 1.4).

### Проверки Этапа 1 (из `WORKDIR`)

Э1-П1. Синтаксис:
```bash
python3 -m py_compile server/tg-gateway/tg_gateway_keys.py server/tg-gateway/test_gateway.py && echo OK
```
Ожидается: `OK`.

Э1-П2. Справка CLI:
```bash
python3 -I server/tg-gateway/tg_gateway_keys.py rotate --help | head -3; python3 -I server/tg-gateway/tg_gateway_keys.py list --help | grep -c -- --json
```
Ожидается: строка `usage: ... rotate [-h] [--json] name`; затем число ≥ 1 (argparse может повторять --json в usage и options).

Э1-П3. Тесты затронутой части (один раз, в конце этапа; только локальный 127.0.0.1, нужен `openssl`):
```bash
cd server/tg-gateway && timeout 120 python3 -m unittest -v \
  test_gateway.GatewayTests.test_key_utility_rotate_replaces_key_and_reloads \
  test_gateway.GatewayTests.test_key_utility_rotate_text_and_errors \
  test_gateway.GatewayTests.test_key_utility_list_json \
  test_gateway.GatewayTests.test_key_utility_add_list_revoke_and_reload \
  test_gateway.GatewayTests.test_key_utility_new_state_show_cert_and_bad_names \
  test_gateway.GatewayTests.test_key_utility_json \
  test_gateway.GatewayTests.test_key_utility_refuses_corrupt_file; echo EXIT=$?; cd ../..
```
Ожидается: 7 тестов `ok`, `OK`, `EXIT=0`. Обычно укладывается в 30–60 с.

Э1-П4. `git status --short` — только ` M server/tg-gateway/tg_gateway_keys.py` и ` M server/tg-gateway/test_gateway.py`.

---

## Что не трогать / запреты (Этап 1)

- Работать только в `WORKDIR`. Не коммитить, не пушить, не менять ветки, без `git stash/reset/checkout`.
- Не запускать установщик (`install.sh`), systemd, настоящий `~/.local/bin/tg-gateway-keys`, не трогать `~/.local/opt/tg-gateway`.
- Без внешней сети (тесты сами используют только 127.0.0.1:18xxx), без sudo. Не трогать `.env`, секреты, `~/work/eportal`.
- Не менять формат `keys.json` и функцию `validate_keys`. Не выводить ключи/хэши в stderr или в `list`.
- Без фоновых процессов. Других файлов не менять.

## Правило тестов

Во время работы тесты не запускать — только `python3 -m py_compile`. Один раз в конце Этапа 1 — только команда Э1-П3
под `timeout 120`. Полные `server/tests/run.sh`, `app/launcher/tests/run.sh` и весь `test_gateway.py` целиком не запускать.
Если тест завис или упал не из-за правки (например, нет `openssl` или занят порт) — не чинить окружение, записать в отчёт.

## Формат отчёта (после Этапа 1)

```
ИТОГ: этап N сделан / не сделан, одной-двумя фразами.
ФАЙЛЫ: изменённые файлы с +/- строк (`git diff --stat`).
ПРОВЕРКИ: каждая проверка этапа — команда, фактический результат (последние строки), совпал ли с ожидаемым.
ПРОБЛЕМЫ: что не получилось, отступления от плана и почему; «нет», если нет.
```


## Правила именно этого bench-прогона (приоритет над командами выше)

Все изменения только в WORKDIR; ветка и worktree уже созданы. Не коммитить, не пушить и не переключать ветки.
Во время работы — только py_compile/bash -n. Тесты самостоятельно НЕ запускать: после твоего отчёта набор один раз
выполнит приведённые команды через check.sh под общим timeout 120. Команды выше — спецификация приёмки.
Полные server/tests/run.sh и app/launcher/tests/run.sh не запускать. Не чинить окружение при внешней ошибке.
В отчёте указать, что тесты переданы механической приёмке, а не утверждать, что они уже прошли.
