# Сервер: выдача конфигов, отзыв, автообновление

Решение владельца: приглашений нет. **Передали конфиг — есть доступ, не передали — нет.**
Сервер выдаёт полный конфиг командой; в каждом выданном конфиге свой ключ ed25519, его можно отозвать.
Формат конфига — `docs/CONFIG-CONTRACT.md`, раздел 1. Код — `server/remoteagents_config.py`, тесты — `server/tests/test_config_export.py`.

## Подготовка (один раз)

1. Исходники лежат на сервере, например в `/opt/remoteagents` (каталог и предки — root, без записи другим).
   Команда: `/opt/remoteagents/server/remoteagents config …`; можно сделать
   `ln -s /opt/remoteagents/server/remoteagents /usr/local/bin/remoteagents`.
   Отдельного установщика, служебного пользователя, sudoers и служб нет.
2. Настройки выдачи — `/etc/remoteagents/config-export.json` (если его нет и команду запускает не root —
   `~/.config/remoteagents/config-export.json`; явно — `--config`). Поля — [схема](../server/config-export.schema.json),
   [пример](../server/config-export.example.json). Файл и все каталоги над ним принадлежат root или запускающему,
   без записи группе/остальным (иначе отказ).
   - обязательно: `serverAddress`, `serverPort`, `workerUser` (рабочий пользователь, не root);
   - `hostKeys` (`тип base64`) — или `hostKeyFiles`; по умолчанию читаются `/etc/ssh/ssh_host_{ed25519,ecdsa,rsa}_key.pub`
     этого же сервера (локальный файл — доверенный источник; из сети ключи не берутся);
   - `routes` — порядок маршрутов (по умолчанию только `direct`): `proxy {type, server, port}`,
     `hop {name, host, port, user, hostKey, keyFile|passwordFile}`. Секреты переходов — только файлами 0600;
   - `catalogFile` — общий каталог связи (по умолчанию `~рабочего/.config/remoteagents/transport-catalog.json`,
     тот же, что `transport/server-transport-catalog.py` / `Get-WizardCatalog`), проверяется той же схемой;
   - `vpnBootstrap` — «VPN первым» (как было в invite): `channelFile` (JSON канала, 0600), `entryFiles`
     (имя узла каталога → его `client.json`, 0600, нужны все включённые), `hops` (имя перехода каталога →
     `host, port, user, keyFile`), `vpn {checkUrl, dnsServer}` — свой HTTPS-адрес проверки и DNS;
   - `happier {account, serverUrl, webappUrl}` — необязательно;
   - необязательные пути: `workerAuthorizedKeys`, `stateDir`, `syncFile`, `nodeCatalog`, `authLog`.
3. Запускать от root (читает секреты из `/root/...`, пишет в authorized_keys рабочего пользователя с его владельцем)
   или от самого рабочего пользователя, если все файлы ему доступны.

## `remoteagents config export --name "<название>"`

```sh
remoteagents config export --name "Ноутбук сына" --master-password-stdin --output /root/laptop.json
# необязательно: --vpn on|off (по умолчанию on, если есть vpnBootstrap), --happier same|new:Имя (по умолчанию same),
#                --folders "Проект,Проект/docs"
```

Что происходит:

1. Проверяются настройки и все файлы секретов (права 0600) — **до** создания ключа: при ошибке ничего не меняется.
2. `ssh-keygen` создаёт новую пару ed25519 (без пароля, во временном каталоге 0700, затем удаляется).
3. Под `flock` (`<stateDir>/config.lock`) открытая часть дописывается в authorized_keys рабочего пользователя строкой
   `ssh-ed25519 AAAA… ra-config:<id> <название>`. Запись атомарная: временный файл в том же каталоге (0600, владелец —
   рабочий пользователь) → `rename`. Каталоги проходятся от `/` через `O_NOFOLLOW` (symlink и hardlink — отказ),
   `.ssh` создаётся 0700. Если файл одновременно дописал кто-то ещё (например `>>` мастера), запись пересчитывается.
4. `<id>` — 16 шестнадцатеричных символов, новый на каждую выдачу; запись `<stateDir>/<id>.json` (название, время,
   отпечаток, открытый ключ) и строка журнала `<stateDir>/config-events.log` — только код и id, без названий и секретов.
