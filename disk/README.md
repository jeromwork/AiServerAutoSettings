# RemoteDisk

`04-disk.cmd [-Profile C:\путь\ssh-transport.json]` устанавливает без администратора Syncthing Tray 2.1.9 со встроенным движком 2.1.7 и sing-box 1.14.4. Данные и настройки находятся в `%LOCALAPPDATA%\RemoteDisk`. Существующие устройство, индексы и паузы сохраняются. Нужны Windows, PowerShell 5.1, сохранённый SSH-профиль и доступ к GitHub. Серверу нужны Python 3, OpenSSL, Git и Linux amd64; пользователь SSH должен читать конфигурацию sing-box.

Через SSH устанавливаются серверный скрипт и правила исключений. `channel-config` читает серверный sing-box, получает Reality public key через OpenSSL/X25519 и возвращает клиентскую конфигурацию прямо в файл. Исходная конфигурация сервера не изменяется. Прямой маршрут и промежуточный SSH-хост из профиля выбирает urltest. Задача `RemoteDiskChannel` запускает канал при входе и проверяет запуск каждую минуту. Трей запускается через HKCU Run.

Контекстное меню папки «Синхронизировать с сервером» предлагает одноимённую серверную папку или простой выбор. Для агентов:

```powershell
& "$env:LOCALAPPDATA\RemoteDisk\app\Add-RemoteDiskFolder.ps1" -Path D:\Работа\app -Remote app
```

Серверная папка — `~/Disk/<имя>`, одна на проект. Новые ID: `disk-` и 24 hex SHA-256 от UTF-8 `folder:<имя>`; старые ID сохраняются. Если обе папки непустые, нужно подтверждение или `-Merge`. Повтор безопасен, команда сразу возвращает управление после настройки; передачу показывает готовый трей. Пауза управляется в Syncthing Tray. Без связи файлы остаются доступными для записи. Конфликтные копии сохраняет Syncthing, максимум 10.

Правила обеих сторон — только `stignore.txt`. Перед перезаписью принимаются точная копия или старый набор с отпечатком из `legacy-ignores.sha256`, извлечённым из Git-истории. Чужой `.stignore` нужно самостоятельно сохранить и удалить перед подключением. В Git `info/exclude` сервер добавляет `.stfolder`, `.stignore`, `*.sync-conflict-*`. Секреты и генерируемые каталоги исключаются; обычные исходники внутри `log` и `db` передаются.

`04-disk.cmd -Uninstall` снимает автозапуск, задачу и меню; пользовательские файлы и папки сохраняются. Серверные команды: `list`, `attach`, `detach`, `add-device`, `channel-config`, `bootstrap`. Для команд с данными второй аргумент — base64 JSON. `detach` убирает устройство из папки, оставляя файлы.

Изолированные проверки (общий лимит 120 секунд, небольшой набор файлов):

```sh
python3 disk/test-disk.py /tmp/remote-disk-release-zP80am/syncthing-linux-amd64-v2.1.7.tar.gz
~/.cache/pwsh-test/pwsh -NoProfile -File disk/test-install.ps1
python3 -B test-windows-control.py
bash -n disk/server-disk.sh
```

`test-disk.py` также запускает три остальные проверки в рамках общего лимита. Windows-планировщик, реестр, WinForms, Win32_Process и реальное переключение сетевого маршрута требуют проверки на Windows.

## Автоматическое подключение серверных проектов

Решение владельца от 8 ноября 2026: каждая обычная папка непосредственно в `~/Disk/<имя>` автоматически расшаривается всем зарегистрированным в RemoteDisk устройствам (все peer devices этого отдельного Syncthing). Новое устройство также получает существующие папки. `reconcile` сохраняет старые ID, паузы и настройки существующих папок, новые создаёт `sendreceive` из defaults. Удаление каталога не удаляет регистрацию и данные других сторон. Символические ссылки и недопустимые Windows-имена пропускаются. Чужой `.stignore` блокирует только свою папку и попадает в stderr/journal. За пределами `~/Disk` reconcile не регистрирует папки и не пишет Git exclude, включая внешний gitdir worktree.

