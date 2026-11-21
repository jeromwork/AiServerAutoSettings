Сейчас делай только Этап 1. После отчёта остановись.

# Задание C (сложное): одноразовая ссылка — честная одноразовость при параллельных скачиваниях

Рабочий каталог: `WORKDIR` (git worktree, ветка предоставлена набором). Все пути ниже — от него.

**В этом прогоне только Этап 1. После отчёта остановиться.**

## Цель и суть проблемы

`server/oneshot_link.py` раздаёт ZIP по одноразовой ссылке: страница `/<token>` с кнопкой, файл `/<token>/<имя>`.
Вся логика сейчас — замыкание внутри `main()`, тестов нет. Ошибки:

1. **Гонка: ссылка не одноразовая.** Признак `done` ставится только ПОСЛЕ полной отдачи. Пока идёт первое скачивание,
   любой второй запрос файла тоже получает 200 и весь файл (ссылку из чата могут открыть два человека/устройства).
2. **Срок истёк во время скачивания.** `main()` по истечении срока ждёт 2 с, гасит сервер и удаляет файл,
   даже если скачивание ещё идёт.
3. Нельзя проверить без живого запуска на `0.0.0.0`.

В этом задании: только вынести `Link` и `make_server()`, добавить `--bind` и базовые тесты, сохранив поведение. Исправление гонок — отдельная задача.

### Важно для всех тестов: ответ клиенту и смена состояния не синхронны

Клиент может дочитать тело ответа РАНЬШЕ, чем обработчик на сервере вызовет `done.set()` / `release()`.
Поэтому в тестах состояние после запроса проверять только ожиданием с пределом:
`self.assertTrue(self.link.done.wait(2))` но не прямым `assert` сразу после запроса.

---

## Этап 1. Рефакторинг без изменения поведения + базовые тесты

### Файлы Этапа 1
- `server/oneshot_link.py` — изменить;
- `server/tests/test_oneshot_link.py` — создать.

### Шаг 1.1. Структура модуля `server/oneshot_link.py`

Импорты оставить стандартные (можно разнести по строкам). Переписать модуль так (docstring модуля сохранить):

```python
CHUNK = 65536


class Link:
    def __init__(self, path, chunk=CHUNK):
        self.path = os.path.abspath(path)
        self.name = os.path.basename(self.path)
        self.size = os.path.getsize(self.path)
        self.token = secrets.token_urlsafe(18)
        self.chunk = chunk
        self.done = threading.Event()
        # Только для тестов: вызывается перед записью каждого блока, аргумент — уже отправлено байт.
        self.before_chunk = None

    def page_route(self):
        return '/' + self.token

    def file_route_matches(self, route):
        return (route == '/' + self.token + '/' + urllib.parse.quote(self.name)
                or urllib.parse.unquote(route) == '/' + self.token + '/' + self.name)


class Handler(http.server.BaseHTTPRequestHandler):
    # self.server.link — объект Link
    def log_message(self, *args): pass
    def deny(self, code=404): ...   # send_response(code), Content-Length: 0, end_headers()
    def do_GET(self): ...           # перенести логику из старого H.do_GET, используя link = self.server.link


def make_server(link, bind='0.0.0.0', port=18080):
    server = http.server.ThreadingHTTPServer((bind, port), Handler)
    server.daemon_threads = True
    server.link = link
    return server
```

В Этапе 1 поведение `do_GET` — ТОЧНО как сейчас (страница, 404 на чужие пути и после `done`, отдача файла блоками
по `link.chunk`, `BrokenPipeError/ConnectionResetError` → просто `return`, при `sent == size` печать
`'скачано полностью'` и `link.done.set()`). Перед каждой записью блока вызвать
`if link.before_chunk: link.before_chunk(sent)`. HTML страницы и заголовки — без изменений.

### Шаг 1.2. `main()`

- Добавить аргумент `p.add_argument('--bind', default='0.0.0.0', help='адрес прослушивания')`.
- `link = Link(a.file)`; `server = make_server(link, a.bind, a.port)`; поток `serve_forever` (daemon) как сейчас;
  печать ссылки `'http://%s:%d/%s' % (a.host, a.port, link.token)`.
- Остальное (ожидание `link.done.wait(a.minutes * 60)`, «срок ссылки истёк», `time.sleep(2)`, `shutdown`, удаление
  файла без `--keep`) — как сейчас. Добавить `server.server_close()` после `shutdown()`.

### Шаг 1.3. Тест `server/tests/test_oneshot_link.py` (базовый)

```python
import http.client, sys, tempfile, threading, time, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import oneshot_link
```