5. Полный конфиг печатается в stdout (или в `--output`: новый файл 0600, существующий не перезаписывается).
   В stderr — только id, метка и предупреждения. Секреты не попадают ни в stderr, ни в журнал (проверено тестом).
6. Обновляется снимок автообновления (см. ниже).

Без `--master-password-stdin` секреты в конфиге открытым текстом — stderr предупреждает, что конфиг передаётся как пароль.
С `--master-password-stdin` пароль читается одной строкой из stdin (`\r\n`/`\n` в конце и BOM отбрасываются; из терминала —
скрытый ввод дважды). Мастер-пароль нигде не сохраняется. Для шифрования нужен пакет `python3-cryptography`
(PBKDF2 и HMAC — из стандартной библиотеки, AES-256-CBC — из `cryptography`); если его нет — понятный отказ,
экспорт без пароля работает и без него.

### Что внутри выданного конфига

```json
{
  "kind": "remoteagents-config", "schema": 1,
  "device": { "name": "Ноутбук сына" },
  "server": {
    "address": "203.0.113.10", "port": 22, "login": "workuser",
    "hostKeys": ["ssh-ed25519 AAAA…"],
    "routes": [ {"kind": "direct"},
                {"kind": "proxy", "proxy": {"type": "socks", "server": "127.0.0.1", "port": 10808}},
                {"kind": "hop", "hop": {"host": "relay.example.invalid", "port": 22, "user": "relayuser", "hostKey": "ssh-ed25519 AAAA…",
                                        "key": {"secret": "hop-relay-key"}}} ],
    "key": { "secret": "server-key" }
  },
  "vpn": { "enabled": true, "checkUrl": "https://check.example.invalid/", "dnsServer": "192.0.2.53",
           "bootstrap": { "catalog": { "schema": 1, "entries": […], "hops": […], "relays": […], "cdn": […] },
                          "channel": {"secret": "vpn-channel"},
                          "entries": {"Entry1": {"secret": "vpn-entry-entry1"}},
                          "hops": {"vhop": {"host": "…", "port": 22, "user": "…", "key": {"secret": "vpn-hop-vhop"}}} } },
  "happier": { "mode": "same", "label": "Основной", "serverUrl": "…", "webappUrl": "…" },
  "bridge":  { "enabled": true, "allowShell": false },
  "disk":    { "folders": ["Проект", "Проект/docs"] },
  "secrets": { "protected": "master-password", "kdf": {"name": "pbkdf2-sha256", "iterations": 200000, "salt": "…"},
               "check": "enc1:…", "server-key": "enc1:…", "vpn-channel": "enc1:…", … }
}
```

| Секрет | Значение (открытый текст до шифрования) |
|---|---|
| `server-key` | закрытый ключ OpenSSH ed25519 этого конфига (текст, LF), комментарий ключа `ra-config:<id>` |
| `hop-<имя>-key`, `hop-<имя>-password` | закрытый ключ / пароль перехода из `routes` (имя — `hop.name` или номер) |
| `vpn-channel` | JSON-текст канала сервера (`channelFile`) |
| `vpn-entry-<имя в нижнем регистре>` | JSON-текст `client.json` узла каталога (ключ в `entries` — имя как в каталоге) |
| `vpn-hop-<имя в нижнем регистре>` | закрытый ключ SSH-перехода каталога для VPN первым |

`rootPassword` не выдаётся: компьютер входит ключом конфига. Ключ Happier не выдаётся (как и в invite: аккаунт
настраивает действие `Account` по SSH). Бинарник `sing-box.exe` в текстовый конфиг не кладётся (см. `docs/CONFIG-REPORT-B.md`, «Что нужно от других потоков»).
`disk.base` не задаётся — компьютер берёт свой (`Get-DiskBase`). `--vpn off` → `vpn.enabled=false`, без канала и узлов.

### Тестовый вектор enc1 (общий для Python и C#)

