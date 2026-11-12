# Движок CONFIG: интерфейс C ↔ D ↔ B

Поток C. Windows PowerShell 5.1; существующий JSON-интерфейс `build/Wizard.ps1` сохранён:

```text
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File build/Wizard.ps1
  -Home <основной Home> -Action <действие> -RequestFile <JSON> -ProgressFile <JSONL>
```

Один результат в stdout: `{"ok":true,"result":...}` или `{"ok":false,"reason":...,"remedy":...}` с кодом выхода 1. Успех оболочки означает выполнение запроса; готовность раздела определяется **`result.ok`**, `pending`, `vpn`, `skipped`. Установки в фоне и неподтверждённый TUN не становятся готовностью.

## Порядок и запросы

D сначала сохраняет `profile` и вызывает `SecretVault.Materialize(home)`, затем `Bootstrap`, `Server`. После успешного Server допускаются независимые процессы Connection, Bridge, Account, Disk, Vpn. Proxy/Lan сериализуются. Для VPN остаётся зависимость от живой связи: ранний Vpn возвращает `pending:"connection"`; до proof он не выключает начальный VPN, даже если итоговый vpn.enabled=false.

Как окно (D, `SectionOutcome.From`, `ConfigEngine`) читает ответ: `result.ok:true` — ✅; `ok:false` с `pending:"disk"|"happier"` —
⏳, окно и трей следят за установкой действием `Operation` и повторяют только этот раздел; `pending:"connection"` у Vpn —
Vpn повторяется один раз сразу после успешного Connection; `ok:false` без `pending` — ❌ с причиной и «Повторить»
(исключение — неподтверждённый запрос TUN у Vpn: ⏳ «ещё не подтверждено», никогда не ✅). Ошибка оболочки
(`{"ok":false,"reason"}`) — ❌ с причиной.

| Действие | Запрос / изменение |
|---|---|
| `Bootstrap` | `{}`; необязательный `parentPid` для существующего TUN/watchdog. Читает `profile.vpn.bootstrap`, **до первого SSH** проверяет чужой VPN, выбирает путь с настоящим HTTPS, запускает существующий Vpn.Tun и ждёт свежего `state=on`. Без bootstrap — пропуск; на уже управляемой установке — `skipped`, действующая сеть сохраняется. Ошибка/конфликт дают `result.ok=false`, без поддельного transport.ok. |
| `Server` | Прежние `address`, `login`, `keyFile`, `passwordPipe`, `askpassExecutable`, `proxy`, `hop`, `installMissing`. Если имеется `profile.server` с материализованным ключом, входит **именно этим ключом**, не создаёт и не добавляет другой. Отсутствующий материализованный секрет — отказ, без отката к регистрации другого ключа. `profile.server.port`, `hostKeys`, `routes` применяются при этом входе. Старый административный мастер по паролю остаётся отдельным путём. |
| `Connection` | Прежние `catalog`, `shared`, `expected`. `catalog` — публичная схема 1 (`entries/hops/relays/cdn`). При первом запуске запускает и оставляет **рабочий** daemon и требует свежий revision + настоящий SSH через локальный inbound. Не создаёт preflight-копию. При изменении установленной связи сохраняет прежние preflight/watchdog/rollback. От Syncthing не зависит. |
| `Bridge` | Прежние `enabled`, `shell`; новое необязательное `deviceName`: 1–80 символов без управляющих символов. Для работающего моста переименование тоже сразу отправляется серверу: повторная регистрация существующего binding с новым именем, проверка чтением реестра. Shell и пути binding сохраняются. Имя записывается в `profile.device.name`. |
| `Account` | Прежние поля. Дополнительно `mode:"same"`, необязательный публичный `account` — выбрать и живой проверкой подтвердить существующий серверный аккаунт, без recovery-ключа и без нового daemon. Неоднозначный выбор — отказ. Обычный запрос с ключом по-прежнему использует существующий Invoke-WizardAccount. |
| `Disk` | Прежние `base`, `paths`, `reconnect`. Если серверный Syncthing ещё не готов, возвращает `ok:false,pending:"disk",operation,summary`; C запускает/наблюдает отсоединённую установку. D повторяет **Disk**, остальные разделы продолжают работу. После подготовки диска C отдельно добавляет настоящий sync inbound в канал и проверяет reload + SSH; Connection ожидания диска не содержит. |
| `ConfigSync` | `{}`; необязательный `askpassExecutable` для пароля hop, по умолчанию установленный EXE. Снимок `config-sync.json` берётся только по доверенному SSH, собственным ключом; произвольный JSON запроса не применяется как доверенный снимок. Ответ `{ok, changed, summary}`. |

Остальные действия и запросы сохранены. Действий InvitePrepare/Enroll/Verify/Disk/Account/Refresh/Sync больше нет; файлы приглашений, одноразовые ключи и offline refresh EXE движок не принимает.

### Материализация (стык A ↔ C)

PS не читает vault и не разыменовывает `{"secret":...}` сам. Окно (D) сохраняет profile (`ConfigBundle.Store`), спрашивает
пустые секреты и вызывает `SecretVault.Materialize(home)`; единственная карта путей — `secrets/materialized.json`
(таблица — `docs/CONFIG.md`). Пустая ссылка не даёт файла и перечисляется в `missing`; старый файл вместо неё не
используется. PowerShell (`Get-WizardMaterialized`) берёт оттуда:

- ключ сервера: `profile.server.keyFile/keyPath` (внутреннее), иначе `serverKeyFile` манифеста, иначе ключ уже работающего
  SSH-профиля с тем же адресом/логином; нет ключа и есть ссылка `server.key` — отказ, другой ключ не создаётся;
- маршрут `hop` с индексом i: `routes[i].hop.keyFile` → `keyFile`; пароль из `routes[i].hop.passwordFile`
  (`secrets/route-<i>-auth.json`) → постоянный `routePasswordFile` этого маршрута (askpass EXE + `transport/Route.Proxy.ps1`,
  в аргументах SSH только путь). Профильная форма `hop.{host,user,port}` переводится в `hop.ssh`, `proxy.server` → `proxy.host`;
- VPN первым: `channelPath` (или `secrets/channel.json`), кэши узлов `secrets/entries/<имя>.json`; SSH-переходы каталога —
  ключ `hops.<имя>.keyFile` манифеста, адрес из `profile.vpn.bootstrap.hops.<имя>`, ключи хоста из каталога: пишется
  частный ssh config (`<ключ>.conf`, `<ключ>.known_hosts`, StrictHostKeyChecking yes) под публичным псевдонимом узла;
- `sing-box.exe`: `transport.singBoxPath`, иначе `transport-bin/sing-box.exe` в Home; при первом запуске копируется из
  начального бандла EXE (`transport/sing-box.exe`, SHA-256 сверяется с `build/bundle-binaries.json`), иначе прежняя загрузка
  1.14.4 с закреплённой SHA-256. Нет ни того, ни другого — понятный отказ раздела, а не тихий провал;
- VPN первым запускается только если в `profile.vpn.bootstrap` есть `channel`; один публичный `catalog`
  (`config export --vpn off`) — не VPN.

Учётные данные прокси маршрута (`routes[i].proxy.credentialsFile`) материализуются, но `--proxy-connect` их пока не
использует: маршрут через прокси с паролем не поддержан (честное ограничение).

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

## Автообновление (ConfigSync) — общий протокол с сервером

Один формат на обеих сторонах: сервер публикует снимок, клиент читает его своим ключом. Серверная сторона и поля —
`docs/CONFIG-SERVER.md`, раздел «Автообновление»; здесь — клиент.

После Server на Windows устанавливается задача текущего пользователя `RemoteAgents config sync <home-hash>`: каждые **5 минут**, также при входе. Без повышения прав, IgnoreNew, лимит 4 минуты; runtime хранится отдельно и переживает удаление исходного bundle. Трей дополнительно вызывает то же действие `ConfigSync` сразу после восстановления связи. Linux-тесты проверяют адаптер планировщика, настоящую задачу не создают.

1. Клиент по собственному SSH-ключу (сначала через местный транспорт, затем сохранённым маршрутом; без keyscan,
   accept-new и HTTP) читает снимок: `cat "$HOME/.config/remoteagents/config-sync.json"` (до 1 МиБ, `\r` убирается).
2. Снимок — `{"kind":"remoteagents-config-sync","schema":1,"generatedUtc","revision","config"}`, где `config` — частичный
   конфиг формата вставки (`server.address/port/login/hostKeys/routes`, `vpn.checkUrl/dnsServer/bootstrap`,
   `secrets` открытым текстом). Другой `kind`/`schema`, секрет по ссылке, которого нет в снимке, — отказ.
3. `ConvertFrom-WizardConfigSync` (build/Wizard.Refresh.ps1) переводит его во внутренний снимок настроек
   (`serverAddress/serverPort/workerUser/hostKeys`, маршруты `proxy.host`, `hop.{ssh,hostKey,privateKey,password}`,
   `bootstrap.{catalog,channel,entries,hops{host,port,user,privateKey},vpn}`). Отсутствующие поля не трогаются:
   ключ компьютера, `vpn.enabled`, device/happier/bridge/disk/proxyOut/lan в снимке не передаются.
4. Публичный каталог берётся живым (`python3 - < transport/server-transport-catalog.py`) и авторитетен; каталог из снимка
   нужен только до первого SSH. `workerUser` не может смениться. Неизменный снимок (тот же отпечаток) ничего не применяет.

Новые pins, routes, caches и VPN готовятся в `state/connection-generations`; ключ не заменяется. После изолированного preflight включается независимый rollback, затем обновляется стабильный профиль, проверяется рабочий revision/SSH. При ошибке возвращаются прежние профиль, pins, канал, VPN и pin intent. Секреты не помещаются в вывод/прогресс. После sync повторно регистрируется `profile.device.name`, если мост включён.

Проверено сквозным тестом `app/launcher/tests/test_config_e2e.py`: снимок, выданный настоящим `remoteagents config export`,
применяется по настоящему SSH через местный транспорт; добавленный на сервере ключ хоста (`remoteagents config sync`)
закрепляется у клиента, повторный вызов ничего не меняет.

**Имя компьютера при переподключении:** `Start-WindowsControl.ps1` при каждой регистрации берёт `-DeviceName`, иначе
`profile.device.name` из `config.json` программы, иначе `COMPUTERNAME` — переподключение моста не возвращает `WIN-…`.