`bootstrap` и `add-device` также вызывают reconcile. Существующая cron-проверка bootstrap раз в минуту сохраняется. Команда `install-auto` дополнительно устанавливает пользовательский systemd timer с интервалом 30 секунд; root не нужен. Если user manager не работает без входа пользователя, автоматизация работает только пока доступна пользовательская сессия (либо через существующий cron). Скрипт не включает linger и не устанавливает пакеты.

На Windows отдельная задача `RemoteDiskFolders` при входе и раз в минуту запускает короткий companion `Sync-RemoteDiskFolders.ps1`. Она работает рядом с готовым Syncthing Tray, повторяет попытку после восстановления REST/связи и принимает только предложения из сохранённого `server.txt`. Встроенный `autoAcceptFolders` для сервера выключается: он не обеспечивает проверку занятости. База, как у Яндекс Диска, — `%USERPROFILE%\Disk` (например `C:\Users\user\Disk\<label>`), сохраняется в `%LOCALAPPDATA%\RemoteDisk\base.txt`. Эту же базу companion записывает в настройку Syncthing «папка по умолчанию», поэтому ручное принятие в трее предлагает то же место.

Сменить базу: `& "$env:LOCALAPPDATA\RemoteDisk\app\Enable-RemoteDiskFolders.ps1" -BasePath 'D:\Projects'`. Все серверные папки, лежащие прямо в прежней базе, переезжают в новую с сохранением folder ID и паузы. На том же диске каталог перемещается, на другой диск — копируется, сверяется и только потом удаляется исходник. Если хоть одна папка не переехала (путь занят, файл заблокирован), база не меняется: устраните причину и повторите команду, перенесённые папки повторно не трогаются. При первом включении прежней базой считается `C:\work` (ранний вариант по умолчанию). Папки, подключённые через контекстное меню в произвольном месте, остаются там, где их выбрали.

Любое содержимое целевой папки, включая только `.git` или скрытые файлы, означает **«папка занята»**. Папка остаётся pending; сообщение записывается в `%LOCALAPPDATA%\RemoteDisk\install.log` (ротация 256 KiB), при ручном запуске также выводится warning. Вложенные/пересекающиеся пути Syncthing и reparse points запрещены. Для уже зарегистрированного ID повтор ничего не меняет. Контекстное меню и явное подключение с подтверждением объединения остаются доступны. Задача требует входа того же Windows-пользователя; длительная недоступность REST видна в журнале.

### Применение на сервере владельцем

Изменения подготовлены в репозитории; эти команды меняют рабочую конфигурацию **только при ручном применении**:

```bash
cd /home/remoteagents/Disk/AiServerAutoSettings
install -m 700 disk/server-disk.sh "$HOME/.local/share/remote-disk/server-disk.sh"
install -m 600 disk/stignore.txt disk/legacy-ignores.sha256 "$HOME/.local/share/remote-disk/"
bash "$HOME/.local/share/remote-disk/server-disk.sh" install-auto
bash "$HOME/.local/share/remote-disk/server-disk.sh" reconcile
systemctl --user status remote-disk-folders.timer --no-pager
journalctl --user -u remote-disk-folders.service -n 30 --no-pager
```

Выключить дополнительный таймер: `systemctl --user disable --now remote-disk-folders.timer`. Пока остаётся старый cron bootstrap, он продолжает reconcile; для полного выключения автоматизации требуется убрать именно строку RemoteDisk из пользовательского crontab. `detach` при включённой автоматизации временный: очередная проверка снова добавит устройство. Постоянные исключения устройств/папок пока не реализованы.

### Применение на Windows, PowerShell 5.1

Скачайте подготовленный `remotedisk-auto.zip` в Downloads. Это исходные скрипты, без бинарников и конфигураций. Обновление не запускает общий установщик, не меняет sing-box и не требует скачивания программ:

