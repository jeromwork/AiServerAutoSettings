# Отчёт потока B (сервер) — задача CONFIG

Ветка `app/config-b`, worktree `~/work/wt-config-b`. Живой сервер, `~/.ssh`, authorized_keys пользователя `remoteagents`,
службы, мост и Windows не трогались: все проверки — во временных каталогах и на своём sshd (loopback, без root).

## Что сделано

1. **`remoteagents config export --name "<название>" [--master-password-stdin] [--vpn on|off] [--happier same|new:Имя]
   [--folders a,b/c] [--output файл]`** — полный конфиг по формату соглашения (раздел 1): новая пара ed25519 на каждую
   выдачу (ssh-keygen), открытая часть — в authorized_keys рабочего пользователя строкой `… ra-config:<id> <название>`,
   закрытая — `secrets.server-key`. Адрес/порт/ключи хоста/маршруты/VPN первым — из настроек выдачи
   `/etc/remoteagents/config-export.json` (бывший `/etc/remoteagents/invite/config.json`, без полей ra-enroll/sudo/EXE)
   и тех же источников, что брал invite: каталог связи `transport-catalog.json` с той же проверкой схемы, снимки канала/узлов
   VPN, ключи переходов. Ключи хоста по умолчанию берутся из `/etc/ssh/ssh_host_*_key.pub` этого сервера.
   Запись authorized_keys: `flock`, временный файл 0600 в том же каталоге + `rename`, обход пути от `/` через `O_NOFOLLOW`,
   отказ на symlink/hardlink, `.ssh` 0700, владелец — рабочий пользователь при запуске от root, пересчёт, если файл
   параллельно дописал кто-то ещё (`>>` мастера). Все файлы секретов проверяются (0600) **до** выдачи ключа.
2. **enc1** с `--master-password-stdin` — точно по соглашению: PBKDF2-SHA256 → 64 байта (AES | HMAC), AES-256-CBC+PKCS7,
   HMAC-SHA256 над iv‖ct, `check` = enc1(`remoteagents`), 200000 итераций, случайные salt (16 байт) и iv на каждое значение.
   Пароль — одна строка stdin (CRLF и BOM отбрасываются), из терминала — скрытый ввод дважды; нигде не сохраняется.
   **Выбор библиотеки:** `python3 -c 'import cryptography'` — есть (41.0.7, пакет `python3-cryptography` Ubuntu).
   PBKDF2/HMAC — stdlib, AES-CBC — `cryptography` (своей реализации AES нет, §2). Вызов `openssl enc` отвергнут:
   ключ пришлось бы передавать в argv (виден в `ps`). Если пакета нет — понятный отказ только для мастер-пароля;
   выдача без пароля работает.
   **Тестовый вектор** — в `docs/CONFIG-SERVER.md` (пароль, salt, iv, оба ключа, `check` и многострочный секрет);
   совпадение проверено тремя реализациями: Python, OpenSSL CLI и .NET (`Rfc2898DeriveBytes`+`Aes`+`HMACSHA256`).
3. **`config list`** (`--json`): id, название, создан, состояние (действует / отозван / ключа нет в authorized_keys),
   последний вход — по отпечатку из строк sshd `Accepted publickey` (journalctl при root/adm/systemd-journal или файлы
   `authLog`); журнал недоступен → честно «неизвестно», доступен, но строк нет → «нет в журнале».
   **`config revoke <id>`** удаляет только строки `ra-config:<id>`; если тот же ключ записан ещё под другой меткой —
   строки остаются и печатается предупреждение, что по ним доступ сохраняется. Честно в выводе: открытые SSH-сессии
   не обрываются. **`config devices`** — компьютеры с названиями из реестра моста.
4. **Название компьютера**: `server_node_catalog.py` — `device_name()` очищает `deviceName` (только печатаемые, без
   переводов строк и невидимых `‮`, ≤ 80, пусто → `hostId`); регистрация управления (`Bridge`, `controlOnly`)
   переименовывает все записи этого `hostId`, а передача проекта (знает только `MachineName`) берёт имя из записи
   управления. `codex-windows-bridge.py` (`windows_devices`) — только имя: очищенное `deviceName`, для старых записей
   без поля — `hostId` (раньше был бы `KeyError`). Откуда имя берётся сейчас: `Start-WindowsControl.ps1` шлёт
   `$env:COMPUTERNAME` в `CONTROL_DATA` → `server-control.sh` → `register` (см. «Что нужно»).
