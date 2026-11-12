# Задача CHANNEL: «канал первым» — подключение через промежуточный сервер без TUN

12.11.2026, решение владельца. Исполнять ровно как написано; ничего сверх плана не придумывать. Нашли расхождение
с кодом — сделать минимально и записать в отчёт. Правила: `docs/CONSTITUTION.md` (§1 без вшитых значений, §2 минимум своего
кода, §3 секреты отдельно, §5 честный статус, §6б CRLF, §6в PS 5.1). Код — для Windows PowerShell 5.1 и .NET 4.8.

## Почему
Компьютер «Комп» владельца работает только через мобильный интернет. Журнал с Windows:
- **Прямой SSH до сервера не проходит.** TCP и баннер проходят, обмен ключами тоже, затем `SSH2_MSG_SERVICE_ACCEPT received` и `Connection timed out`. Сеть глушит SSH после рукопожатия.
- **Включён Happ (TUN).** Нынешний Bootstrap поднимает свой TUN, требует UAC и при чужом VPN отказывается работать.
- **Рабочий путь проверен.** VLESS-канал сервера через тупой TCP-ретранслятор sparfum `77.91.72.183:8443` работает: HTTPS 204 за 0,5 с, sshd за ним виден. Каталог уже содержит `relays:[{name:"sparfum",host:"77.91.72.183",port:8443}]`.

**Решение.** Раздел Bootstrap больше НЕ поднимает TUN. Вместо этого он запускает существующий демон связи
(`transport/Transport.Daemon.ps1`, sing-box от имени пользователя), который сам выбирает рабочего кандидата
(`vless-direct`, `vless-relay-<имя>` …). Затем:
- у демона появляется локальный SOCKS-вход;
- шаг «Сервер» и все дальнейшие SSH ходят через него (существующий маршрут вида `proxy`, сохраняется в ssh.conf как `ProxyCommand`);
- трей уже держит демон постоянно (`build/components.json`, компонент `transport`, `restart: always`).

## Контракт (общий для всех потоков, менять нельзя)
- **Настройка transport `channelSocksPort`:**
  - число, по умолчанию `2223`, рядом с `sshPort=2222` в `$defaults` у `Read-TransportSettings` (`transport/Transport.Common.ps1` ~195);
  - проверка диапазона — как у других портов.
- **Вход демона:** `{type:'mixed', tag:'channel-socks', listen:'127.0.0.1', listen_port:<channelSocksPort>}`.
  - Правило маршрута (первым в `route.rules`): `{inbound:['channel-socks'], action:'route-options', override_address:'127.0.0.1', override_port:<Get-TransportServerPort $profile>}`.
  - Затем `{inbound:['channel-socks'], outbound:'active'}`. Тот же смысл, что у существующего входа `ssh` (2222 → 127.0.0.1:порт sshd на сервере).
  - Если в sing-box 1.14 `override_*` в `route-options` недоступен — сделать эквивалент и записать в отчёт.
- **Признак в `config.json` → `transport.channelFirst = true`.** Его ставит только Bootstrap «канал первым».
- **Маршрут шага «Сервер», когда `transport.channelFirst` и демон отвечает:**
  - `{kind:'proxy', proxy:{type:'socks', host:'127.0.0.1', port:<channelSocksPort>}}`, заголовок `через канал`;
  - ставится ПЕРВЫМ в списке маршрутов, перед маршрутами конфига.
- **Итог действия `Bootstrap`:**
  - успех: `@{ok=$true; vpn='channel'; channel='<tag активного кандидата>'; summary='Канал до сервера поднят: <tag>'}`;
  - неуспех: `@{ok=$false; vpn='channel-failed'; summary='Канал до сервера не поднят: <причина>. Доступны обычные маршруты'}`.
  - Строки прогресса трассировки начинаются с `· ` (их видит только журнал): список кандидатов, выбранный кандидат, время.
- **Выдача конфига `remoteagents config export --vpn channel`:** раздел `vpn = {enabled:false, checkUrl, dnsServer, bootstrap:{catalog, channel:{secret:'vpn-channel'}, entries, hops}}`, секрет `vpn-channel` — как при `--vpn on`.
- **Название раздела Bootstrap в окне:** «Канал до сервера». Префикс в строке «Сервер» — `Канал: `.

