# Облако и удаление прежнего Диска: отчёт app/cloud-app

Дата: 13.11.2026. Основа: `0a3d3a8`. Windows EXE не собирался, публикации и push не выполнялись.

## Статус стыковки

Стыковка после объединения серверной ветки реализована: загрузка удалённых помощников убрана, доставка облака и настоящий контракт apply проверены. Текущие изменения и результаты прогонов — в разделе «Стыковка» в конце документа. Остальные разделы сохраняют историю предыдущего этапа; прежний запрет менять `Send-WizardHelpers` снят владельцем в новой задаче.

## Что удалено

До добавления этого отчёта diff относительно основы: 132 пути, +1266 / −9461 строк (с учётом схем, тестов, документации и переносов общих функций). Полностью убран каталог `disk/`: в исходной версии 27 файлов, 3222 строки. Полный список удалённых путей ниже; переносы `AccountDiskSetup` и `Disk.Binary.ps1` отражены отдельно в следующем разделе.

- Убраны компоненты Syncthing/Syncthing Tray из бандла, фоновые запуск/надзор и опросы дерева. Старые бандлы при чтении фильтруют компонент `disk`, поэтому rollback бандла не возвращает его в Supervisor новой программы.
- Удалены вкладка и шаг выбора папок, дерево, выбор направлений/внешних папок, фоновые очереди применения, окно прогресса, интеграция с Проводником и команды `--disk-shell`.
- Удалены Disk-действия мастера и серверные операции установки Syncthing. Из серверной выдачи конфигов удалён `--folders` и генерация `disk`.
- Удалены тесты удалённой реализации; общие тесты мастера, конфига, обновлений, Happier и сетевых настроек сохранены и адаптированы к отсутствующему шагу.

- `04-disk.cmd`
- `app/launcher/DiskChoice.cs`
- `app/launcher/DiskEvictionSafety.cs`
- `app/launcher/DiskExplorerController.cs`
- `app/launcher/DiskExplorerMetadata.cs`
- `app/launcher/DiskExplorerNative.cs`
- `app/launcher/DiskExplorerObservation.cs`
- `app/launcher/DiskExplorerPresentation.cs`
- `app/launcher/DiskExplorerRegistry.cs`
- `app/launcher/DiskFolderTree.cs`
- `app/launcher/DiskFoldersModel.cs`
- `app/launcher/DiskFoldersView.cs`
- `app/launcher/DiskProgressWindow.cs`
- `app/launcher/DiskShellCommands.cs`
- `app/launcher/DiskShellModel.cs`
- `app/launcher/DiskSyncMonitor.cs`
- `app/launcher/DiskSyncStatus.cs`
- `app/launcher/DiskTreeSelection.cs`
- `app/launcher/LocalFolderBrowser.cs`
- `app/launcher/LocalFolders.cs`
- `app/launcher/tests/DiskChoiceTests.cs`
- `app/launcher/tests/DiskExplorerMetadataTests.cs`
- `app/launcher/tests/DiskFoldersModelTests.cs`
- `app/launcher/tests/DiskShellTests.cs`
- `app/launcher/tests/DiskTreeTests.cs`
- `app/launcher/tests/LocalFoldersTests.cs`
- `app/launcher/tests/test-disk-errors.ps1`
- `app/launcher/tests/test-folders-ui.ps1`
- `app/launcher/tests/test-navpane.ps1`
- `app/launcher/tests/test-selective.ps1`
- `disk/Add-RemoteDiskFolder.ps1`
- `disk/Disk.Common.ps1`
- `disk/Disk.Engine.ps1`
- `disk/Disk.Explorer.ps1`
- `disk/Disk.NavPane.ps1`
- `disk/Disk.Selective.ps1`
- `disk/Disk.Status.ps1`
- `disk/Disk.Union.ps1`
- `disk/Ensure-DiskExplorerIgnores.ps1`
- `disk/Install-RemoteDisk.ps1`
- `disk/Move-RemoteDiskFolder.ps1`
- `disk/README.md`
- `disk/Remove-DiskExplorer.ps1`
- `disk/Select-Disk.ps1`
- `disk/Sync-RemoteDiskFolders.ps1`
- `disk/server-disk.sh`
- `disk/stignore-previous.sha256`
- `disk/stignore.txt`
- `disk/test-choice.ps1`
- `disk/test-disk.py`
- `disk/test-explorer.ps1`
- `disk/test-ignore-history.py`
- `disk/test-install.ps1`
- `disk/test-selective.py`
- `disk/test-tree.py`
- `disk/test-wizard-merge.py`

