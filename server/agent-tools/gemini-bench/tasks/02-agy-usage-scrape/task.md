# Задание A (средняя): agy_usage_scrape — дни/секунды в сроке сброса и устойчивая запись снимка

Рабочий каталог: `WORKDIR` (git worktree, ветка предоставлена набором). Все пути ниже — от него.
Задание одно, этапов нет.

## Цель

`server/agy_usage_scrape.py` снимает с экрана `agy /usage` остаток квоты Gemini и пишет снимок
`~/.cache/remoteagents/agy-usage.json` (его читает `server/happier_web_quotas.py`). Сейчас две проблемы:

1. `parse_duration()` понимает только часы и минуты (`163h 37m`). Если agy покажет `6d 19h 37m` или `45s`,
   дни и секунды теряются (6 дней превращаются в 19 ч 37 мин).
2. `main()` при ошибке снятия читает прежний снимок через `json.loads(out.read_text())` без защиты.
   Если прежний файл повреждён (не JSON) или в нём не объект (например, список), `main()` падает с исключением,
   новый снимок не пишется. Кроме того, логику записи нельзя проверить тестом без tmux и agy.

Нужно: (1) научить `parse_duration` единицам `d`, `h`, `m`, `s`; (2) вынести запись снимка в отдельную функцию
`write_snapshot(out, scrape_fn)`, устойчивую к повреждённому прежнему файлу; (3) покрыть это юнит-тестами без tmux/сети.

## Файлы

Разрешено менять/создавать ТОЛЬКО:
- `server/agy_usage_scrape.py` — изменить;
- `server/tests/test_agy_usage_scrape.py` — создать новый.

Всё остальное не трогать (в том числе `server/happier_web_quotas.py`, `server/tests/test_happier_web.py`, `server/tests/run.sh`).

## Шаги

### Шаг 1. `parse_duration` (в `server/agy_usage_scrape.py`)

Заменить тело функции так, чтобы она складывала все найденные пары «число + единица», единицы `d` (86400 с),
`h` (3600), `m` (60), `s` (1). После единицы должна быть граница слова (`\b`), чтобы `5 min` не считался минутами
по ошибке у других слов. Если ни одной пары нет — вернуть `None` (как сейчас). Образец:

```python
UNITS = {'d': 86400, 'h': 3600, 'm': 60, 's': 1}


def parse_duration(text):
    found = re.findall(r'(\d+)\s*([dhms])\b', text or '')
    if not found:
        return None
    return sum(int(number) * UNITS[unit] for number, unit in found)
```

`UNITS` поставить рядом с `WINDOWS` в начале модуля. Функцию `parse()` не менять.

Ожидаемо: `parse_duration('163h 37m') == 163*3600+37*60`, `parse_duration('37m') == 2220`,
`parse_duration('6d 19h 37m') == 6*86400+19*3600+37*60`, `parse_duration('45s') == 45`,
`parse_duration('soon') is None`, `parse_duration('') is None`.

### Шаг 2. Функция `write_snapshot(out, scrape_fn)` и упрощённый `main()`

Добавить перед `main()` функцию, а `main()` переписать так, чтобы он только вычислял путь и вызывал её:

```python
def previous_snapshot(out):
    """Прежний снимок; повреждённый или чужой формат — как отсутствующий."""
    try:
        value = json.loads(out.read_text())
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def write_snapshot(out, scrape_fn=None):
    """Снимает квоту и атомарно пишет снимок. 0 — успех или уже идёт другой запуск, 1 — ошибка снятия."""
    scrape_fn = scrape_fn or scrape
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(out.parent / 'agy-usage.lock', 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return 0
        try:
            data = dict(ok=True, fetchedAt=time.time(), groups=scrape_fn())
        except Exception as error:
            # Прежние проценты остаются, но помечаются устаревшими по fetchedAt.
            data = dict(previous_snapshot(out), ok=False, error=str(error)[:200])
        tmp = out.with_suffix('.tmp')
        tmp.write_text(json.dumps(data, ensure_ascii=False))
        os.chmod(tmp, 0o600)
        tmp.replace(out)
    return 0 if data['ok'] else 1


def main():
    home = Path(sys.argv[sys.argv.index('--home') + 1]) if '--home' in sys.argv else Path.home()
    return write_snapshot(home / '.cache/remoteagents/agy-usage.json')
```

Важно: поведение для командной строки не меняется (тот же путь, тот же код выхода, та же блокировка).
Функции `tmux`, `capture`, `scrape` не менять. В `write_snapshot` по умолчанию вызывается настоящий `scrape` —
в тестах его ВСЕГДА подменять аргументом `scrape_fn`.

### Шаг 3. Тест `server/tests/test_agy_usage_scrape.py`

Создать файл (stdlib `unittest`, без сети, без tmux, без настоящего HOME). Импорт модуля:

```python
import fcntl, json, sys, tempfile, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import agy_usage_scrape as scrape
```

Класс `AgyUsageScrapeTests(unittest.TestCase)`, в `setUp` — `tempfile.TemporaryDirectory()` + `addCleanup`,
`self.out = Path(tmp) / 'cache/agy-usage.json'`. Тесты (каждый — отдельный метод):

1. `test_parse_duration_units` — все шесть примеров из шага 1.
2. `test_parse_screen_with_days` — экран:
   ```
   GEMINI MODELS
     Weekly Limit Remaining
       [###] 50%
       Refreshes in 6d 19h 37m
     Five Hour Limit Remaining
       [###] 12.5%
       Refreshes in 45s
   ```
   ожидать `parse(screen)['gemini'] == [dict(id='seven_day', remainingPercent=50.0, resetsInSec=6*86400+19*3600+37*60), dict(id='five_hour', remainingPercent=12.5, resetsInSec=45)]`.