Класс `OneshotLinkTests(unittest.TestCase)`:
- Помощник-фабрика `start(self, name='handout.zip')`: во временном каталоге (создать в `setUp`, `addCleanup(cleanup)`)
  записать файл `name` с содержимым `self.data = bytes(range(256)) * 20` (5120 байт);
  `link = oneshot_link.Link(path, chunk=1024)`; `server = oneshot_link.make_server(link, '127.0.0.1', 0)`;
  поток `threading.Thread(target=server.serve_forever, daemon=True).start()`;
  очистка: СНАЧАЛА зарегистрировать `self.addCleanup(server.server_close)`, ПОТОМ `self.addCleanup(server.shutdown)`
  (очистки выполняются в обратном порядке: сперва `shutdown`, затем `server_close`);
  вернуть `(link, server.server_address[1])`.
- `setUp`: `self.link, self.port = self.start()`.
- Помощник `get(self, path, port=None)` → `(status, body_bytes, headers)` через
  `http.client.HTTPConnection('127.0.0.1', port or self.port, timeout=5)`; соединение закрывать в `finally`.
- Помощник `file_path(self, link=None)` → `'/' + (link or self.link).token + '/' + (link or self.link).name`.
- Тесты:
  1. `test_page_then_full_download_then_gone`: страница → 200, в теле есть `file_path()`; файл → 200, тело равно
     `self.data`, заголовок `Content-Length == '5120'`; `self.assertTrue(self.link.done.wait(2))`;
     затем и страница, и файл → 404.
  2. `test_wrong_token_and_paths_are_404`: `'/'`, `'/' + 'x' * 24`, `'/' + token + '/other.zip'`,
     `'/' + token + '/../handout.zip'` → 404; `self.link.done.is_set()` — False.
  3. `test_quoted_name_matches`: `link, port = self.start('my file.zip')`; запрос `'/' + link.token + '/my%20file.zip'`
     на этот `port` → 200, тело == `self.data`.

Вывод `'скачано полностью'` в консоль тестов допустим, подавлять не нужно.

### Проверки Этапа 1 (из `WORKDIR`)

Э1-П1. `python3 -m py_compile server/oneshot_link.py server/tests/test_oneshot_link.py && echo OK` → `OK`.

Э1-П2. `python3 server/oneshot_link.py --help | grep -c -- --bind` → число ≥ 1 (argparse может повторять --bind в usage и options).

Э1-П3. Тест (один раз в конце этапа):
```bash
cd server/tests && timeout 120 python3 -m unittest -v test_oneshot_link; echo EXIT=$?; cd ../..
```
Ожидается: 3 теста `ok`, `OK`, `EXIT=0`, длительность — секунды.

Э1-П4. `git status --short` → ` M server/oneshot_link.py`, `?? server/tests/test_oneshot_link.py`.

---

## Что не трогать / запреты (Этап 1)

- Менять только `server/oneshot_link.py` и `server/tests/test_oneshot_link.py`. Остальное не трогать.
- Работать только в `WORKDIR`. Не коммитить, не пушить, не менять ветки, без `git stash/reset/checkout`.
- НЕ запускать `oneshot_link.py` как сервер вручную (кроме `--help`), не слушать `0.0.0.0` и внешние порты;
  тесты слушают только `127.0.0.1` с портом 0.
- Без сети, без sudo, без systemd. Не трогать `.env`, секреты, `~/work/eportal`, `~/Disk`.
- Без фоновых процессов вне тестов. Только stdlib, никаких сторонних библиотек.

## Правило тестов

Во время работы тесты не запускать — только `python3 -m py_compile`. Один раз в конце каждого этапа — только
`test_oneshot_link` под `timeout` (команды выше). Полные `server/tests/run.sh` и `app/launcher/tests/run.sh` НЕ запускать.
Если тест завис или упал не из-за правки — не чинить окружение, записать в отчёт.

## Формат отчёта (после Этапа 1)

```
ИТОГ: этап N сделан / не сделан, одной-двумя фразами.
ФАЙЛЫ: изменённые/созданные файлы с +/- строк (`git diff --stat`, для нового — `wc -l`).
ПРОВЕРКИ: каждая проверка этапа — команда, фактический результат (последние строки), совпал ли с ожидаемым.
ПРОБЛЕМЫ: что не получилось, отступления от плана и почему; «нет», если нет.
```


## Правила именно этого bench-прогона (приоритет над командами выше)

Все изменения только в WORKDIR; ветка и worktree уже созданы. Не коммитить, не пушить и не переключать ветки.
Во время работы — только py_compile/bash -n. Тесты самостоятельно НЕ запускать: после твоего отчёта набор один раз
выполнит приведённые команды через check.sh под общим timeout 120. Команды выше — спецификация приёмки.
Полные server/tests/run.sh и app/launcher/tests/run.sh не запускать. Не чинить окружение при внешней ошибке.
В отчёте указать, что тесты переданы механической приёмке, а не утверждать, что они уже прошли.
