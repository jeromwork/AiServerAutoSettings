# Контракт v2: Очистка системы и управление процессами (cleanup)

- **Базовый SHA**: `80f1d0a0d4b99eee088254d5ede152c5e5d542dc`
- **Источники**:
  - `lab/ralab/cleanup.py`
  - `lab/ralab/app.py`:143–181
  - `lab/ralab/procs.py`
  - `lab/exe/LabJob.cs`

## 1. Режимы вызова и тайм-ауты

| Режим | Функция / Точка вызова | Общий лимит | Лимит подпроцесса | Поведение |
|---|---|---|---|---|
| `startup` | `cleanup.run('startup', home, log)` (`cleanup.py:409–414`, `app.py:144–147`) | 59 с (`cleanup.py:42`) | min(20 с, остаток − 1 с) (`cleanup.py:53`) | Очистка хвостов прошлого запуска перед подъёмом сети. Реестр не чистится (`cleanup.py:401`). |
| `exit` | `cleanup.run('exit', home, log)` (`cleanup.py:409–414`, `app.py:171–181`) | 28 с (`cleanup.py:42`) | min(20 с, остаток − 1 с) (`cleanup.py:53`) | Запускается только при `exit_code == 0` и `final == true` (`app.py:171`) в потоке-демоне с `join(30)` (`app.py:177–181`). Включает чистку реестра (`cleanup.py:401–402`). |
| `check` (dry-run) | `cleanup.check(home)` (`cleanup.py:416–418`) | 28 с (`cleanup.py:42`) | min(20 с, остаток − 1 с) (`cleanup.py:53`) | `reading=True`, ничего не удаляет, собирает список проблем (`cleanup.py:418`). |

- Платформа: только Windows (`os.name == 'nt'`); на других ОС возвращается `['Уборка системы доступна только в Windows']` (`cleanup.py:395–396`).
- Ошибка тайм-аута: `TimeoutError('Время уборки истекло')` (`cleanup.py:48, 55`).
- При зависании внешней команды: `taskkill.exe /F /T /PID <pid>` (тайм-аут min(0.5 с, остаток)), затем `kill()` (тайм-аут min(0.25 с, остаток)) (`cleanup.py:60–72`).
- Остановка TUN перед `kill_all`: `ctx.tun.stop().join(timeout=40)` (`app.py:169`).

## 2. Порядок шагов уборки (`cleanup.py:398–406`)

1. **Процессы (`cleanup.py:129–155`):**
   - Критерии принадлежности процесса (`cleanup.py:107–123`): `ProcessId != os.getpid()`, `ProcessId != $PID`, `ProcessId != ppid` (если `ppid > 0`), `ExecutablePath.StartsWith(<home>\)` (регистронезависимо), `ExecutablePath != RA_EXE`.
   - Действие: `Stop-Process -Id <id> -Force` (`cleanup.py:131–135`).
   - Контроль: если процессы остались — замечание `'Процессы: остались запущенные программы из папки данных'` (`cleanup.py:137, 154`).
2. **Откат изменений (`cleanup.py:363–392`):**
   - Каталог: `<home>/undo` (`cleanup.py:364`). Пропуск, если папка или файл — симлинк/junction (`cleanup.py:365, 375`).
   - Файлы: `*.cmd`, сортировка по времени модификации `st_mtime_ns` от новых к старым (`cleanup.py:374–379`).
   - Вызов: `%ComSpec% /D /S /V:OFF /C ""%RA_UNDO_FILE%""` с `env['RA_UNDO_FILE'] = str(path)` (`cleanup.py:384–386`).
   - При успехе файл удаляется (`path.unlink()`), при ошибке остаётся на следующий запуск (`cleanup.py:387`).
3. **Сетевые адаптеры (`cleanup.py:160–178`):**
   - Проверка активности сети (`cleanup.py:156–159`): если процесс из `<home>` с именем `^(sing-box.*|ralab-core|RA2-VPN)\.exe$` жив, шаг пропускается с пометкой `'Адаптеры: удаление пропущено, сетевой процесс ещё работает'` (`cleanup.py:163`).
   - Фильтр адаптеров WQL/PowerShell (`cleanup.py:17–22`): `sing-tun Tunnel` или `Wintun Userspace Tunnel` с именами `RA2-LAN*`, `RA2-VPN*`, `RemoteAgents-Lab*`, `ralab-tun*`, `ralab-vpn*`.
   - Если статус адаптера `Up` — удаление пропускается (`cleanup.py:170–172`).
   - Удаление: `pnputil.exe /remove-device <PnPDeviceID>`, допустимые коды выхода `0, 3010` (`cleanup.py:176–177`).
