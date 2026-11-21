# Задание: юнит-тесты для server/component_files.py (только тесты, код не менять)

Рабочий каталог: `WORKDIR` (git worktree от `main`, ветка предоставлена набором). Все пути — от него.
Одна задача, этапов нет. Размер: один новый файл ~120–160 строк.

## Цель
`server/component_files.py` — модуль приватного ввода-вывода файлов компонентов (Syncthing, Telegram-шлюз, мост, Happier,
Codex, Claude). Он работает по жёсткому белому списку путей и режет symlink. Отдельных тестов нет (его косвенно трогают
`test_server_components.py` и `test_server_apply.py`). Нужно покрыть тестами именно риск: что запрещённый путь, symlink и
кривые данные отвергаются, а не только что нормальный путь проходит.

## Файлы
Создать ТОЛЬКО `server/tests/test_component_files.py`. Больше ничего не менять и не создавать. `component_files.py` не править:
если тест показал баг — записать в отчёт, тест оставить в виде `unittest.expectedFailure`.

## Как грузить модуль (как в соседних тестах, образец — начало `server/tests/test_close_port_leak.py`)
```python
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('component_files', ROOT / 'component_files.py')
cf = importlib.util.module_from_spec(spec); spec.loader.exec_module(cf)
```
Домашний каталог подменять переменной `HOME` на временную папку (`tempfile.TemporaryDirectory`, `unittest.mock.patch.dict(os.environ, {'HOME': tmp})`);
`Path.home()` на Linux берёт `HOME`. Настоящий `~` не трогать.

## Тесты (класс на группу, имена методов — как ниже)
1. `AllowedTests`
   - `allowed('disk', '.local/share/remote-disk/config.xml')` → True.
   - `allowed('disk', '.ssh/authorized_keys')` → False (чужой вид).
   - `allowed('bridge', '.local/share/remote-agents-nodes/node-1/a_b.json')` → True; `.../NODE/a.json` (заглавные) → False;
     `.local/share/remote-agents-nodes/../x/a.json` → False; вложенность на уровень глубже → False.
   - `allowed('happier', '.happier/servers/s1/access.key')` → True; `.happier/servers/s1/other.txt` → False.
2. `PathTests`
   - обычный путь внутри HOME возвращается как `Path(HOME)/имя`;
   - если `HOME/.ssh` — symlink на другую папку → `cf.path('.ssh/authorized_keys')` бросает `ValueError`;
   - если сам файл — symlink → `ValueError`.
3. `ValidateTests` (`cf.validate`)
   - не словарь, пустой список вместо словаря, значение не строка, имя вне списка → `ValueError`;
   - 257 файлов → `ValueError`;
   - kind `disk`: полный набор из 4 файлов с корректным XML `<configuration/>` и `{"gui": 8384, "listen": 22000}` → возвращает тот же словарь;
     без одного файла → `ValueError`; корень XML не `configuration` → `ValueError`; порт 0, 65536, строка `"8384"` и `True` → `ValueError`
     (`True` — отдельный случай, `type(...) is int`).
   - kind `codex`/`claude` с одним разрешённым файлом → проходит.
4. `MainWriteTests` — запуск через `subprocess.run([sys.executable, ROOT/'component_files.py'], input=json, env={**os.environ,'HOME':tmp}, timeout=20)`
   - действие `write` (любое, кроме `identity`/`read`/`health`), `kind: 'claude'`, `files: {'.config/remoteagents/claude.env': 'A=1\n'}` → код 0, файл создан, права `0o600`;
   - файл `.local/bin/claude` → права `0o700`;
   - имя `.config/evil.txt` (не из списка assets и не unit systemd) → код ≠ 0, файл НЕ создан, в stderr нет содержимого значения;
   - повторная запись того же файла заменяет содержимое, временных файлов (`tmp*`) в каталоге не остаётся.

## Запреты
Не запускать `health` (идёт в сеть). Не писать в настоящий `~`. Не менять другие тесты, не править `run.sh`, не коммитить, не запускать фоновые задачи.

## Правило тестов
Во время работы — только `python3 -m py_compile`. Тесты — один раз в конце, только этот файл, под `timeout 120`. Полный `server/tests/run.sh` НЕ запускать.

## Проверки
- П1 `python3 -m py_compile server/tests/test_component_files.py && echo OK` → `OK`.
- П2 `cd server/tests && timeout 120 python3 -m unittest -v test_component_files; echo EXIT=$?` → все `ok`, `EXIT=0`.
- П3 `git status --short` → ровно `?? server/tests/test_component_files.py`.

## Формат отчёта
```
ИТОГ: сделано / не сделано, одной фразой.
ФАЙЛЫ: список с числом строк.
ПРОВЕРКИ: П1–П3 — команда, фактический результат, совпал ли.
ПРОБЛЕМЫ: найденные баги модуля, отступления; «нет», если нет.
```


## Правила именно этого bench-прогона (приоритет над командами выше)

Все изменения только в WORKDIR; ветка и worktree уже созданы. Не коммитить, не пушить и не переключать ветки.
Во время работы — только py_compile/bash -n. Тесты самостоятельно НЕ запускать: после твоего отчёта набор один раз
выполнит приведённые команды через check.sh под общим timeout 120. Команды выше — спецификация приёмки.
Полные server/tests/run.sh и app/launcher/tests/run.sh не запускать. Не чинить окружение при внешней ошибке.
В отчёте указать, что тесты переданы механической приёмке, а не утверждать, что они уже прошли.
