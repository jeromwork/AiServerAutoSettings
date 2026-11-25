# Контракт v2: Code Slots, Update, Push

Базовый коммит: `80f1d0a0d4b99eee088254d5ede152c5e5d542dc` (`git rev-parse HEAD`).
Источники: `lab/exe/CodeSlots.cs`, `lab/exe/LabMain.cs`, `lab/ralab/updater.py`, `lab/ralab/update.py`, `lab/server/ra_lab.py`, `lab/ralab/agent.py`, `lab/ralab/link.py`.

---

## 1. Code Slots и состояние версий (EXE-сторож)

### 1.1 Файлы состояния и правила именования
- **Путь к состоянию**: `<Home>\code\state.json` (`lab/exe/CodeSlots.cs:25`). Запись атомарная: запись в `.tmp` + `File.Replace` или `File.Move` (`lab/exe/CodeSlots.cs:62-64`).
- **Схема `state.json`** (`lab/exe/CodeSlots.cs:36-38, 57-60`):
  - `current` (string | null): имя активной папки кода (`lab/exe/CodeSlots.cs:36, 58`).
  - `lastGood` (string | null): имя последней проверенной версии (`lab/exe/CodeSlots.cs:36, 58`).
  - `embeddedSeen` (string | null): версия встроенного кода EXE при первом запуске (`lab/exe/CodeSlots.cs:36, 58`).
  - `failsGood` (int, 0..1000): число последовательных падений проверенной версии (`lab/exe/CodeSlots.cs:38, 53, 58`).
  - `memRestarts` (int, 0..1000): число последовательных перезапусков по памяти (`lab/exe/CodeSlots.cs:38, 53, 59`).
  - `rollbackReason` (string | null): строка причины отката на английском ASCII (`lab/exe/CodeSlots.cs:37, 59, 101-102`).
- **Файл ожидания новой версии**: `<Home>\code\pending.json` (`lab/exe/CodeSlots.cs:26`, `lab/ralab/updater.py:75-77`). Содержит JSON `{"dir": "<name>"}`. Читается и сразу удаляется сторожем при выходе с кодом 3 (`lab/exe/CodeSlots.cs:75-79`).
- **Именование версий**: regex `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` (`lab/exe/CodeSlots.cs:20, 116`).
- **Точка входа скрипта**: `<Home>\code\<name>\run_lab.py` (`lab/exe/CodeSlots.cs:28-29`).

### 1.2 Константы и пороги
- `MaxFailsGood = 3`: лимит падений проверенной версии до перехода в `Stop` (`lab/exe/CodeSlots.cs:21, 108`).
- `MaxMemRestarts = 3`: лимит перезапусков по памяти до перехода в `Stop` (`lab/exe/CodeSlots.cs:21, 97`).
- `LongRunSeconds = 600.0`: время непрерывной работы после `good`, сбрасывающее `failsGood = 0` (`lab/exe/CodeSlots.cs:22, 106`).
- `PythonSilenceFuseSeconds = 120`: таймер В; предельное время ожидания сигнала `good` до принудительного `Terminate()` (`lab/exe/LabMain.cs:116, 139-145`).
- `RestartGraceSeconds = 45`: ожидание мягкого выхода Python при перезапуске (`lab/exe/LabMain.cs:114, 484`).
- `FinalExitGraceSeconds = 80`: ожидание мягкого выхода и очистки при полном закрытии (`lab/exe/LabMain.cs:115, 484`).

### 1.3 Сигнал Good и проверка версии
- Строка от Python в stdout: `{"t":"good","version":"<str>"}` (`lab/exe/LabMain.cs:20, 423-428`, `lab/ralab/link.py:4`).
- При получении `good`: сторож останавливает таймер В (`lab/exe/LabMain.cs:424`), вызывает `Slots.MarkGood()`: `lastGood = Current`, `failsGood = 0`, `memRestarts = 0`, `rollbackReason = null`, сохраняет `state.json` (`lab/exe/CodeSlots.cs:68`, `lab/exe/LabMain.cs:427`).