4. **Правила DNS NRPT (`cleanup.py:179–187`):**
   - Запрос: `Get-DnsClientNrptRule | Where-Object { $_.Comment -like 'RemoteAgents-Lab*' }` (`cleanup.py:23`).
   - Удаление: `Remove-DnsClientNrptRule -Name $_.Name -Force` (`cleanup.py:184–186`).
5. **Файл hosts (`cleanup.py:188–220`):**
   - Путь: `%SystemRoot%\System32\drivers\etc\hosts` (`cleanup.py:189`).
   - Определение BOM: UTF-8 (`\xef\xbb\xbf`), UTF-16LE (`\xff\xfe`), UTF-16BE (`\xfe\xff`), по умолчанию `latin-1` (`cleanup.py:191–195`).
   - Удаление блока регулярным выражением (`cleanup.py:28–29, 199`):
     `(?m)^#[ \t]*(RemoteAgents-Lab[^\r\n]*?)[ \t]+begin[ \t]*\r?\n[\s\S]*?^#[ \t]*\1[ \t]+end[^\r\n]*(?:\r?\n|$)`
   - Контроль: незакрытый маркер `_BEGIN` (`cleanup.py:27, 204–205`).
   - Атомарная перезапись: временный файл `RemoteAgents-Lab-*.tmp` в той же папке, `fsync`, затем `os.replace` (`cleanup.py:209–216`).
6. **Настройки системного прокси (`cleanup.py:221–261`):**
   - Маркер: `<home>/state/proxy-set.json` (`cleanup.py:222`).
   - Раздел реестра: `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings` (`cleanup.py:25`).
   - Разрешённые имена параметров: `ProxyEnable`, `ProxyServer`, `ProxyOverride`, `AutoConfigURL`, `AutoDetect` (`cleanup.py:26, 231`).
   - Типы реестра: `REG_DWORD` для `int` (0..0xffffffff), `REG_SZ` / `REG_EXPAND_SZ` для `str` (`cleanup.py:239–241`).
   - Значение `null` / `None`: удаление параметра через `DeleteValue` (`cleanup.py:3, 247–251`).
   - Оповещение WinINet: P/Invoke `wininet.dll!InternetSetOption` с опциями `39` (`INTERNET_OPTION_SETTINGS_CHANGED`) и `37` (`INTERNET_OPTION_REFRESH`) (`cleanup.py:255–259`).
   - Маркер удаляется только после успешного восстановления параметров (`cleanup.py:5, 260`).
7. **Запланированные задачи (`cleanup.py:262–270`):**
   - Выборка: `Get-ScheduledTask | Where-Object { $_.TaskName -like 'RemoteAgents-Lab*' }` (`cleanup.py:24`).
   - Удаление: `Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false` (`cleanup.py:267–269`).
8. **Реестр Windows (`cleanup.py:271–292`):**
   - Выполняется при `reading=True` или `mode == 'exit'` (`cleanup.py:401`).
   - Контекстное меню проводника: удаление ключей `HKCU:\Software\Classes\Directory\shell\RemoteAgents.LabDisk.*` (`cleanup.py:280–284`).
   - Автозапуск: удаление значения `'RemoteAgents-Lab'` в `HKCU:\Software\Microsoft\Windows\CurrentVersion\Run` (`cleanup.py:285–289`).
9. **Временные файлы и ярлыки (`cleanup.py:330–362`):**
   - Внутри `<home>`: удаление файлов с суффиксами `.ralab-part` и `.ralab-tmp` (`cleanup.py:331–333`).
   - Каталоги временных файлов: `%TEMP%` / `%TMP%` (только элементы с префиксом `ralab*`) и `<home>/tmp` (все элементы) (`cleanup.py:334–355`).
   - Ярлык остановки на рабочем столе: `[Environment]::GetFolderPath('DesktopDirectory')\RemoteAgents-Lab СТОП.cmd` (`cleanup.py:356–361`).
   - Защита от удаления чужого: папки-симлинки и directory junctions не обходятся рекурсивно (`cleanup.py:299, 312–314, 340–344`); junction удаляется через `rmdir`, symlink через `unlink` (`cleanup.py:314`).

## 3. Формат файла состояния прокси (`cleanup.py:3–5, 228–243`)

Файл: `<home>/state/proxy-set.json` (кодировка UTF-8 с BOM или без, `cleanup.py:229`).

Допустимые структуры JSON:
1. Прямой словарь ключ-значение: `{"ProxyEnable": 0, "ProxyServer": null}`.
2. Вложенный словарь values: `{"values": {"ProxyEnable": 0, "ProxyServer": null}}`.
3. Запись с явным типом: `{"ProxyServer": {"value": "127.0.0.1:8080", "type": 1}}`.

