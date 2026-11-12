# Движок CONFIG: интерфейс C ↔ D ↔ B

Поток C. Windows PowerShell 5.1; существующий JSON-интерфейс `build/Wizard.ps1` сохранён:

```text
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File build/Wizard.ps1
  -Home <основной Home> -Action <действие> -RequestFile <JSON> -ProgressFile <JSONL>
```

Один результат в stdout: `{"ok":true,"result":...}` или `{"ok":false,"reason":...,"remedy":...}` с кодом выхода 1. Успех оболочки означает выполнение запроса; готовность раздела определяется **`result.ok`**, `pending`, `vpn`, `skipped`. Установки в фоне и неподтверждённый TUN не становятся готовностью.

## Порядок и запросы

D сначала сохраняет `profile` и вызывает `SecretVault.Materialize(home)`, затем `Bootstrap`, `Server`. После успешного Server допускаются независимые процессы Connection, Bridge, Account, Disk, Vpn. Proxy/Lan сериализуются. Для VPN остаётся зависимость от живой связи: ранний Vpn возвращает `pending:"connection"`; до proof он не выключает начальный VPN, даже если итоговый vpn.enabled=false.

| Действие | Запрос / изменение |
|---|---|
| `Bootstrap` | `{}`; необязательный `parentPid` для существующего TUN/watchdog. Читает `profile.vpn.bootstrap`, **до первого SSH** проверяет чужой VPN, выбирает путь с настоящим HTTPS, запускает существующий Vpn.Tun и ждёт свежего `state=on`. Без bootstrap — пропуск; на уже управляемой установке — `skipped`, действующая сеть сохраняется. Ошибка/конфликт дают `result.ok=false`, без поддельного transport.ok. |
| `Server` | Прежние `address`, `login`, `keyFile`, `passwordPipe`, `askpassExecutable`, `proxy`, `hop`, `installMissing`. Если имеется `profile.server` с материализованным ключом, входит **именно этим ключом**, не создаёт и не добавляет другой. Отсутствующий материализованный секрет — отказ, без отката к регистрации другого ключа. `profile.server.port`, `hostKeys`, `routes` применяются при этом входе. Старый административный мастер по паролю остаётся отдельным путём. |
| `Connection` | Прежние `catalog`, `shared`, `expected`. `catalog` — публичная схема 1 (`entries/hops/relays/cdn`). При первом запуске запускает и оставляет **рабочий** daemon и требует свежий revision + настоящий SSH через локальный inbound. Не создаёт preflight-копию. При изменении установленной связи сохраняет прежние preflight/watchdog/rollback. От Syncthing не зависит. |
| `Bridge` | Прежние `enabled`, `shell`; новое необязательное `deviceName`: 1–80 символов без управляющих символов. Для работающего моста переименование тоже сразу отправляется серверу: повторная регистрация существующего binding с новым именем, проверка чтением реестра. Shell и пути binding сохраняются. Имя записывается в `profile.device.name`. |
| `Account` | Прежние поля. Дополнительно `mode:"same"`, необязательный публичный `account` — выбрать и живой проверкой подтвердить существующий серверный аккаунт, без recovery-ключа и без нового daemon. Неоднозначный выбор — отказ. Обычный запрос с ключом по-прежнему использует существующий Invoke-WizardAccount. |
| `Disk` | Прежние `base`, `paths`, `reconnect`. Если серверный Syncthing ещё не готов, возвращает `ok:false,pending:"disk",operation,summary`; C запускает/наблюдает отсоединённую установку. D повторяет **Disk**, остальные разделы продолжают работу. После подготовки диска C отдельно добавляет настоящий sync inbound в канал и проверяет reload + SSH; Connection ожидания диска не содержит. |
| `ConfigSync` | `{}`; необязательный `askpassExecutable` для пароля hop, по умолчанию установленный EXE. Снимок берётся только по доверенному SSH, собственным ключом; произвольный JSON запроса не применяется как доверенный снимок. |

Остальные действия и запросы сохранены. Действий InvitePrepare/Enroll/Verify/Disk/Account/Refresh/Sync больше нет; файлы приглашений, одноразовые ключи и offline refresh EXE движок не принимает.

### Материализация для A

PS не читает vault и не разыменовывает `{"secret":...}` самостоятельно. Он ожидает:

- существующий `transport.profilePath` с путём ключа, совпадающими адресом/логином из `profile.server`; либо внутренний `profile.server.keyFile`/`keyPath`; резервный стандартный путь — `secrets/server-key`;
- `secrets/channel.json`, `secrets/entries/<transport-name>.json`, локальный `transport.singBoxPath` либо `transport-bin/sing-box.exe`; Bootstrap/Connection также находят binary в bundle (`transport/sing-box.exe`, `transport-bin/sing-box.exe`). При отсутствии используется прежняя загрузка 1.14.4 с закреплённой SHA-256, до первого SSH;
- публичные списки в `transport.entries/hops/relays/cdn`. При их отсутствии Bootstrap строит entries из имён `profile.vpn.bootstrap.entries`; необязательный `bootstrap.catalog` понимается для перенесённых снимков, но не требуется внешнему формату;
- VPN hop-конфигурации и пути в `transport.hops` должны быть материализованы. Ключи hop — `keyFile`. Пароль hop — `routePasswordFile`, приватный JSON со `sshExecutable`, `configPath`, `knownHostsPath`, `askpassExecutable`, `host`, `port`, `user`, `password`. В SSH argv попадает только путь;
- профильные маршруты `proxy.server` и `hop.{host,user,port}` принимаются и преобразуются к прежним `proxy.host`, `hop.ssh`. Уже материализованные прежние формы тоже допустимы.