5. **Автообновление** (бывший `invite sync`): `remoteagents config sync` и каждый `export` публикуют
   `~рабочего/.config/remoteagents/config-sync.json` (0600): `{kind: "remoteagents-config-sync", schema, generatedUtc,
   revision, config}`, где `config` — частичный конфиг того же формата (`server` без `key`, `vpn` без `enabled`, секреты
   VPN/переходов открытым текстом). Без изменений файл не переписывается. Формат, правила клиента и соответствие старому
   `invite-settings.json` — `docs/CONFIG-SERVER.md`, раздел «Автообновление».
6. **Удалено**: `server/invite.py` (create/list/revoke/refresh/enroll/devices/revoke-device/publish/receive/serve),
   `server/invite_overlay.py`, `server/install-invite.sh`, `server/invite-config.{example,schema}.json`,
   `server/tests/test_invite{,_refresh,_security}.py` — вместе с ними `ra-enroll`, одноразовый пропуск, sudo-скрипт и sudoers,
   overlay EXE, одноразовые ссылки. `server/remoteagents` теперь `remoteagents config …` (работает и через symlink в
   `/usr/local/bin`), `remoteagents invite` → код 2. В `docs/INVITE.md` добавлена пометка «устарело» сверху.
7. **`server/tests/run.sh`**: лимит 60 с на тест, список тестов читается заранее (`mapfile`), каждый тест получает
   `stdin=/dev/null`. Найдена и исправлена старая ошибка: дочерний `ssh` в тесте читал stdin цикла и «съедал» оставшиеся
   тесты — прогон заканчивался с кодом 0 после 24 из 64 тестов. Теперь в конце печатается число прошедших.

## Файлы

- новые: `server/remoteagents_config.py`, `server/config-export.schema.json`, `server/config-export.example.json`,
  `server/tests/test_config_export.py`, `docs/CONFIG-SERVER.md`, `docs/CONFIG-REPORT-B.md`;
- изменены: `server/remoteagents`, `server/tests/run.sh`, `server_node_catalog.py`, `codex-windows-bridge.py`
  (только `deviceName` в `windows_devices`), `docs/INVITE.md` (пометка сверху);
- удалены: перечислены в п. 6.

## Проверки

- `timeout 120 bash server/tests/run.sh` → **64 теста, все прошли, 29 с** (17 новых в `test_config_export.py` +
  close_port_leak 8, lan_vpn 25, proxy_out 14).
- Новые тесты: выдача → строка `ra-config:<id> <название>` = открытый ключ закрытого из конфига (`ssh-keygen -y`), 0600,
  `.ssh` 0700, прежняя строка без перевода строки сохранена, временных файлов нет; новый файл и каталог `.ssh`;
  повторная выдача — новый id и ключ; 4 параллельные выдачи — 4 строки; revoke — только своя строка (тот же ключ под
  `ra-device:…`, комментарий, строка с `restrict` остаются), предупреждение, повторный отзыв, неизвестный/кривой id;
  list — порядок, «неизвестно» без журнала, время последнего входа из журнала (ISO и syslog), «нет в журнале», «отозван»;
  enc1 — все значения зашифрованы, CRLF-пароль, неверный пароль и подмена байта → отказ; вектор = OpenSSL; утечки — 27
  строк секретов (ключи, канал, узел, мастер-пароль) не встречаются в stderr, журнале событий, записях и `list`;
  маршруты direct/proxy/hop (ключ+пароль) и VPN первым (канал, узел, переход каталога) → разделы и имена секретов,
  `--vpn off`, файл секрета 0644 → отказ без изменения authorized_keys; отказы: плохие названия, настройки 0666,
  symlink authorized_keys и `.ssh`, существующий `--output`; `--output` 0600; запуск «от root» (geteuid/fchown
  подменены) — `.ssh` и файл отданы рабочему пользователю; sync — 0600, без `server.key`/`vpn.enabled`, ревизия
  стабильна и меняется при смене адреса/ключей; имена — очистка, распространение, MachineName не перетирает, старые
  записи без поля, `windows_devices` и `config devices`; обёртка и отсутствие остатков invite (grep).
- **Настоящий sshd** (loopback, свой порт): выдача с мастер-паролем → расшифровка → вход ключом из конфига со строгой
  проверкой ключа хоста из `server.hostKeys` — **1,1 с от выдачи до успешного входа**; `list` находит вход в журнале
  этого sshd по отпечатку; после `revoke` — `Permission denied`.
