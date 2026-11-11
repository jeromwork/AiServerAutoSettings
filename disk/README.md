# RemoteDisk

Модуль диска RemoteAgents. Его устанавливает мастер (шаг «Диск») командой
`disk/Install-RemoteDisk.ps1 -Profile <ssh-transport.json>`: без администратора скачивается Syncthing Tray 2.1.9
со встроенным движком 2.1.7 (проверка SHA-256), создаётся состояние в `%LOCALAPPDATA%\RemoteDisk`, движок
запускается без окна (`syncthingtray.exe syncthing serve`) под надзором `Disk.Status.ps1` лаунчера.
Связь с сервером идёт через транспорт лаунчера (локальный SSH-вход, по умолчанию 127.0.0.1:2222).
`Install-RemoteDisk.ps1 -Uninstall` убирает значок Disk в Проводнике; пользовательские файлы сохраняются.

Через SSH устанавливаются серверный скрипт и правила исключений. Серверная команда `channel-config` читает
серверный sing-box, получает Reality public key через OpenSSL/X25519 и возвращает клиентскую конфигурацию
канала для транспорта лаунчера. Исходная конфигурация сервера не изменяется.

Серверная папка — `~/Disk/<имя>`, одна на проект. Новые ID: `disk-` и 24 hex SHA-256 от UTF-8 `folder:<имя>`; старые ID сохраняются. Если обе папки непустые, нужно подтверждение или `-Merge`. Повтор безопасен, команда сразу возвращает управление после настройки; передачу показывает готовый трей. Пауза управляется в Syncthing Tray. Без связи файлы остаются доступными для записи. Конфликтные копии сохраняет Syncthing, максимум 10.

Правила обеих сторон — только `stignore.txt`. Перед перезаписью принимаются точная копия или старый набор с отпечатком из `stignore-previous.sha256`, извлечённым из Git-истории. Чужой `.stignore` нужно самостоятельно сохранить и удалить перед подключением. В Git `info/exclude` сервер добавляет `.stfolder`, `.stignore`, `*.sync-conflict-*`. Секреты и генерируемые каталоги исключаются; обычные исходники внутри `log` и `db` передаются.

Серверные команды: `list`, `attach`, `detach`, `add-device`, `channel-config`, `bootstrap`, `reconcile`,
`install-auto`, `tree`, `verify-selection`. Для команд с данными второй аргумент — base64 JSON.

## Автоматическое подключение серверных проектов

Решение владельца от 8 ноября 2026: каждая обычная папка непосредственно в `~/Disk/<имя>` автоматически расшаривается всем зарегистрированным в RemoteDisk устройствам (все peer devices этого отдельного Syncthing). Новое устройство также получает существующие папки. `reconcile` сохраняет старые ID, паузы и настройки существующих папок, новые создаёт `sendreceive` из defaults. Удаление каталога не удаляет регистрацию и данные других сторон. Символические ссылки и недопустимые Windows-имена пропускаются. Чужой `.stignore` блокирует только свою папку и попадает в stderr/journal. За пределами `~/Disk` reconcile не регистрирует папки и не пишет Git exclude, включая внешний gitdir worktree.

`bootstrap` и `add-device` также вызывают reconcile. Существующая cron-проверка bootstrap раз в минуту сохраняется. Команда `install-auto` дополнительно устанавливает пользовательский systemd timer с интервалом 30 секунд; root не нужен. Если user manager не работает без входа пользователя, автоматизация работает только пока доступна пользовательская сессия (либо через существующий cron). Скрипт не включает linger и не устанавливает пакеты.

Любое содержимое целевой папки, включая только `.git` или скрытые файлы, означает **«папка занята»**. Папка остаётся pending; сообщение записывается в `%LOCALAPPDATA%\RemoteDisk\install.log` (ротация 256 KiB), при ручном запуске также выводится warning. Вложенные/пересекающиеся пути Syncthing и reparse points запрещены. Для уже зарегистрированного ID повтор ничего не меняет. Контекстное меню и явное подключение с подтверждением объединения остаются доступны. Задача требует входа того же Windows-пользователя; длительная недоступность REST видна в журнале.

### Применение на сервере владельцем

Изменения подготовлены в репозитории; эти команды меняют рабочую конфигурацию **только при ручном применении**:

```bash
cd /home/remoteagents/Disk/AiServerAutoSettings
install -m 700 disk/server-disk.sh "$HOME/.local/share/remote-disk/server-disk.sh"
install -m 600 disk/stignore.txt disk/stignore-previous.sha256 "$HOME/.local/share/remote-disk/"
bash "$HOME/.local/share/remote-disk/server-disk.sh" install-auto
bash "$HOME/.local/share/remote-disk/server-disk.sh" reconcile
systemctl --user status remote-disk-folders.timer --no-pager
journalctl --user -u remote-disk-folders.service -n 30 --no-pager
```

Выключить дополнительный таймер: `systemctl --user disable --now remote-disk-folders.timer`. Пока остаётся старый cron bootstrap, он продолжает reconcile; для полного выключения автоматизации требуется убрать именно строку RemoteDisk из пользовательского crontab. `detach` при включённой автоматизации временный: очередная проверка снова добавит устройство. Постоянные исключения устройств/папок пока не реализованы.

Изолированные проверки (общий лимит 120 секунд, небольшой набор файлов):

```sh
python3 disk/test-disk.py /tmp/remote-disk-release-zP80am/syncthing-linux-amd64-v2.1.7.tar.gz
~/.cache/pwsh-test/pwsh -NoProfile -File disk/test-install.ps1
python3 -B test-windows-control.py
bash -n disk/server-disk.sh
```