### 1.4 Реакция на завершение процесса (OnExit)
- **Запуск Python**: аргументы `-X utf8 -u "<ScriptPath>" --home "<Home>" --exe-version "<Version>" [--rollback-reason "<Reason>"]` (`lab/exe/LabMain.cs:253-254`). Переменные окружения: `RA_EXE`, `RA_EXE_VERSION`; удаляются `PYTHONPATH`, `PYTHONHOME` (`lab/exe/LabMain.cs:260-261`).
- **Запрос перезапуска из трея (`requested`)**: `SlotAction.Restart` (`lab/exe/CodeSlots.cs:88`).
- **Код выхода 3**:
  - Если в `pending.json` валидная папка и `next != Current`: `Current = next`, `failsGood = 0`, `memRestarts = 0`, `SlotAction.Restart` (`lab/exe/CodeSlots.cs:89-91`).
  - Если непроверенная версия перезапускает себя без нового кода (`!Unverified` ложно): считается падением (`lab/exe/CodeSlots.cs:92-93`).
  - Для проверенной версии без новой папки: перезапуск `SlotAction.Restart` (`lab/exe/CodeSlots.cs:93`).
- **Код выхода 4 (память)**: `memRestarts++`; если `> 3` -> `SlotAction.Stop`, иначе `SlotAction.Restart` (`lab/exe/CodeSlots.cs:95-98`).
- **Таймер В (120 с без good) или падение (код != 0/3/4, либо неожиданный код 0)**:
  - Формирование англоязычной причины `whyEn`: `"version <ver> did not bring the channel up in 120 s"`, `"version <ver> exited with code 0 unrequested"`, или `"version <ver> crashed, exit code <code>"` (`lab/exe/CodeSlots.cs:100-102`).
  - Для непроверенной версии (`Current != LastGood`):
    - При наличии `lastGood`: `Current = lastGood`, `rollbackReason = whyEn`, сброс счетчиков, `SlotAction.Restart` (`lab/exe/CodeSlots.cs:104`).
    - Иначе при наличии `embedded`: `Current = embedded`, `rollbackReason = whyEn`, сброс счетчиков, `SlotAction.Restart` (`lab/exe/CodeSlots.cs:105`).
  - Для проверенной версии: `failsGood++`; если `>= 3` -> `SlotAction.Stop`, иначе `SlotAction.Restart` (`lab/exe/CodeSlots.cs:107-109`).

---

## 2. Протокол доставки кода (ra-lab push -> /code)

### 2.1 Клиентская отправка (ra-lab push)
- Упаковка в zip (deflated): `run_lab.py`, все `ralab/**/*.py` (сортированные), `code-version.txt` (`<git-short-sha>[-dirty]\n`) (`lab/server/ra_lab.py:471-475`).
- HTTP-запрос:
  - Метод: `POST /code` (`lab/server/ra_lab.py:481`, `lab/ralab/agent.py:298`).
  - Заголовки: `Content-Type: application/zip`, `X-Sha256: <hex sha256 zip>` (`lab/server/ra_lab.py:481`).
  - Тело: бинарный zip (`lab/server/ra_lab.py:481`).
- Опция `--wait` / `-w`: ожидает сообщение о подъёме канала новой версии до `--deadline` (секунды) (`lab/server/ra_lab.py:479-494`).

### 2.2 Валидация и распаковка на агенте
- **Ограничения архива** (`lab/ralab/updater.py:13, 43-44`):
  - `FILES_MAX = 500`: максимум 500 файлов в zip.
  - `FILE_MAX = 1 МБ` (1 048 576 байт): максимальный размер одного файла.
  - `TOTAL_MAX = 20 МБ` (20 971 520 байт): суммарный размер распакованных файлов.
  - Предел тела запроса агента: 5 МБ для `/code` (`lab/ralab/agent.py:5`).