## Что осталось и почему

- `AccountSecrets.cs`: прежние защита каталога секретов ACL и сохранение/резервирование ключа Happier. Они нужны аккаунту и proxyOut, синхронизации в них не было.
- `build/Process.Common.ps1`: общие запись UTF-8, quoting, запуск процесса и SSH-профиль/вызов, которыми пользуются мастер и Happier. Старые имена функций `Invoke-DiskProcess`, `Read-DiskProfile`, `Invoke-DiskSsh`, `Quote-Disk`, `Write-DiskUtf8` сохранены ради совместимости используемых интерфейсов. Функций API/дерева/выбора/состояния Syncthing здесь нет. `accounts/Account.ps1` меняет только импорт общей библиотеки и убирает ненужную переменную RemoteDisk.
- `build/Install.Binary.ps1`: общий установщик проверенного SHA-256 ZIP, который по-прежнему нужен sing-box. Загрузок Syncthing больше нет.
- `build/server-channel.py`: прежний экспорт VLESS-канала перенесён из удалённого server-disk.sh без логики Syncthing. Сохранена совместимость переменной `REMOTE_DISK_CHANNEL_SOURCE`, добавлено нейтральное имя `REMOTEAGENTS_CHANNEL_SOURCE`. Новые каналы не получают sync inbound.
- Named pipe оставлен для повторного запуска, `--identify`, выхода, настроек и прочих команд программы; пересылки команд Проводника больше нет.
- Значения `disk` в свежих метриках свободного места сервера относятся к файловой системе сервера. Это не компонент Диска.
- Исторические CONFIG-REPORT*.md помечены как отчёты прежней версии. Корневые утилиты синхронизации, обслуживающие прежние сценарии моста/транспорта, не переписаны: изменение моста и транспорта запрещено задачей. В `transport/`, VPN и реализации Happier изменений нет; UI-индексы их страниц сдвинуты после удаления страницы Диска.

## Миграция

`LegacyDiskMigration.cs` — 222 строки, включая подменяемый интерфейс и тонкий Windows-адаптер. Запуск перед созданием трея; маркер `state/legacy-disk-removed-v1` записывается только после успешной очистки. При ошибке маркер не появляется, повторный запуск повторяет идемпотентные действия. `Uninstall.Run` вызывает ту же миграцию принудительно, в том числе без активного бандла.

- Процессы проверяются по точному пути нашего EXE; встроенный режим Syncthing дополнительно требует точный `--home ...\RemoteDisk\state`. Перед остановкой повторно проверяются executable/CreationDate. Сначала останавливается GUI, потом встроенный serve.
- Run-значения и ярлыки удаляются только при совпадении цели с нашим Syncthing/Syncthing Tray; чужие установки остаются.
- Меню Проводника требует одновременно префикс `RemoteAgents.Disk.*` и `RemoteAgentsOwner=RemoteAgents.Disk.v1`. Удаляется только фиксированный продуктовый CLSID панели навигации, обе его копии и связанное скрытие значка рабочего стола.
- `desktop.ini` удаляется только с `[RemoteAgents]`, `Owner=RemoteAgents.Disk.v1` и допустимым `OriginalReadOnly=0|1`. Атрибут папки восстанавливается; неизвестные метаданные сохраняются. Reparse-папки и их предки не обходятся.
- Junction удаляется нерекурсивно и только по `external.json`: прежний корень + remote, записанный путь junction и текущая цель должны совпасть. Заменённые пользователем ссылки остаются; цель и её файлы не удаляются.
- Из RemoteDisk удаляются только известные служебные каталоги/файлы и журналы; неизвестные файлы сохраняются. Иконки удаляются только по продуктовому префиксу. В конце вызывается SHChangeNotify.
- Содержимое `%USERPROFILE%\Disk`, файлов внешних папок и папки официального облака не удаляется. Реестр/ФС/процессы/COM Win32-адаптера ещё требуют проверки на настоящей Windows.