3. `test_success_writes_private_snapshot` — `scrape_fn=lambda: {'gemini': [...любой список...]}`; код 0;
   в файле `ok is True`, `groups` равны переданным, `fetchedAt` — число; права файла `0o600`
   (`self.out.stat().st_mode & 0o777`); файла `agy-usage.tmp` рядом нет.
4. `test_failure_keeps_previous_groups` — заранее записать в `self.out` JSON
   `{"ok": true, "fetchedAt": 1700000000, "groups": {"gemini": [{"id": "five_hour", "remainingPercent": 80, "resetsInSec": 60}]}}`
   (создать родительский каталог); `scrape_fn` бросает `RuntimeError('экран /usage не распознан')`; код 1;
   в файле `ok is False`, `error == 'экран /usage не распознан'`, `fetchedAt == 1700000000`, `groups` прежние.
5. `test_failure_with_corrupt_previous_does_not_crash` — подтесты (`self.subTest`) для содержимого
   `'not json{'` и `'[1, 2]'`: `scrape_fn` бросает `RuntimeError('x')`; код 1, исключения нет;
   в файле ровно ключи `{'ok', 'error'}`, `ok is False`.
6. `test_error_text_is_truncated` — `scrape_fn` бросает `RuntimeError('E' * 500)`; `len(data['error']) == 200`.
7. `test_concurrent_run_is_skipped` — создать каталог `self.out.parent`, открыть
   `self.out.parent / 'agy-usage.lock'` и взять `fcntl.flock(f, fcntl.LOCK_EX)`; при удержанной блокировке
   `write_snapshot(self.out, scrape_fn=…)` возвращает 0, `scrape_fn` НЕ вызван (проверить флагом/списком),
   `self.out` не существует. Блокировку снять в `finally`.

В конце файла: `if __name__ == '__main__': unittest.main()`. Объём теста — примерно 80–110 строк.

## Что не трогать / запреты

- Работать только в `WORKDIR`. Не коммитить, не пушить, не менять ветки, не делать `git stash/reset/checkout`.
- Не запускать `agy`, `tmux`, `scrape()` по-настоящему, не трогать настоящий `~/.cache/remoteagents/`.
- Без сети, без sudo, без systemd, без живых служб. Не трогать `.env`, секреты, `~/work/eportal` и что-либо вне worktree.
- Не создавать фоновых процессов. Не менять другие файлы, даже «заодно».

## Правило тестов

Во время работы тесты не запускать — только проверка синтаксиса (`python3 -m py_compile`).
Один раз в конце — только тесты затронутой части (команда П3 ниже), под `timeout 120`.
Полный `server/tests/run.sh` и `app/launcher/tests/run.sh` НЕ запускать. Если тест завис или упал не из-за правки —
не чинить окружение, записать в отчёт.

## Команды проверки (выполнить по порядку, из `WORKDIR`)

П1. Синтаксис:
```bash
python3 -m py_compile server/agy_usage_scrape.py server/tests/test_agy_usage_scrape.py && echo OK
```
Ожидается: `OK`.

П2. Быстрая проверка функции без тестов:
```bash
cd server && python3 -c "import agy_usage_scrape as s; print(s.parse_duration('6d 19h 37m'), s.parse_duration('163h 37m'), s.parse_duration('45s'), s.parse_duration('soon'))"; cd ..
```
Ожидается: `589020 589020 45 None`.

П3. Тесты затронутой части (один раз, в конце):
```bash
cd server/tests && timeout 120 python3 -m unittest -v test_agy_usage_scrape test_happier_web.QuotaTests.test_agy_usage_scrape_parses_screen; echo EXIT=$?; cd ../..
```
Ожидается: все тесты `ok`, в конце `OK` и `EXIT=0` (8 тестов: 7 новых + 1 существующий).

П4. Изменены только разрешённые файлы:
```bash
git status --short
```
Ожидается ровно: ` M server/agy_usage_scrape.py` и `?? server/tests/test_agy_usage_scrape.py`
(если до начала в статусе уже были другие строки — перечислить их в отчёте как «были до меня»).

## Формат отчёта (обязательно, в конце ответа)

```
ИТОГ: сделано / не сделано, одной-двумя фразами.
ФАЙЛЫ: список изменённых/созданных файлов с числом строк (+/-) — из `git diff --stat` и `wc -l` нового файла.
ПРОВЕРКИ: П1–П4 — команда, фактический результат (последние строки вывода), совпал ли с ожидаемым.
ПРОБЛЕМЫ: что не получилось, отступления от плана и почему; «нет», если нет.
```


## Правила именно этого bench-прогона (приоритет над командами выше)

Все изменения только в WORKDIR; ветка и worktree уже созданы. Не коммитить, не пушить и не переключать ветки.
Во время работы — только py_compile/bash -n. Тесты самостоятельно НЕ запускать: после твоего отчёта набор один раз
выполнит приведённые команды через check.sh под общим timeout 120. Команды выше — спецификация приёмки.
Полные server/tests/run.sh и app/launcher/tests/run.sh не запускать. Не чинить окружение при внешней ошибке.
В отчёте указать, что тесты переданы механической приёмке, а не утверждать, что они уже прошли.