Формат — `docs/CONFIG-CONTRACT.md`, раздел 1: `enc1:` + base64( iv[16] ‖ AES-256-CBC/PKCS7 ‖ HMAC-SHA256[32] над iv‖ct ),
64 байта = PBKDF2-SHA256(UTF-8 мастер-пароля без нормализации, salt, iterations): первые 32 — AES, вторые 32 — HMAC.

| Поле | Значение |
|---|---|
| мастер-пароль | `Мастер-пароль 1` (UTF-8, 28 байт) |
| `kdf.salt` | `AAECAwQFBgcICQoLDA0ODw==` (байты 00…0f) |
| `kdf.iterations` | `200000` |
| iv | байты 10…1f |
| ключ AES (hex) | `4a705d00d0b0eb61e464aac6aa0712bcb93c88417d7db998d56d72cfbb87cb6e` |
| ключ HMAC (hex) | `23756d57411519ab4fd2f3cb1f4ce7d7594d96e01dbc6bafa100fc102eaf6b1b` |
| `check` = enc1(`remoteagents`) | `enc1:EBESExQVFhcYGRobHB0eH5S/AYvjmvqbyp4eatsIP0ESDucdw0ufuFBNWskJNZdj/a/PyROkWqohaJO+d8dnCA==` |
| enc1(`секрет\nвторая строка`) | `enc1:EBESExQVFhcYGRobHB0eH9EATN4mI2yZF1iffFippgsKu5D1MyvAG2NfKVaGcnHzvCO5vWsIX2yfsu90ejzi8negWZF8qpwxkbFOMwPwBMnei8w8zX8GwmtQ4CNs3ZfL` |

Проверено: Python (`hashlib` + `cryptography`), OpenSSL CLI (`openssl kdf PBKDF2`, `openssl enc -aes-256-cbc`) и .NET
(`Rfc2898DeriveBytes(…, SHA256)` + `Aes` CBC/PKCS7 + `HMACSHA256`, есть и в .NET Framework 4.7.2+) дают те же строки.
Расшифровка: сначала HMAC (сравнение за постоянное время), потом AES; неверный пароль/подмена → отказ.

## `config list`, `config revoke <id>`, `config devices`

- `config list` (`--json` — по строке JSON): id, название, создан, состояние (`действует` / `отозван` /
  `ключа нет в authorized_keys` — удалили вручную), последний вход. Последний вход — по отпечатку ключа из
  строк sshd `Accepted publickey for <рабочий> … SHA256:…`: `journalctl -t sshd -t sshd-session` (нужен root или
  группа `adm`/`systemd-journal`) либо файлы `authLog`. Нет доступа к журналу → **«неизвестно»**; доступ есть, но строк
  нет (журнал короче срока или входа не было) → «нет в журнале».
- `config revoke <id>` удаляет из authorized_keys **только строки с меткой `ra-config:<id>`**; остальные строки
  (в том числе тот же ключ, записанный вручную под другой меткой) сохраняются, и об этом печатается предупреждение —
  по такой строке доступ остаётся. Запись помечается `revokedUtc`. Повторный отзыв безвреден.
  **Честно: открытые SSH-сессии этим ключом не обрываются** (и туннель моста работает до разрыва); новые входы запрещены.
- `config devices` — компьютеры из реестра моста (`~рабочего/.local/share/remote-agents-nodes`): `hostId`, название,
  проекты. Без живой проверки — она в `windows_devices`. Связи «компьютер ↔ id конфига» в реестре нет.

## Название компьютера → реестр → `windows_devices`

`device.name` из конфига → действие `Bridge {…, deviceName}` → `Start-WindowsControl.ps1` кладёт `deviceName` в
`CONTROL_DATA` → `server-control.sh` → `server_node_catalog.register`. Сейчас `Start-WindowsControl.ps1` отправляет
`$env:COMPUTERNAME` — это надо заменить (см. ниже). На сервере (`server_node_catalog.py`):

- название очищается: только печатаемые символы (переводы строк, управляющие и невидимые `‮` и т. п. убираются),
  пробелы схлопываются, до 80 символов; пусто → `hostId`;
- название принадлежит компьютеру: регистрация управления (`controlOnly`, т. е. `Bridge`) переименовывает все записи
  этого `hostId`, а передача проекта (`Agent.Handoff.ps1`, знает только `MachineName`) берёт имя из записи управления;
