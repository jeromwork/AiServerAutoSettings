# Облако и удаление прежнего Диска: отчёт app/cloud-app

Дата: 13.11.2026. Основа: `0a3d3a8`. Windows EXE не собирался, публикации и push не выполнялись.

## Статус и обязательная стыковка

Локальная часть, миграция, модель конфига и новый трей реализованы. **Ветка пока не готова к выпуску отдельно от серверного потока.** По прямому ограничению задачи функция `Send-WizardHelpers` оставлена неизменной: она ещё пытается читать три удалённых файла `disk/`. Это воспроизводимый дефект стыковки, а не известное падение среды. Вопрос о владельце этой правки задан; разрешения менять функцию не получено. Каталог `cloud/` не изменялся.

Перед совместной интеграцией в `Send-WizardHelpers` нужно убрать загрузку `disk/server-disk.sh`, `disk/stignore.txt`, `disk/stignore-previous.sha256` и ветвления `Get-DiskIgnoreUpload`/истории stignore. Серверный поток должен обеспечить доставку своего `cloud/server-cloud.sh` в `$HOME/.local/share/remoteagents-cloud/server-cloud.sh`. Приложение использует только оговорённый контракт `apply` через stdin. После интеграции необходимо повторить проверки loopback, параллельной загрузки хелперов и CONFIG E2E, перечисленные ниже.

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