```powershell
$src = Join-Path $env:TEMP 'remotedisk-auto-update'
Expand-Archive -LiteralPath "$env:USERPROFILE\Downloads\remotedisk-auto.zip" -DestinationPath $src -Force
& "$src\Enable-RemoteDiskFolders.ps1"
# Немедленная проверка вместо ожидания минуты:
& "$env:LOCALAPPDATA\RemoteDisk\app\Sync-RemoteDiskFolders.ps1"
Get-ScheduledTask -TaskName RemoteDiskFolders
Get-Content -LiteralPath "$env:LOCALAPPDATA\RemoteDisk\install.log" -Tail 30
```

Если политика выполнения блокирует локальные скрипты, выполните их через `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <путь>` (либо временно задайте `Set-ExecutionPolicy -Scope Process Bypass`). Установщик `04-disk.cmd` для новых установок включает эту задачу сам. Отключение companion: `& "$env:LOCALAPPDATA\RemoteDisk\app\Enable-RemoteDiskFolders.ps1" -Disable`.

CLI сам загружает адрес REST и API credential через существующий `Read-DiskState`; переменные окружения трея и особый HOME не нужны. Подтверждено на WIN-405GNP6MREA: у plain PowerShell переменные не инициализированы, после загрузки state REST доступен. Ключ не печатается:

```powershell
. "$env:LOCALAPPDATA\RemoteDisk\app\Disk.Common.ps1"
Invoke-DiskApi 'system/status' | Select-Object myID
Invoke-DiskApi 'config/folders' | Select-Object id,label,path,paused
```

### Перенос уже принятой NaPolyakh

Папка вне базы (Documents) при смене базы не переезжает, её переносят один раз явно. Сначала убедитесь, что `$env:USERPROFILE\Disk\NaPolyakh` отсутствует или пуст. Скрипт перемещает каталог (внутри тома — Directory.Move, на другой том или с `-Copy` — копирование со сверкой и удалением исходника), сохраняет ID, исключения, индексы и исходную паузу. Он ждёт события Syncthing `FolderPaused`, перемещает каталог, обновляет только локальный path и возобновляет. Серверные API не вызываются; файлы не удаляются на сервере. Содержимое не объединяется. Перед переносом закройте редакторы и другие программы, которые пишут в исходную папку.

```powershell
. "$env:LOCALAPPDATA\RemoteDisk\app\Disk.Common.ps1"
$f = @(Invoke-DiskApi 'config/folders' | Where-Object { $_.label -ceq 'NaPolyakh' })
if ($f.Count -ne 1) { throw 'Ожидалась одна NaPolyakh; проверьте список ID' }
& "$env:LOCALAPPDATA\RemoteDisk\app\Move-RemoteDiskFolder.ps1" -FolderId $f[0].id -Destination "$env:USERPROFILE\Disk\NaPolyakh"
Invoke-DiskApi 'config/folders' | Select-Object id,label,path,paused
```

Если после физического перемещения REST не принял новый path, скрипт оставляет папку на паузе: данные уже лежат в новом месте. Проверьте оба пути, затем вручную выполните `Invoke-DiskApi ('config/folders/'+$f[0].id) PATCH @{path="$env:USERPROFILE\Disk\NaPolyakh"}` и `Invoke-DiskApi ('config/folders/'+$f[0].id) PATCH @{paused=$false}`. Не создавайте пустой старый каталог и не снимайте паузу до исправления path. При ошибке до перемещения исходный каталог сохраняется; сначала выясните причину, затем верните исходную паузу.

Проверки Linux запускают два настоящих Syncthing 2.1.7 в временных HOME и реальные companion/move скрипты через уже имеющийся pwsh. Проверяются discovery, повтор, новая регистрация, пропуск symlink/чужой политики, pending для занятой `.git`-папки, автоматическая передача, перенос с тем же ID, передача после переноса, смена базы с переездом папок, перенос копированием с сохранением времени файлов и запрет переноса внутрь самой папки. Реальные Windows Task Scheduler, NTFS ACL/блокировки и PowerShell 5.1 требуют приёмки владельцем. Между проверкой свободного пути и регистрацией возможна внешняя запись другой программы: не создавайте/не наполняйте этот путь одновременно с принятием. Ошибка после записи `.stignore`, но до регистрации может оставить служебный файл в ещё не принятой папке; после проверки его можно убрать и повторить.
