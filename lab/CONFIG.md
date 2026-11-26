# Конфиг «remoteagents-2» (для LLM на сервере)

Один JSON-файл, который человек вставляет в программу. Секреты внутри зашифрованы одним паролем (`enc1:`).
Программа сама раскладывает конфиг по файлам; своего конфига нет у ПК владельца — там работает прежний путь.

## Пример (значения выдуманные)
```json
{
  "format": "remoteagents-2",
  "name": "ПК-Иван",
  "server": {"host": "203.0.113.10", "port": 22, "user": "remoteagents",
             "hostKey": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample", "key": "-----BEGIN OPENSSH PRIVATE KEY-----\nexample\n-----END OPENSSH PRIVATE KEY-----"},
  "paths": {"entries": ["msk-1"], "relays": [], "hops": [], "cdn": [], "wsEntries": [],
            "secrets": {"msk-1": "{\"server\":\"198.51.100.5\",\"secrets\":{}}"},
            "channel": "{\"outbounds\":[]}"},
  "control": true,
  "autostart": true,
  "vpn": {"mode": "off", "bridges": [], "direct": {"domains": []}},
  "lan": [{"name": "Клиника", "host": "192.0.2.7", "port": 1194,
           "share": {"enabled": true, "subnets": ["192.168.87.0/24"], "domains": ["eastclinic.local"]}}],
  "tun": {"enabled": true},
  "happier": {"localWeb": {"enabled": true, "port": 47831, "serverPort": 47831}},
  "disk": {"home": "%LOCALAPPDATA%\\RemoteDisk"}
}
```
В примере секреты (`server.key`, `paths.channel`, `paths.secrets.*`) записаны открытым текстом — так их пишет LLM.
Команда `seal` заменит их на `enc1:…` и добавит `kdf` и `check`. Для `check` без пароля годится только запечатанный файл.

## Поля
| Поле | Смысл | Обязательно | Умолчание |
|---|---|---|---|
| `format` | всегда `remoteagents-2` | да | — |
| `name` | имя компьютера человека (показывается на странице) | да | — |
| `server.host` | адрес сервера канала | да | — |
| `server.port` | порт SSH | нет | 22 |
| `server.user` | логин канала на сервере | да | — |
| `server.hostKey` | ключ сервера одной строкой `ssh-ed25519 AAAA…` | да | — |
| `server.key` | закрытый ключ ПК (OpenSSH, текст) — секрет | да | — |
| `paths.entries` | имена узлов входа; для каждого нужен секрет в `paths.secrets` | одно из `entries`/`channel` | `[]` |
| `paths.relays`, `paths.hops`, `paths.cdn`, `paths.wsEntries` | дополнительные пути: объекты, как в `transport.*` программы (`name`, `host`, `port`, …) | нет | `[]` |
| `paths.secrets` | `{имя узла: JSON файла узла}` — секреты узлов входа | если есть `entries` | `{}` |
| `paths.channel` | JSON канала sing-box (`outbounds`) — секрет | одно из `entries`/`channel` | нет |
| `control` | разрешено ли управление компьютером | нет | `false` |
| `autostart` | запускать при входе в Windows | нет | `false` |
| `vpn.mode` | режим VPN: `off`, `auto`, `only` (другое отвергается; пишется в состояние при применении); остальные поля `vpn` (`bridges`, `direct.domains`) читает код VPN | нет | `off` |
| `lan` | сети ЛВС: `name`, `host`, `port`, `share{enabled, subnets, domains}` | нет | нет |
| `tun` | `{"enabled": true}`: по умолчанию TUN выключен, включается только так | нет | выключен |
| `happier.localWeb` | `{enabled, port, serverPort}`: `enabled: true` включает проброс Happier, `port` на ПК, `serverPort` на сервере; без `enabled` и `serverPort` проброс не создаётся | нет | нет (47831 / 47831) |
| `forwards`, `lanProxy` | проброс портов и порт прокси ЛВС (как в конфиге Программы) | нет | по умолчанию кода |
| `disk.home` | папка Диска | нет | `%LOCALAPPDATA%\RemoteDisk` |
| `disk.syncPort` | порт синхронизации на стороне ПК (серверный порт берётся из входа sync в `paths.channel`) | нет | 22001 |
| `kdf`, `check` | параметры пароля и проверка пароля; ставит `seal` | да в готовом файле | — |

Ограничения: файл не больше 1 МБ; имена узлов — буквы, цифры, `_`, `-`, до 48 знаков.

## Как выпустить конфиг человеку
Выполнять на сервере, секреты не печатать в чат. Сначала: `umask 077; d=$(mktemp -d)` — все временные файлы (ключ `ra-<имя>`, `<имя>.json`, `<имя>.sealed.json`) только в `$d`; в конце `rm -rf "$d"`. Что включить (`control`, `vpn.mode`, `lan`, `tun`, `happier`, `autostart`), выбирает владелец.