- Тестовый вектор enc1: Python = OpenSSL (`kdf PBKDF2`, `enc -aes-256-cbc`) = .NET 10 (`Rfc2898DeriveBytes(SHA256)`,
  разовая проверка вне репозитория).
- Изменения реестра/моста: корневые `test-windows-control.py` (11), `test-multi-node.py` (8),
  `test-agent-instructions.py` (4), `test-windows-bridge.py` (6, 3 пропущены как и раньше) — проходят.

## Что нужно от других потоков

**A (формат, `ConfigBundle`)** — схема `config.paste.schema.json` должна принимать то, что выдаёт сервер:
- `vpn.bootstrap.catalog` (публичный каталог связи, формат `server-transport-catalog.py`) и
  `vpn.bootstrap.hops: {<имя>: {host, port, user, key: {secret}}}`; ключи `vpn.bootstrap.entries` — имена из каталога
  (`[A-Za-z0-9][A-Za-z0-9_-]{0,47}`, возможны заглавные), имена секретов при этом в нижнем регистре: `vpn-entry-<имя>`, `vpn-hop-<имя>`;
- `server` без `rootPassword`; hop-маршрут с `key` и/или `password` (секреты `hop-<имя>-key` / `hop-<имя>-password`);
- `disk` без `base` (только `folders`), `happier` без `key` (`mode`, `label`, `serverUrl`, `webappUrl`);
- значения `vpn-channel`, `vpn-entry-*` — JSON-**текст**; `server-key`, `*-key` — текст закрытого ключа OpenSSH с LF;
- `secrets.kdf.iterations` от сервера — 200000; проверить свою реализацию тем же вектором из `docs/CONFIG-SERVER.md`;
- частичный конфиг из `config-sync.json` разбирается тем же парсером (нет `device`, `server.key`, `vpn.enabled`).

**C (движок)**:
- клиент автообновления: путь `$HOME/.config/remoteagents/config-sync.json`, новый формат и правила — `docs/CONFIG-SERVER.md`
  («Автообновление», таблица соответствия старому `invite-settings.json`); сейчас `build/Wizard.Refresh.ps1` читает
  `invite-settings.json` с `type: settings` — переделать (имена функций `*Invite*` тоже);
- `SecretVault.Materialize`/Bootstrap: `vpn-channel` → `secrets/channel.json`, `vpn-entry-*` → `secrets/entries/<имя>.json`,
  `vpn-hop-*`/`hop-*-key` → файлы ключей переходов (как делал `Set-WizardRefreshSnapshot`);
- **`sing-box.exe` больше не приезжает с сервером** (раньше лежал в overlay EXE): для VPN первым он должен быть в бандле/
  компонентах самого EXE (`build/components-vpn.json`), иначе VPN первым до первого SSH невозможен;
- `Bridge {deviceName}` должен дойти до `Start-WindowsControl.ps1`: сейчас там `deviceName=$env:COMPUTERNAME`
  (`New-ControlPayload`). Файл корневой и ни за кем в соглашении не закреплён — координатору решить, кто меняет
  (предложение: параметр `-DeviceName`, по умолчанию `$env:COMPUTERNAME`);
- клиентские тесты, которые запускались из удалённых `server/tests/test_invite*.py` (`app/launcher/tests/test-invite*.ps1`,
  `test-refresh.ps1`), теперь без серверной обвязки — перенести на новый формат со своими фикстурами или удалить.

**D (окно)**: смена названия в настройках → повторить действие `Bridge` (имя уходит на сервер только с регистрацией);
вывод `config export` (stdout — сам конфиг, stderr — сообщения) можно вставлять без правки.

**Координатор**: удалить/переписать `docs/INVITE.md`, `docs/TASK-INVITE.md`, `docs/INVITE-*REPORT.md` после слияния
(я только пометил INVITE.md как устаревший, чтобы не конфликтовать с другими потоками).

## Что не проверено

- Живой сервер: настоящий запуск от root (владелец/права проверены подменой `geteuid`/`fchown`), настройки в `/etc`,
  journalctl с правами root/adm (проверен разбор строк sshd из файла и журнал своего sshd, но не системный журнал).
- Ветка «нет `python3-cryptography`» — только по коду (сообщение), не на машине без пакета; скрытый ввод из терминала.
- C#-реализация потока A — только тем же вектором на .NET 10 вне репозитория, не кодом A.
- Имя компьютера с настоящего моста Windows (`Start-WindowsControl.ps1` ещё шлёт `COMPUTERNAME`).
- Клиентская часть автообновления (поток C) — формат описан, сквозной проверки «сервер → компьютер» нет.