## Конфиг и применение

`cloud` — объект или непустой массив из 1–32 объектов по приоритету. Используется только первый. Поля: `vendor:"mailru"`, `login`, ссылка `password`; `remoteRoot` по умолчанию `Disk`, `pollSeconds` по умолчанию 20, диапазон 1–86400. `cloud-password` работает через обычный vault, `secret set`, экспорт с мастер-паролем; пароль не материализуется отдельным файлом. При отсутствии cloud шаг не включается в план.

Старые `disk` и `components.disk` удаляются до проверки вставленного конфига; сохранение даёт одну строку `config.disk.ignored`. Старые статусы/очереди серверной установки disk также больше не опрашиваются. Публичные схемы и примеры описывают cloud; legacy disk принимает именно совместимый парсер приложения.

`CloudApply` — отдельный шаг применения, ожидающий Server/Connection. Одноразовый `PasswordRelay` передаёт сериализованный JSON хелперу, запросный файл содержит только имя pipe. Хелпер запускает фиксированную команду `bash "$HOME/.local/share/remoteagents-cloud/server-cloud.sh" apply` и пишет JSON `{vendor,login,password,remoteRoot,localRoot:"~/Disk",pollSeconds}` только на stdin SSH. Облачный вызов не использует трассировку общего исполнителя. Сырые stdout/stderr не сохраняются: наружу выходят нормализованный boolean-ответ и первая строка stderr с маскированием пароля. C# дополнительно проверяет код 0 и настоящий boolean `ok:true`. Таймауты/отмена/невалидный ответ не считаются успехом.

`cloud.localFolder` — настройка этого устройства в локальном config.json, отдельно от переносимого профиля. Константа `CloudSettings.MailFolder` задаёт `%USERPROFILE%\Облако Mail`. Трей проверяет наличие папки и при отсутствии показывает ссылку на официальный клиент и указание на localFolder; установка и состояние официального клиента не выдаются за проверенную синхронизацию.

## Трей и название процесса

Порядок модели: `Открыть` (Happier), `Настройки`, `Диск` (папка облака), разделитель, связь, сервер, `Выход`. Левый клик открывает Happier; если URL отсутствует, даёт объяснение про happier.webappUrl. Строк Диска, выбора папок и прогресса нет. AssemblyTitle/Product/Description получают ProductName: обычный EXE имеет RemoteAgents, соседний RemoteVPN сохраняет своё имя.

На временной net48 DLL проверены ресурсы без сборки EXE:

```text
Build succeeded. 0 Error(s)
FileDescription=RemoteAgents
ProductName=RemoteAgents
```

## Проверки

Исходная версия запущена через `SKIP_LAUNCHER_EXE=1 app/launcher/tests/run.sh` в отдельной копии `0a3d3a8`. Первый запуск пересёкся с удалением файлов и не считается baseline. Повтор в изолированной копии завершился кодом 1 с известным `PermissionError` `/var/lib/remoteagents/lan/pending`. Архивная копия сначала не имела .git, поэтому packaging-проверка git check-ignore дала 128; после локального git init все 12 исходных packaging-тестов повторно прошли. Это отдельно учтённый артефакт изоляции, не исправление продукта.

Исходный suite останавливает следующие группы после ошибки. Новый run.sh сохраняет общий ненулевой код, но продолжает независимые проверки, поэтому известная ошибка сервера не скрывает C#-тесты. Запуск после изменений: `SKIP_LAUNCHER_EXE=1 app/launcher/tests/run.sh`.