1. **Ключ ПК** (отдельный для каждого человека):
   `ssh-keygen -t ed25519 -N '' -C ra-pc:<имя> -f $d/ra-<имя>`
   Открытую часть дописать одной строкой: `cat $d/ra-<имя>.pub >> ~remoteagents/.ssh/authorized_keys` (пользователь канала, он же `server.user`). Комментарий `ra-pc:<имя>` нужен, чтобы потом отозвать ключ: удалить эту строку. Закрытая часть (`$d/ra-<имя>`) идёт в `server.key`.
2. **hostKey**: `cat /etc/ssh/ssh_host_ed25519_key.pub | cut -d' ' -f1,2`. Адрес и порт — из `~/.config/remoteagents/config-export.json` (`serverAddress`, `serverPort`, `workerUser`).
3. **Пути канала**:
   - `paths.channel` — готовый файл канала, который сервер выдаёт ПК: `~/.config/remoteagents/vpn-channel.json` (путь — `vpnBootstrap.channelFile` в `~/.config/remoteagents/config-export.json`; читает `vpn_section` в `server/remoteagents_config.py`). Для канала Диска (прямой VLESS + ssh/sync-входы) — вывод `bash ~/.local/share/remote-disk/server-disk.sh channel-config <base64 JSON {"server":"<адрес>","sshPort":22}>` (функция `channel` в `disk/server-disk.sh`).
   - `paths.entries` и `paths.secrets` — узлы входа из каталога `~/.config/remoteagents/transport-catalog.json` (`catalogFile` в `config-export.json`); для каждого включённого узла файл берётся из `vpnBootstrap.entryFiles[<имя>]`, его содержимое идёт в `paths.secrets.<имя>` (в `entries` — само имя). Если `entryFiles` пуст, узлов входа нет: оставить только `paths.channel`.
   - `paths.hops`: переходы из каталога (`hops`), данные ключа — `vpnBootstrap.hops[<имя>]`; ключ перехода в конфиг не класть без решения владельца.
4. Собрать открытый файл `$d/<имя>.json` по схеме выше и запечатать (пароль — из переменной, не из командной строки):
   `cd ~/Disk/AiServerAutoSettings/lab && RA_PASSWORD=… python3 -m ralab.v2config seal $d/<имя>.json $d/<имя>.sealed.json`
   Имя компьютера обязательно: `--name Office-Laptop` (латиница/цифры/._-, до 64 знаков, уникально; список выданных — `~/.local/share/ra-lab/issued-names.json`). В терминале без `--name` спросит сам и предложит транслитерацию кириллицы; без терминала — ошибка.
   Проверить: `python3 -m ralab.v2config check $d/<имя>.sealed.json` (код 0 — готово).
5. **Выдать**: `python3 ~/Disk/AiServerAutoSettings/server/oneshot_link.py $d/<имя>.sealed.json --host <публичный адрес сервера>` — владелец получает в чат только ссылку, пароль передаётся человеку отдельно. Ссылка сама удалит файл после скачивания или по сроку: открытые `$d/ra-<имя>*` и `$d/<имя>.json` удалить сразу, а `rm -rf "$d"` — когда ссылка отработала.

## Что делает программа с конфигом
Раскладывает в папке данных `private\v2\`: `id_key`, `known_hosts`, `ssh-profile.json`, `channel.json`, `secrets\entries\<имя>.json`; сам конфиг хранится в `config\active.json`, прежний — в `config\prev.json`. «Вернуть прежний конфиг» возвращает его; если прежнего нет, конфиг убирается. При возврате выбор VPN и управления остаётся текущим.

## Диск (`disk`)

При активном конфиге v2 и поднятом канале новый Диск подключается сам: программа создаёт
личность ПК, регистрирует её на сервере и запускает синхронизацию. Без конфига v2 прежнее
поведение сохраняется. Существующий Диск старой Программы без `join.json` не регистрируется
заново, его `server.txt` не перезаписывается.

| Поле | Смысл | Умолчание |
|---|---|---|
| `enabled` | Автоматически подключать новый Диск; `false` отключает автоподключение | `true` |
| `home` | Каталог служебных файлов Диска | `%LOCALAPPDATA%\RemoteDisk` |
| `base` | Каталог для скачиваемых папок | `%USERPROFILE%\Disk` |
| `folders` | Имена проектов, которые нужно сразу скачать | `[]` |

Новому человеку ничего не скачивается автоматически: `folders` по умолчанию пуст.
Папки сервера только видны в Проводнике; человек подключает нужные через меню Диска.
Автоматическое скачивание включается явным списком, например:

```json
{"disk": {"enabled": true, "folders": ["Проект"]}}
```

Имена для `folders` берутся из git-проектов верхнего уровня `~/Disk/<имя>` на сервере:

```bash
for d in ~/Disk/*/; do [ "$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" = "${d%/}" ] && basename "$d"; done
```

**Для LLM и владельца:** сервер предлагает каждому подключённому ПК **все** проекты из
`~/Disk` — так работает `server-disk.sh reconcile`. Выбор `folders` ограничивает только
автоматическое скачивание, а не список предлагаемых проектов или права доступа к ним.
Без явного выбора оставляйте `folders: []`.

Для подключения Диска вручную на сервере ничего делать не нужно: при первом подключении
ПК сам вызывает `server-disk.sh add-device` своим ключом.