## Поток A — Codex — движок PowerShell
Ветка/worktree: `app/channel-a` / `~/work/wt-channel-a`.
Свои файлы: `build/Wizard*.ps1`, `transport/Transport.Common.ps1`, `transport/Transport.Daemon.ps1`, `disk/Disk.Common.ps1`,
`app/launcher/tests/test-config-*.ps1`.

1. **`Start-WizardBootstrap`** (`build/Wizard.Bootstrap.ps1` ~142):
   - если `profile.vpn.bootstrap.channel` есть, выполнить существующую подготовку `config.transport` (строки ~150–172: profilePath, catalog groups, channelPath, `Set-WizardBootstrapHops`, `Ensure-WizardTransportBinary`), но с `channelFirst=$true` и `openSsh` по умолчанию;
   - БЕЗ: проверки чужого VPN, `Select-WizardBootstrapInternetPath`, `Set-VpnEnabled`, `Start-WizardBootstrapTun`;
   - запустить демон через `Start-WizardWorkingTransport` (`build/Wizard.Engine.ps1` ~39);
   - ждать (до 45 с, шаг 1 с), пока статус демона (`status/transport.json`, найти поле активного кандидата) не покажет рабочего кандидата и не откроется TCP `127.0.0.1:<channelSocksPort>`;
   - вернуть итог по контракту. Ранний выход `Test-WizardNetworkManaged` оставить.
   - Старые функции TUN-bootstrap не удалять, если они используются ещё где-то; неиспользуемые удалить (§2).
2. **SOCKS-вход и правило** по контракту в `New-TransportConfig` (`transport/Transport.Common.ps1` ~403–426).
3. **`Get-TransportCandidates`** (~368): не добавлять туннель `openssh-proxy`, если прокси сохранённого маршрута — `127.0.0.1:<channelSocksPort>`. Иначе петля: демон через самого себя.
4. **`Connect-WizardSnapshot`** (`build/Wizard.Bootstrap.ps1` ~29): маршрут «через канал» по контракту — первым, когда `config.transport.channelFirst` и порт отвечает. Дальше всё существующее: `Select-WizardRoute`, `Save-WizardRoute`, `routeProxyCommand`.
5. **Раздел «Связь» на первой установке** (`Set-WizardInitialNetwork`, `build/Wizard.Engine.ps1` ~56):
   - он переписывает `config.transport` и запускает демон заново. Сохранить `channelFirst`, `channelSocksPort` и `relays`;
   - выяснить, перечитывает ли работающий демон изменённый config (мьютекс на Home). Если нет — перезапуск так, чтобы SOCKS-порт пропадал минимально;
   - Bridge/Account/Disk идут параллельно и пользуются портом. Если их SSH падает из-за короткого перезапуска — один повтор через 3 с в `Invoke-WizardSsh` только для кода 255 и только при `channelFirst`;
   - записать в отчёт, что выбрано.
6. **Честная причина SSH** (`disk/Disk.Common.ps1` `Invoke-DiskProcess`): если в stderr есть `Remote protocol version`, а код 255 с `timed out`/`Connection reset`, вернуть «Сервер ответил, но сеть глушит SSH после рукопожатия — нужен обход (канал через промежуточный сервер)». Не «Нет SSH-баннера». Флаг `WizardNoBanner` в этом случае не ставить.
7. **Тесты:** обновить `app/launcher/tests/test-config-bootstrap.ps1` и родственные под новый Bootstrap: TUN не вызывается, конфликт VPN не мешает, `channelFirst` пишется, маршрут «через канал» первый. Плюс тест на п. 6. Каждый тест-файл с `timeout 60`.

## Поток B — Opus — C# окно/движок и сервер
Ветка/worktree: `app/channel-b` / `~/work/wt-channel-b`.
Свои файлы: `app/launcher/ConfigApply.cs`, `ConfigWindow.cs`, `app/launcher/tests/ConfigApplyTests.cs`,
`server/remoteagents_config.py`, `server/tests/test_config_export.py`, `docs/CONFIG-SERVER.md`, `docs/CONFIG.md`.