Хотя в условии указано отсутствие PowerShell, обнаружен исполнимый `~/.cache/pwsh-test/pwsh`: PowerShell 7.6.9 на Linux. Доступные PS-тесты реально выполнялись. **Windows PowerShell 5.1 отсутствует и не проверен**; успешный PS7 не заменяет этот пункт.

Финальный полный прогон завершился **кодом 1**. Неисправленные причины:

| Проверка | Фактический результат |
|---|---|
| `server/tests/test_lan_vpn.py::test_timer_failure_prevents_network_mutation` | Известный `PermissionError: /var/lib/remoteagents/lan/pending`; сетевые файлы/права среды не менялись. |
| `transport/test-engine-loopback.py --without-disk` | `Send-WizardHelpers` пытается читать удалённый `disk/stignore.txt`. Тест транспорта не менялся. Отдельный повтор даёт ту же причину. |
| `test_wizard_boundary.py::test_two_computers_upload_without_sharing_staging_files` | Та же незавершённая стыковка загрузки хелперов; остальные три теста файла проходят. |
| `test_config_e2e.py` | Настройка Server проходит, Connection падает при чтении удалённого stignore-хелпера; Account честно блокируется отсутствием подтверждённой Connection. |

Эти три новых интеграционных отказа нельзя считать нестабильностью транспорта или зелёным результатом задачи. Их устраняет оговорённая правка резервированной функции и совместная интеграция серверного потока. Без этого приложение нельзя объявить готовым к развёртыванию.

Прошедшие проверки (выборка фактического вывода финального suite):

```text
PASS: 6 cloud PowerShell/SSH-stdin checks (Linux fake SSH; not Windows PowerShell 5.1)
OK: 15 setup/headless checks (fixtures)
OK: 27 account PowerShell checks (fake SSH; no live accounts)
OK: 84 wizard/model/catalog/rollback checks (fake SSH, no Windows)
OK: 89 onboarding/LAN checks (fake SSH, real keygen and isolated bash, no Windows)
OK: 42 Happier pending/detached checks (fake SSH; no live server)
OK: 34 proxy/LAN network checks (fake ssh/sudo/python, no root, no Windows)
PASS: config channel-first bootstrap/route/socks/honest-reason/retry: 93 assertions
PASS: 46 password-route checks (SSH/probes stubbed; no Windows)
OK: 44 resource lock/timing/CRLF checks; six-way overlap 964 ms
OK: 14 config scheduler retirement checks (Windows Task Scheduler adapters stubbed)
OK: 41 config sync/pins/key/rollback/CRLF checks
Ran 14 tests ... OK                 # UI wiring
Ran 3 tests ... OK                  # Happier UI
Ran 12 tests ... OK                 # packaging, обоих продуктов
Ran 5 tests ... OK                  # detached server operations
PASS: 65 window/routing/sync/status checks
PASS: 96 tray menu/server health/path/schedule checks
PASS: 52 cloud/config/stdin/migration checks
PASS: CONFIG: 131 assertions
SKIP: Windows launcher EXE build/publish (SKIP_LAUNCHER_EXE=1)
```

После последнего ужесточения проверки ownership отдельного Syncthing выполнены **последовательно**, с кодом 0, PortableTests для RemoteAgents и RemoteVPN, ConfigTests для обоих продуктов и повторная компиляция всех production C# в временную net48 DLL:

```text
PASS: 55 cloud/config/stdin/migration checks (fake executor, FS and registry; no real Windows)
PASS: 65 window/routing/sync/status checks
PASS: 96 tray menu/server health/path/schedule checks
OK: 104 config engine checks
PASS: CONFIG: 131 assertions
RemoteAgents: update selftests ok=true, count=108
RemoteVPN: update selftests ok=true, count=108
Build succeeded. 0 Error(s)          # net48 DLL, не Windows EXE
```