- `windows_devices` (`codex-windows-bridge.py`) показывает очищенное `deviceName`, для старых записей без поля — `hostId`.

## Автообновление (бывший `invite sync`) — для потока C

Сервер публикует снимок `~рабочего/.config/remoteagents/config-sync.json` (0600, владелец — рабочий пользователь) при
каждом `config export` и командой `remoteagents config sync` (после изменения адреса, ключей хоста, маршрутов, каталога,
снимков VPN). Если ничего не изменилось, файл не переписывается (`generatedUtc` прежний).

```json
{ "kind": "remoteagents-config-sync", "schema": 1, "generatedUtc": "2026-11-12T10:00:00+00:00",
  "revision": "<sha256 от config>",
  "config": { "kind": "remoteagents-config", "schema": 1,
              "server": { "address", "port", "login", "hostKeys", "routes" },
              "vpn": { "checkUrl", "dnsServer", "bootstrap": { "catalog", "channel", "entries", "hops" } },
              "secrets": { "vpn-channel": "…", "vpn-entry-…": "…", "vpn-hop-…": "…", "hop-…-key": "…" } } }
```

`config` — частичный конфиг того же формата (раздел 1 соглашения), секреты **открытым текстом** (файл доступен только
рабочему пользователю, читается его же ключом). Правила для клиента:

- забирать раз в 5 минут, при запуске и при восстановлении связи **только своим ключом через SSH с уже закреплённым
  ключом хоста**: `cat "$HOME/.config/remoteagents/config-sync.json"` (через местный транспорт, затем сохранённый маршрут,
  как `Get-WizardInviteSettings`). Без keyscan, accept-new и HTTP. Ответ > 1 МиБ, не тот `kind`/`schema` → отказ;
  `\r` убирать перед разбором (§6б);
- `revision` совпал с применённым → ничего не делать;
- отсутствующие поля не трогать: в снимке нет `server.key` (ключ компьютера остаётся свой), нет `vpn.enabled`
  (вкл/выкл VPN — выбор компьютера), нет `device`, `happier`, `bridge`, `disk`, `proxyOut`, `lan`;
- `server.login` не может смениться — отказ; новые `hostKeys`/адрес принимаются, потому что пришли по уже доверенному
  SSH (смена VPS: сначала добавить новый путь, `config sync`, дождаться компьютеров, потом убрать старый и снова `config sync`);
- применять через тот же движок с проверкой нового пути до замены и независимым откатом (как `Update-WizardInviteSettings`);
- живой каталог связи по-прежнему авторитетен: `python3 - < transport/server-transport-catalog.py` после входа; каталог
  в снимке — то, что нужно до первого SSH.

Соответствие старому `invite-settings.json` (`type: settings`): `serverAddress/serverPort/workerUser/hostKeys` →
`config.server.address/port/login/hostKeys`; `routes[].proxy.host` → `server`; `routes[].hop.{ssh,privateKey,password}` →
`hop.{host,port,user}` + `key/password` → `secrets`; `bootstrap.catalog` → `vpn.bootstrap.catalog`;
`bootstrap.channel/entries` (объекты) → `secrets["vpn-channel"]`, `secrets["vpn-entry-…"]` (JSON-текст);
`bootstrap.hops[].privateKey` → `secrets["vpn-hop-…"]`; `bootstrap.vpn.{checkUrl,dnsServer}` → `vpn.{checkUrl,dnsServer}`;
`vpn: on/off` → не передаётся.

## Что удалено

`server/invite.py` (create/list/revoke/refresh/enroll/devices/revoke-device/publish/receive/serve), `server/invite_overlay.py`,
`server/install-invite.sh`, `server/invite-config.{example,schema}.json`, тесты `server/tests/test_invite*.py`.
Вместе с ними ушли служебный пользователь `ra-enroll`, одноразовый пропуск, sudo-скрипт регистрации и его sudoers,
нагрузка в конце EXE, публикация одноразовых ссылок. Перенесено: «VPN первым» (`vpnBootstrap`), маршруты и пароли hop
по маршрутам, автообновление, список компьютеров, безопасная запись authorized_keys (O_NOFOLLOW, hardlink, права, flock).