1. **Заголовки:**
   - `ConfigSections.Title(Bootstrap)` = «Канал до сервера»;
   - в `ConfigWindow.Report` префикс `"VPN первым: "` → `"Канал: "`;
   - сводка по умолчанию в `RunSection` (`ConfigApply.cs` ~709): «Канал до сервера поднят».
2. **«Код 0»** (`ConfigApply.cs` ~250–256): при неразборчивом выводе шага текст исключения дополнить первыми 300 символами stdout (одной строкой, маскировать подстроки `[A-Za-z0-9+/_=-]{32,}` → `<secret>`). Сам `.out` скопировать в `logs/wizard-<action>-<HHmmss>.out` перед удалением.
3. **Пустые секреты:** в строке «Конфиг принят…» перечислить имена пустых секретов (`parsed.Missing`).
4. **Поле конфига:**
   - если оно заполнено автоматически (`Ready()`: конфиг рядом с EXE или прежний профиль), при первом фокусе/вставке выделять весь текст, чтобы Ctrl+V заменял его целиком;
   - в журнал после «Конфиг принят» одной строкой: `устройство: <имя>; маршруты: <kinds>; канал первым: <имена relays/entries или «нет»>`.
5. **Сервер `--vpn channel`** по контракту (`server/remoteagents_config.py`, `vpn_section` и `common_sections`, choices `on|off|channel`):
   - тест в `server/tests/test_config_export.py`;
   - строка в `docs/CONFIG-SERVER.md`, в `docs/CONFIG.md` — описание «канал первым» (2–4 строки).
6. **Тесты:** `ConfigApplyTests.cs` — Bootstrap планируется при `vpn.enabled=false` и наличии `bootstrap.channel`; заголовок. Проверка: `cd app/launcher/tests && timeout 300 ~/.dotnet/dotnet run --project PortableTests.csproj -c Release -p:ConfigTests=true` и `server/tests/run.sh`.

## Поток C — Opus — сквозной тест на стенде
Ветка/worktree: `app/channel-c` / `~/work/wt-channel-c`.
Свои файлы: `app/launcher/tests/test_config_e2e.py`, `app/launcher/tests/ConfigE2E.cs` (и только их).

Новый сценарий рядом с существующим (существующий не ломать), на loopback:
- **«Глушилка» прямого SSH:** sshd стенда слушает `127.0.0.1:P`. На `127.0.0.2:P` — Python-сервер, который отдаёт настоящий баннер (проксирует первые байты до `127.0.0.1:P`) и затем замолкает навсегда. Это поведение мобильной сети. В конфиге `server.address=127.0.0.2`, `port=P`.
- **Канал:**
  - sing-box-сервер VLESS-Reality на loopback, параметры генерировать как в существующих тестах transport (поискать в `transport/test-*.py`);
  - тупой TCP-ретранслятор на Python (как sparfum: порт R → порт VLESS-сервера);
  - каталог `relays:[{name:'relay',host:'127.0.0.1',port:R}]`;
  - в канале прямого VLESS-адреса нет или он недоступен, так что работает только relay;
  - секрет `vpn-channel` — JSON канала с vless-outbound.
- **Ожидание:**
  - Bootstrap `ok`, `vpn='channel'`, кандидат `vless-relay-relay`;
  - Server `ok` через маршрут `proxy` 127.0.0.1:`channelSocksPort`;
  - затем Connection `ok`; вход по выданному ключу работает;
  - TUN и UAC не вызывались;
  - в отчёт — время «Запустить → Сервер ✅».
- Пока потоки A/B не слиты, тест падает. Это нормально: написать по контракту, проверить его части (стенд, глушилку, ретранслятор, VLESS через curl) отдельно.

## Общее
- Commit в свою ветку можно; push/merge — нет. Живой сервер, `~/.ssh`, службы, мост, Windows не трогать.
- Тесты: `timeout 60` (максимум 120) на файл. PowerShell: `~/.cache/pwsh-test/pwsh -NoProfile -NonInteractive … < /dev/null`, `LOCALAPPDATA=/tmp/<своё>`. .NET: `~/.dotnet/dotnet`.
- Прогресс одной строкой «k/n: что делаю» в `/tmp/agent-channel-<a|b|c>-status.txt` после каждого шага.
- В конце `docs/CHANNEL-REPORT-<A|B|C>.md`: что сделано, файлы, проверки с цифрами, отступления от контракта, что не проверено.