Отдельный требуемый повтор `transport/test-transport-daemon.py` прошёл: failover, pin/auto/hot reload/restart, занятые порты, backoff, Stop и ParentPid (имитаторы). Временные отказы по времени в итоговом прогоне не воспроизвелись. Loopback повторён отдельно и имеет именно указанный отказ загрузки удалённого файла.

Дополнительно: серверный `server/tests/test_config_export.py` прошёл (включая фактический вход sshd ключом из зашифрованного конфига и отказ после revoke); опубликованные runtime/paste-примеры прошли JSON Schema; PS parser проверил build/*.ps1; изменённые PS-файлы проверены как UTF-8 BOM/CRLF, bash/Python как LF; `git diff --check` чист. `transport/`, `cloud/` не изменены, Send-WizardHelpers совпадает с исходником после нормализации переводов строк.

Полные временные журналы этого сеанса: `/tmp/cloud-app-baseline.log`, `/tmp/cloud-baseline-build-retest.log`, `/tmp/cloud-app-final.log`, `/tmp/cloud-focused-{core,vpn,config,config-vpn}.log`, `/tmp/cloud-daemon-retest.log`, `/tmp/cloud-loopback-retest.log`, `/tmp/cloud-server-config-tests.log`, `/tmp/cloud-gui.log`. Проверки на имитаторах не заменяют реальную проверку облака и миграции на Windows.


## Проверить вручную на Windows 10

1. Обновить существующую установку с работающими нашим Tray и встроенным Syncthing. После запуска они остановлены, Run/ярлыки/наши пункты меню/CLSID/иконки сняты, marker записан. Повторить запуск и Uninstall. Проверить оба реестровых представления и обновление Проводника без перезапуска.
2. До обновления сохранить тестовые файлы в `%USERPROFILE%\Disk` и внешней папке. После миграции сравнить байты, проверить цели junction. Добавить чужую ссылку и чужие desktop.ini/пункты меню с похожими именами: они должны остаться.
3. Проверить OriginalReadOnly=0 и =1, скрытые desktop.ini, ошибку доступа/занятый процесс: маркер не появляется до успешной очистки, повтор завершается безопасно.
4. Проверить точный порядок трея, левый клик, Happier без URL, открытие настроек, закрытие окна в трей, повторный запуск и Выход. В окне нет выбора папок/прогресса.
5. Без официального клиента/папки «Диск» даёт объяснение; после установки клиента и входа открывает его настоящую папку. Уточнить у владельца фактическое стандартное имя каталога Mail; до уточнения используется согласованная константа. Проверить cloud.localFolder с пробелами/кириллицей.
6. После совместной интеграции серверного потока применить cloud с паролем приложения через окно/secret set. Проверить 0+ok:true, отказ сервера, отсутствие ответа, пропадание SSH и отмену. Пароль отсутствует в argv, setup/config-window/launcher журналах, временных запросах и экспорте для ИИ. Наблюдаемая передача файлов проверяется в официальном клиенте и серверной службе отдельно.
7. Повторить PS-тесты на Windows PowerShell 5.1: массивы ConvertFrom-Json, UTF-8/кириллица, CRLF stdin/ответы, один объект и приоритетный массив облаков. Вставить старый disk-конфиг, проверить отсутствие ошибки и единственную строку журнала.
8. Проверить имя/описание RemoteAgents в Диспетчере задач на релизном EXE после отдельной разрешённой сборки. Не изменять действующие транспорт, VPN, Happier и binding моста.

## Стыковка

13.11.2026, worktree `~/work/wt-cloud-app`, ветка `app/cloud-app`. Начало этого этапа — `f9ab646`: кроме объединения `c104fc7`, уже присутствовали исправление первой остановки отсутствующего unit и оптимизация первого bisync из `85ebf28`. Рабочее дерево перед правками было чистым. Продуктовые EXE не собирались; push, публикации и изменения компьютеров владельца не выполнялись.

### Доставка и контракт

- В `Send-WizardHelpers` удалены три прежних файла, `Get-DiskIgnoreUpload`, поле `versions`, ветвления накопительной истории и специальный пропуск загрузки шаблона. Остались обычный SHA-256 probe, проверка symlink и индивидуальные временные имена для параллельных установок.
- Доставляются `cloud/server-cloud.sh` и `cloud/filter.txt` в `$HOME/.local/share/remoteagents-cloud/`. **Дополнительно найден и исправлен дефект упаковки:** серверные файлы отсутствовали в `build/bundle-files.txt`, хотя функция доставки уже ссылалась на них. Оба обязательны в ZIP и проверяются packaging-тестом.
- Действие `Cloud` вызывает доставку перед `Invoke-WizardCloud`. Это обновляет helper и восстанавливает недостающий/изменённый файл также при отдельном повторе Cloud, независимо от того, какие секции конфига пропущены.
- У C# и PS одна команда: `bash "$HOME/.local/share/remoteagents-cloud/server-cloud.sh" apply`. JSON идёт только через SSH stdin: `{vendor,login,password,remoteRoot,localRoot,pollSeconds}`. `vendor=mailru`, серверный `localRoot=~/Disk`; пароль разрешается из vault, а не из argv/файла запроса.
- Настоящий shell сохраняет входной JSON на fd 3 и читает его внутри Python. Ответ сервера содержит boolean `ok:true` и дополнительные сведения о запуске службы; PS наружу возвращает нормализованный `{"ok":true}`. C# и PS требуют также код 0. Это подтверждение применения/старта, не обещание завершённого обмена файлами.
- `CloudTests.cs` сравнивает команду с независимым ожидаемым путём, проверяет все шесть полей, boolean-ответ и CRLF. Новый `test_wizard_upload_and_apply_contract` выполняет настоящий PowerShell и установленный shell-helper через локальную SSH-заглушку: CRLF-файлы/JSON, первичная доставка, пропуск неизменённого helper, восстановление фильтра, успешный apply и отказ неизвестному провайдеру. Подменены сеть SSH и systemctl; rclone/inotify — настоящие. Это не тест Windows PS 5.1 или аккаунта Mail.
- Проверка двух параллельных доставок теперь извлекает настоящий ZIP и запускает функции именно из него. Проверяются байты обоих облачных файлов, отсутствие старого служебного каталога и оставшихся `*.tmp`.

### Дефекты, обнаруженные полными прогонами

1. Loopback-тест транспорта после успешной загрузки вызывал удалённый `Set-WizardDiskChannel`. Это был воспроизводимый дефект тестовой стыковки, а не тайминговая нестабильность. Удалена подготовка прежнего Диска и его позднего inbound; вместо неё проверяются доставка cloud-helper/filter и отсутствие sync-входа. Проверки одного SSH-сеанса, параллельных команд, хэш-кэша и отбрасывания осиротевшего запроса сохранены.
2. Оптимизация `85ebf28` меняла `--compare size` первого прохода на `--compare size,modtime` последующих. Первый listing не содержал времён, второй проход падал с `Modtime not equal in listing`; воспроизведено также после перезапуска systemd. Исправлено: постоянное `--compare size,modtime`, при инициализации только `--resync`. Параллелизм 16 transfers/checkers сохранён. Попытка добавить `--size-only` лишь к первому проходу прошла обычный сценарий, но отдельный тест существующих файлов одинакового размера с разными mtime выявил ещё один отказ; этот вариант не оставлен. Защита `check-sync` не отключалась. Причина подтверждена [формированием listing в rclone 1.76.0](https://github.com/rclone/rclone/blob/v1.76.0/cmd/bisync/queue.go#L179) и [его финальной проверкой](https://github.com/rclone/rclone/blob/v1.76.0/cmd/bisync/resync.go#L149). Оптимизацию первой перезаливки Mail нельзя считать сохранённой; её нужно решать отдельно с реальным провайдером.
3. Из заголовка `cloud/filter.txt` убрана ссылка на удалённый шаблон. Для уже применённого конфига принимается также хэш с точным прежним заголовком и остальными байтами без изменений: это миграция комментария, без смены правил и повторного resync. Настоящий тест сохраняет initialized-маркеры и listings; посторонний хэш фильтра по-прежнему отвергается.

Уже инициализированные размерной оптимизацией несовместимые listings автоматически не сбрасываются и не объявляются исправленными: такой случай требует отдельного восстановления состояния. Прогоны используют новые временные установки.

### Аудит всего репозитория

Проверены все отслеживаемые текстовые файлы через `git ls-files` и поиск `syncthing|stignore|disk/...`, отдельно build, launcher, transport, серверные схемы, ZIP и документация. Обращений к удалённым файлам в активной цепочке установки/применения облачного лаунчера нет. Публичные схемы не возвращают прежнюю секцию; проверки и код её миграции сохранены. Вне документации точная ссылка на прежний шаблон осталась только в миграции хэша комментария и соответствующем тесте.

**Буквального отсутствия Syncthing во всём репозитории нет.** Остатки не скрыты и не переименованы ради чистого поиска:

| Область | Результат аудита |
|---|---|
| `app/launcher/LegacyDiskMigration.cs`, `tools/legacy-cleanup/`, их тесты | Очистка прежней установки; сохранены по условию задачи. |
| `cloud/filter.txt`, `.gitignore` | Исключение прежних служебных артефактов; это не установка или запуск прежнего движка. |
| `Sync.Runtime.ps1`, `Sync.Workspace.ps1`, `Sync.Orchestrator.ps1`, `server-sync.py`, `server-sync-runtime.py`, `server-install-sync.sh`, корневые тесты | Отдельный действующий контур проектного моста, оставленный предыдущим этапом. Его зависимости существуют; это не обращения к удалённому каталогу. Часть этих файлов входит в бандл для `Invoke-RemoteSyncGuard`. По прежней границе «не менять мост/транспорт» контур не удалён; удаление потребует изменения самого моста. |
| `app/RemoteAgents.Core`, `app/RemoteAgents.Tray`, `app/RemoteAgents.Tests`, `app/test-core-integration.sh` | Прежнее отдельное .NET-приложение и его тесты, с настоящей реализацией Syncthing. Облачный лаунчер на них не ссылается; в его ZIP они не входят. Сохранены, полное удаление не выполнено. |
| Документация | README и актуальные части build/launcher/transport обновлены. Документы прежних задач помечены историческими; их ссылки сохраняют сведения о прежней версии и не выдаются за текущие инструкции. В `docs/CONSTITUTION.md` также есть прежние пути; конституция не менялась, её изменяет только владелец. `THIRD-PARTY-NOTICES.txt` сохранён для оставшегося старого контура. |

Вопрос о полном удалении старого контура задан владельцу отдельно. Результат этого этапа — стыковка облачного лаунчера с честно зафиксированными остатками, а не утверждение о полном удалении Syncthing из репозитория.

### Прогоны

Все launcher-запуски выполнялись с `SKIP_LAUNCHER_EXE=1`, чтобы пройти группы и упаковку без запрещённой сборки/publish Windows EXE. Portable .NET-тесты исполнялись на Linux; это не продуктовые EXE.

Первый полный запуск завершился кодом 1: известный `PermissionError` lan_vpn и найденный вызов удалённого `Set-WizardDiskChannel`. CONFIG E2E уже в этом запуске прошёл: настоящий SSH/sing-box, config export/import, применение, login, sync, revoke; итог 68,0 с. Повтор исправленного loopback отдельно прошёл: Server 4,137 с, Connection 19,622 с, кэш helper и общий сеанс подтверждены.

Финальный полный `SKIP_LAUNCHER_EXE=1 app/launcher/tests/run.sh` завершился **кодом 1**. Причины: известный `PermissionError` lan_vpn и временный таймаут loopback (подробности и отдельные повторы ниже). Прежних ошибок отсутствующего файла/helper/функции больше нет. Остальные группы прошли, в том числе:

- PowerShell cloud stdin и маскирование ошибок; первый запуск, мастер, аккаунт, конфиг, маршруты, scheduler retirement, refresh/sync и server health;
- packaging, загрузка хелперов двумя компьютерами из настоящего ZIP, server operations, heartbeat, account UI и Node account-тесты;
- для RemoteAgents и RemoteVPN: по 55 cloud/config/stdin/migration, 104 config-engine, 108 launcher/update, 65 window, 96 tray и 29 account проверок; CONFIG — по 131 утверждению;
- настоящий CONFIG E2E: все секции успешны, Server 6,549 с, Server→Connection 22,919 с, итог 80,6 с; вход выданным ключом и запрет новых входов после revoke подтверждены;
- финальный ZIP собран, затем runner напечатал `SKIP: Windows launcher EXE build/publish (SKIP_LAUNCHER_EXE=1)`.

В финальном полном запуске loopback отдельно дал таймаут `Управляющий SSH-сеанс не запущен` в `Wizard.Session.ps1:47` (бюджет 12 с). Повтор без изменений кода завершился кодом 0: Server 5,042 с, Connection 23,433 с, общий SSH-сеанс, параллельные команды, неизменённые helpers, доставка cloud/filter и отбрасывание осиротевшего запроса подтверждены. Это временное падение отмечено отдельно от исправленного воспроизводимого вызова удалённой функции. Остальные transport-тесты daemon/liveness в полном запуске прошли.

Серверный runner останавливается на первом сбое. Оставшиеся после известного lan_vpn ещё **15 тестов** выполнены отдельно тем же способом, каждый в отдельном процессе с таймаутом 60 с: все прошли, включая 14 proxy-out. Отдельный повтор `test_lan_vpn.SafetyTests.test_timer_failure_prevents_network_mutation` воспроизводит тот же `PermissionError: /var/lib/remoteagents/lan/pending`; права и сетевое состояние хоста не менялись.

Финальный `bash cloud/tests/run.sh`: **код 0, 7 тестов, 84,207 с, без пропусков**. Вывод:

```text
TOOLS: official rclone 1.76.0, SHA256SUMS verified; apt-get download + dpkg -x OK
EVENT: same-size upload 3.56s, pollSeconds=3600, other project untouched
BISYNC: initial upload, cloud discovery/poll, same-size both ways,
deletions both ways/all/whole project, filters, flock, apply/remove, secrets OK
SYSTEMD: generated user unit, temporary HOME/Disk,
SIGKILL -> automatic restart, event sync OK
CONTRACT: CRLF upload, hash probe/reupload,
Wizard.Cloud -> deployed server-cloud.sh apply stdin, ok:true/error OK
Ran 7 tests in 84.207s
OK
```

`bash -n`, Python compile, `git diff --check` и UTF-8 BOM/CRLF изменённых PS-файлов проверены. Полные журналы этой сессии: `/tmp/cloud-app-integration-logs/launcher.log`, `launcher-final.log`, `cloud-final.log`, `loopback-retry.log`, `loopback-final-retry.log`, `lan-retry.log`, `server-tail.log`.

По стыковке облачного лаунчера ветка **подготовлена к сборке EXE**: обязательные файлы входят в пакет, удалённые helpers не читаются, контракт apply проходит через реальный серверный helper. Нулевого результата общего suite нет из-за описанных сбоев; они не скрыты. Проверки настоящей Windows PowerShell 5.1, миграции Win32 и живого Mail/официального Windows-клиента не выполнялись. Требование полного отсутствия Syncthing во всём репозитории не выполнено: отдельный старый контур и историческая документация явно перечислены в аудите выше.

Коммиты этого этапа до отчёта: `8951630` (доставка/упаковка/контракт), `ec2f676` (совместимые listings bisync), `08435b4` (loopback без прежнего Диска), `40ed35f` (документация/аудит), `8f76ca7` (миграция заголовка фильтра).