- **Проверка путей в zip** (`lab/ralab/updater.py:14, 48-50`):
  - Регулярное выражение: `^(run_lab\.py|code-version\.txt|ralab/[A-Za-z0-9_./-]*\.py)$`.
  - Запрещены: начальный `/`, символ `\`, `:`, сегмент `..`.
  - Обязательно наличие `run_lab.py` в корне (`lab/ralab/updater.py:52-53`).
- **Синтаксическая проверка**: каждый `.py` компилируется `compile(b, n, 'exec')` без сохранения `.pyc` (`lab/ralab/updater.py:54-60`).
- **Ответ при ошибке**: HTTP `422 Unprocessable Entity`, JSON `{"ok": false, "errors": ["<file>:<line>: <msg>", ...]}` (до 20 ошибок) (`lab/ralab/updater.py:32-34, 59`, `lab/ralab/agent.py:300-301`).
- **Успешная установка**:
  - Имя папки: `c-<12 hex символов sha256 zip>` (`lab/ralab/updater.py:62`).
  - Атомарная запись: распаковка в `<Home>\code\<name>.tmp` -> rename в `<Home>\code\<name>` (`lab/ralab/updater.py:63-74`).
  - Запись `<Home>\code\pending.json.tmp` -> rename в `<Home>\code\pending.json` с содержимым `{"dir": "<name>"}` (`lab/ralab/updater.py:75-77`).
  - Очистка старых версий (`_prune`): хранятся не более `DIRS_MAX = 5` папок `c-*`; папки из `state.json`, текущая версия и новая версия защищены от удаления (`lab/ralab/updater.py:13, 84-101`).
  - Ответ: HTTP `200 OK`, JSON `{"ok": true, "dir": "<name>", "files": <int>}` (`lab/ralab/updater.py:82`, `lab/ralab/agent.py:302`).
  - После ответа: публикация события `app.restart` -> выход Python с кодом 3 (`lab/ralab/agent.py:302`, `lab/ralab/app.py:156`).

---

## 3. Обновление и откат EXE-файла

### 3.1 Взаимодействие процессов при обновлении EXE
- **Команды stdin (EXE -> Python)**:
  - `{"t":"update"}`: запуск проверки и скачивания обновления EXE (`lab/exe/LabMain.cs:513`, `lab/ralab/link.py:9, 55-56`).
  - `{"t":"rollback"}`: запрос отката EXE (`lab/ralab/link.py:9, 57-58`).
- **Сообщения stdout (Python -> EXE)**:
  - `{"t":"update-progress","text":"<str <= 24>"}`: прогресс (`Скачиваю...`, `Проверяю...`, `Устанавливаю...`) (`lab/ralab/update.py:104, 156, 169, 174`, `lab/exe/LabMain.cs:437-447`).
  - `{"t":"notice","text":"<str <= 200>"}`: уведомление для трея (`lab/ralab/update.py:100`, `lab/exe/LabMain.cs:430-435`).
  - `{"t":"restart-exe"}`: сигнал готовности к перезапуску EXE (`lab/ralab/update.py:189, 219`, `lab/exe/LabMain.cs:449-456`).
- **Блокировка интерфейса**: при старте обновления выставляется `updateLockUntil = UtcNow + 120 с`, продлевается при каждом `update-progress` (`lab/exe/LabMain.cs:444, 505, 509, 513`).

### 3.2 Скачивание и валидация релиза (`update.py`)
- URL релиза: `https://api.github.com/repos/jeromwork/AiServerAutoSettings/releases/tags/lab-latest` (`lab/ralab/update.py:9`). Тайм-аут запросов: 30 с (`lab/ralab/update.py:37, 62`).
- Формат тела релиза: `Последняя версия: (V[0-9.]+).*?SHA-256 ([0-9a-f]{64})` (`lab/ralab/update.py:10`).
- Имя ассета: `RemoteAgents-Lab-<version>.exe` (`lab/ralab/update.py:43`).
- Ограничения: размер <= 400 МБ (`MAX_SIZE = 400 * 1024 * 1024`), URL строго с `https://github.com/` (`lab/ralab/update.py:11, 51-54`).
- Сверка контрольной суммы: SHA-256 файла должен совпасть с SHA-256 из описания релиза (`lab/ralab/update.py:47-49, 170-172`).

### 3.3 Ротация файлов EXE
- **Имена путей**: `<exe>`, `<base>.prev.exe`, `<base>.new`, `<base>.tmp` (`lab/ralab/update.py:88-89`, `lab/exe/LabMain.cs:521, 537`).
- **Установка нового EXE из Python (`update.py:175-189`)**:
  1. `_rm(prev)`
  2. `os.replace(exe, prev)`
  3. `os.replace(new, exe)` (при сбое — попытка вернуть `prev` в `exe`).
  4. Отправка `{"t":"restart-exe"}` в stdout.
- **Откат EXE из GUI сторожа (`LabMain.cs:523-558`)**:
  - Проверка существования `<base>.prev.exe` (`lab/exe/LabMain.cs:528`).
  - Вызов `RequestExit(false)` с таймаутом `RestartGraceSeconds = 45 с` для завершения Python (`lab/exe/LabMain.cs:514-533`).
  - Замена файлов после завершения Python (`DoRollbackFiles`, `lab/exe/LabMain.cs:535-558`):
    1. `Move(exe, tmp)`
    2. `Move(prev, exe)`
    3. `Move(tmp, prev)`
  - При ошибке на шаге 1 или 2: откат перемещений (`lab/exe/LabMain.cs:553-556`).
- **Перезапуск сторожа**: на `{"t":"restart-exe"}` сторож устанавливает `RestartExeRequested = true`, закрывает форму, освобождает мьютекс `Local\RemoteAgents-Lab` и запускает обновленный EXE (`lab/exe/LabMain.cs:29-32, 47-50, 449-456`).