Если hostKeys отсутствуют при **первом импорте**, используется существующий подход мастера: OpenSSH `accept-new`, затем закрепление полученного ключа и StrictHostKeyChecking=yes. Уже доверенные обновления требуют явные hostKeys. Bootstrap без hostKeys может проверять только интернет-пути, не выдумывает готовность SSH.

## Замки, управляющий сеанс и журнал

| Ресурс | Изменяющие действия |
|---|---|
| connection | Connection, RollbackNetwork, ConfigSync; короткое добавление inbound Disk |
| bridge | Bridge, RollbackBridge, ConfigSync |
| account | Account, ResumeAccount |
| disk | Disk, изменение/пропуск выбора диска |
| vpn | Vpn, Bootstrap, ConfigSync, RollbackNetwork |
| server-network | Proxy, Lan, LanRemove |
| profile | Server |

ConfigSync берёт bridge → connection → vpn в одном порядке. Config R/M/W, общий setup.log и ProgressFile защищены отдельными короткими mutex. Read-only polling не держит общий замок настройки. Никакого общего Invoke-WizardLock вокруг действий нет.

Штатный Wizard.ps1 включает общий SSH worker. Отдельные процессы обращаются через приватную файловую очередь `state/wizard-control/<hash>` к одному SSH-процессу. Команды исполняются параллельно, получают собственные stdout/код/таймаут; stderr не выдаётся в JSON. Очередь публикуется атомарно после установки прав, ответы удаляются, worker завершается после 330 секунд простоя. Смена профиля, pins, маршрута или протокола создаёт другое поколение сеанса. Разрыв возвращает ошибку разделу; команды с изменениями автоматически не повторяются.

**Proxy/Lan подтверждаются новым SSH**, даже при общем worker. Живая проверка Connection тоже использует новое аутентифицированное соединение через рабочий транспорт. Для прямого вызова библиотек в тестах повторное использование включается `REMOTEAGENTS_WIZARD_SESSION=1`; штатный CLI включает его сам.

Helpers проверяются по SHA-256 нормализованного LF-содержимого; передаются только отсутствующие/изменённые. Записи атомарные и с уникальными временными именами. Существующие серверные bridge helpers сохраняются, как в прежнем установщике. Disk из мастера принимает внутренний `-HelpersReady` после этой проверки; отдельный установщик продолжает готовить свои helpers самостоятельно.

ProgressFile остаётся UTF-8 JSONL: `{"text":"..."}`. После каждого действия, включая исключение, появляется **`{"text":"timing Connection 1234"}`**: `timing <Action> <целые миллисекунды>`. Это общее время действия с ожиданием своего ресурса. Параллельные шаги могут писать в один ProgressFile; строки не смешиваются. Setup.log также локальный и не зависит от сети.

Выбранный ProxyCommand/HostName/HostKeyAlias записывается в сгенерированный SSH config. Уже существующие скрипты подготовки и reverse SSH моста читают этот config через `-F`.

## Протокол обновления для B

После Server на Windows устанавливается задача текущего пользователя `RemoteAgents config sync <home-hash>`: каждые **5 минут**, также при входе. Без повышения прав, IgnoreNew, лимит 4 минуты; runtime хранится отдельно и переживает удаление исходного bundle. Linux-тесты проверяют адаптер планировщика, настоящую задачу не создают.

Клиент вызывает по собственному SSH-ключу:

```sh
export PATH="$HOME/.local/bin:$PATH"; remoteagents config sync
```

Ожидается JSON (до 1 МиБ):

```json
{
  "schema": 1, "type": "settings",
  "serverAddress": "server.example.invalid", "serverPort": 22,
  "workerUser": "worker", "hostKeys": ["ssh-ed25519 BASE64"],
  "routes": [{"kind":"direct"}],
  "bootstrap": {
    "channel": {"inbounds":[],"outbounds":[]},
    "entries": {}, "hops": {},
    "vpn": {"checkUrl":"https://check.example.invalid/","dnsServer":"192.0.2.53"}
  }
}
```

`entries` — прежние client.json по имени; `hops` — прежние переносимые snapshot `{host,port,user,privateKey}` с hostKey в публичном каталоге. Канал может быть SSH-only. Публичный каталог клиент отдельно получает штатным `server-transport-catalog.py`; его удаления авторитетны. `workerUser` не может измениться. Неизменный снимок не запускает повторное применение.

Новые pins, routes, caches и VPN готовятся в `state/connection-generations`; ключ не заменяется. После изолированного preflight включается независимый rollback, затем обновляется стабильный профиль, проверяется рабочий revision/SSH. При ошибке возвращаются прежние профиль, pins, канал, VPN и pin intent. Секреты не помещаются в вывод/прогресс. После sync повторно регистрируется `profile.device.name`, если мост включён.

**Стык координатора:** `Start-WindowsControl.ps1` вне файлов C пока посылает `$env:COMPUTERNAME` при каждой новой регистрации. Чтобы пользовательское имя сохранялось немедленно и после reconnect, эта строка должна брать `profile.device.name` с fallback на COMPUTERNAME. Здесь имя передаётся при Bridge и восстанавливается ConfigSync; менять чужой файл потоку C запрещено.