Правила значений:
- `null`: параметр отсутствовал до запуска, при откате удаляется (`cleanup.py:3, 247–251`).
- `int` (0..4294967295): тип `REG_DWORD` (код 4) (`cleanup.py:239–240`).
- `str`: тип `REG_SZ` (код 1) или `REG_EXPAND_SZ` (код 2) (`cleanup.py:239–241`).

## 4. Завершение процессов и Job Objects

### Python Job Object (`lab/ralab/procs.py`)
- Инициализация: `CreateJobObjectW(None, None)` (`procs.py:41`).
- Ограничения: `SetInformationJobObject` с классом 9 (`JobObjectExtendedLimitInformation`) и флагом `LimitFlags = 0x2000` (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`) (`procs.py:43–44`).
- Привязка: `AssignProcessToJobObject(job, popen._handle)` для каждого дочернего процесса сразу после `Popen` (`procs.py:51–56, 195`).
- Лимиты пула: максимум одновременно работающих процессов `MAX_PROCS = 64` (`procs.py:13, 184`).

### EXE C# Job Object (`lab/exe/LabJob.cs`)
- Создание: `CreateJobObject(IntPtr.Zero, null)` (`LabJob.cs:18`).
- Флаг: `limits.Basic.LimitFlags = 0x2000` (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`) через `SetInformationJobObject` (`LabJob.cs:20–21`).
- Привязка: `AssignProcessToJobObject(handle, process.Handle)` сразу после запуска процесса Python (`LabJob.cs:25–29`).
- Завершение: `TerminateJobObject(handle, 1)` при остановке или сбросе (`LabJob.cs:34, 39`).

### Процедура завершения (`procs.py:133–175`)
- Потоки и читатели: stdout/stderr читаются порциями по 64 КБ до `LINE_MAX = 8192` байт (`procs.py:13, 79, 92–94`).
- Мягкая остановка (`graceful=True`):
  - Тайм-аут: 3 с (`procs.py:136`).
  - Windows: отдельный процесс Python подключается через `AttachConsole(pid)`, вызывает `SetConsoleCtrlHandler(None, True)` и генерирует `GenerateConsoleCtrlEvent(1, pid)` (`CTRL_BREAK_EVENT`) с лимитом 2 с (`procs.py:139–146`).
  - POSIX: `os.killpg(pid, signal.SIGTERM)` (`procs.py:148`).
- Принудительная остановка (`kill`):
  - Windows: `taskkill.exe /F /T /PID <pid>` (тайм-аут 2 с при graceful) (`procs.py:165–166`).
  - POSIX: `os.killpg(pid, signal.SIGKILL)` (`procs.py:168`).
  - Гарантированный финальный вызов `popen.kill()` (`procs.py:172`).
- Полная остановка: `kill_all()` завершает все зарегистрированные процессы в словаре `_procs` (`procs.py:214–216`).

## 5. Диагностические сообщения и журнал

- Предупреждения `_Cleanup.note()` формируют итоговый список `issues` (`cleanup.py:96–104`):
  - `'Процессы: остались запущенные программы из папки данных'` (`cleanup.py:137, 154`)
  - `'Адаптеры: удаление пропущено, сетевой процесс ещё работает'` (`cleanup.py:163`)
  - `'Адаптеры: <name> в состоянии Up, удаление пропущено'` (`cleanup.py:171`)
  - `'Адаптеры: осталось устройство программы'` (`cleanup.py:174`)
  - `'DNS: остались правила программы'` (`cleanup.py:182`)
  - `'Имена компьютеров: остались записи программы'` (`cleanup.py:202`)
  - `'Имена компьютеров: найден незакрытый блок, требуется проверка'` (`cleanup.py:205`)
  - `'Прокси: осталось сохранённое изменение настроек'` (`cleanup.py:226`)
  - `'Автозапуск: остались прежние задачи программы'` (`cleanup.py:265`)
  - `'Реестр: осталась запись автозапуска'` (`cleanup.py:278`)
  - `'Файлы: остался временный файл или файл отката'` (`cleanup.py:326, 389`)
  - `'Временные файлы: папка является ссылкой, обход пропущен'` (`cleanup.py:343`)
  - `'Откат изменений: папка является ссылкой, обход пропущен'` (`cleanup.py:366`)
  - `'Откат изменений: файл является ссылкой, запуск пропущен'` (`cleanup.py:376`)
- Записи в журнал при сбоях в `app.py`:
  - `journal.log('app', 'cleanup', {'trace': ...}, 'уборка при старте не удалась')` (`app.py:147`)
  - `journal.log('app', 'cleanup', {'trace': ...}, 'уборка при выходе не удалась')` (`app.py:176`)
  - `journal.log('app', 'cleanup', {}, 'уборка при выходе не успела за 30 с')` (`app.py:181`)
